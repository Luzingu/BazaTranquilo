import bcrypt from 'bcryptjs';
import { Router } from 'express';
import type { NextFunction, Request, Response } from 'express';
import jwt from 'jsonwebtoken';
import { z } from 'zod';
import { config } from '../config.js';
import { HttpError, parse } from '../http.js';
import { DriverModel, PassengerModel } from '../models/accounts.js';
import { SosAlertModel } from '../models/misc.js';
import { AuthorityQueryModel } from '../models/panel.js';
import { AgentModel, StationModel, type AgentDoc, type StationDoc } from '../models/police.js';
import { RideModel } from '../models/Ride.js';
import { haversineM } from '../services/geo.js';
import { pushToTokens } from '../services/push.js';
import { deleteFile, sendFile } from '../services/files.js';
import { sendSms } from '../services/sms.js';

// Área do agente de um posto policial, dentro da mesma aplicação. O agente só
// vê uma corrida quando o passageiro ou o motorista acciona o alerta de perigo,
// e só enquanto o alerta estiver aberto. Cada acesso fica registado.

declare global {
  namespace Express {
    interface Request {
      agent: AgentDoc;
      station: StationDoc;
    }
  }
}

const objectId = z.string().regex(/^[0-9a-f]{24}$/i, 'identificador inválido');

/** Postos avisados quando há um alerta: os que ficam a menos desta distância. */
const NEAR_M = 10_000;
/** Sem resposta ao fim deste tempo, o alerta sobe para o comando provincial. */
const ESCALATE_MS = 2 * 60_000;

// ── Sessão do agente ────────────────────────────────────────────────────────
// Dois passos: o código SMS dá um "bilhete" de curta duração; com ele e com a
// senha abre-se a sessão. O bilhete sozinho não dá acesso a nada.
const signTicket = (id: string) => jwt.sign({ sub: id, agentTicket: true }, config.jwtSecret, { expiresIn: '10m' });
const signAgent = (id: string) => jwt.sign({ sub: id, agent: true }, config.jwtSecret, { expiresIn: '30d' });
function verify(token: string, kind: 'agent' | 'agentTicket'): string | null {
  try {
    const p = jwt.verify(token, config.jwtSecret);
    return typeof p === 'object' && typeof p.sub === 'string' && p[kind] === true ? p.sub : null;
  } catch {
    return null;
  }
}

/** O agente activo com este número, se existir. Usado na entrada do app. */
export const agentByPhone = (phone: string) => AgentModel.findOne({ phone, active: true }).select('+passwordHash');

/** Resposta do passo do código SMS, quando o número é de um agente. */
export const agentTicketFor = (agent: AgentDoc) => ({
  agentTicket: signTicket(agent.id),
  agentHasPassword: Boolean(agent.passwordHash),
});

const agentOut = (a: AgentDoc, s: StationDoc) => ({
  id: a.id as string,
  name: a.name,
  rank: a.rank,
  phone: a.phone,
  onDuty: a.onDuty,
  station: { id: s.id as string, name: s.name, province: s.province, municipality: s.municipality },
});

export const agentRouter = Router();

/** Abre a sessão: bilhete do código SMS + senha (ou senha nova, na primeira vez) + aparelho. */
agentRouter.post('/session', async (req, res) => {
  const body = parse(
    z.object({
      ticket: z.string().min(10).max(600),
      password: z.string().min(6, 'A senha deve ter pelo menos 6 caracteres.').max(72),
      deviceId: z.string().min(8).max(100),
    }),
    req.body,
  );
  const id = verify(body.ticket, 'agentTicket');
  const agent = id ? await AgentModel.findOne({ _id: id, active: true }).select('+passwordHash') : null;
  if (!agent) throw new HttpError(401, 'O código expirou. Volte a entrar com o seu número.');
  const station = await StationModel.findById(agent.station);
  if (!station?.active) throw new HttpError(403, 'O seu posto está desactivado. Fale com a equipa do Bazá.');
  if (agent.passwordHash) {
    if (!(await bcrypt.compare(body.password, agent.passwordHash))) throw new HttpError(401, 'Senha incorrecta.');
  } else {
    agent.passwordHash = await bcrypt.hash(body.password, 11);
  }
  // O acesso fica preso ao primeiro telemóvel; outro aparelho precisa de autorização.
  if (agent.deviceId && agent.deviceId !== body.deviceId) {
    throw new HttpError(403, 'Esta conta está associada a outro telemóvel. Peça à equipa do Bazá para autorizar este aparelho.');
  }
  agent.deviceId = body.deviceId;
  agent.lastLoginAt = new Date();
  await agent.save();
  res.json({ token: signAgent(agent.id), agent: agentOut(agent, station) });
});

async function requireAgent(req: Request, _res: Response, next: NextFunction) {
  const header = req.headers.authorization ?? '';
  const id = header.startsWith('Bearer ') ? verify(header.slice(7), 'agent') : null;
  const agent = id ? await AgentModel.findOne({ _id: id, active: true }) : null;
  const station = agent ? await StationModel.findById(agent.station) : null;
  if (!agent || !station?.active) throw new HttpError(401, 'Sessão inválida. Entre novamente.');
  req.agent = agent;
  req.station = station;
  next();
}
agentRouter.use(requireAgent);

agentRouter.get('/me', (req, res) => {
  res.json({ agent: agentOut(req.agent, req.station) });
});

/** "Estou de serviço": só assim se recebem os alertas. */
agentRouter.post('/duty', async (req, res) => {
  const { on } = parse(z.object({ on: z.boolean() }), req.body);
  req.agent.onDuty = on;
  await req.agent.save();
  res.json({ agent: agentOut(req.agent, req.station) });
});

const pushToken = z.object({ token: z.string().min(20).max(4096) });
agentRouter.put('/push-token', async (req, res) => {
  const { token } = parse(pushToken, req.body);
  await AgentModel.updateMany({ pushTokens: token }, { $pull: { pushTokens: token } });
  await PassengerModel.updateMany({ pushTokens: token }, { $pull: { pushTokens: token } });
  await DriverModel.updateMany({ pushTokens: token }, { $pull: { pushTokens: token } });
  await req.agent.updateOne({ $addToSet: { pushTokens: token } });
  res.json({ ok: true });
});
agentRouter.post('/logout', async (req, res) => {
  const body = parse(pushToken.partial(), req.body ?? {});
  await req.agent.updateOne({ onDuty: false, ...(body.token ? { $pull: { pushTokens: body.token } } : {}) });
  res.json({ ok: true });
});

async function log(req: Request, kind: string, target: string, reason: string) {
  await AuthorityQueryModel.create({
    authority: req.station._id,
    authorityName: req.station.name,
    user: req.agent._id,
    userName: `${req.agent.rank ? `${req.agent.rank} ` : ''}${req.agent.name}`,
    kind,
    target,
    reason,
    results: 1,
  });
}

type Alert = InstanceType<typeof SosAlertModel>;
const mineFilter = (req: Request) => ({ stations: req.station._id });

async function alertSummary(a: Alert, here: StationDoc) {
  const who = a.role === 'driver' ? await DriverModel.findById(a.user).select('name phone') : await PassengerModel.findById(a.user).select('name phone');
  return {
    id: a.id as string,
    createdAt: a.get('createdAt') as Date,
    open: a.status !== 'closed',
    role: a.role,
    name: who?.name || '—',
    lat: a.lat ?? null,
    lng: a.lng ?? null,
    distanceM: a.lat != null && a.lng != null ? Math.round(haversineM({ lat: here.lat, lng: here.lng }, { lat: a.lat, lng: a.lng })) : null,
    assignedName: a.assignedName ?? null,
    escalated: Boolean(a.escalatedAt),
    // Som partilhado por quem pediu ajuda: número do último bloco (0 = não partilha).
    audioLast: a.status !== 'closed' ? (a.audio.at(-1)?.seq ?? 0) : 0,
    closedBy: a.closedBy ?? null,
    closeNote: a.closeNote ?? null,
    cancelledByUser: a.cancelledByUser,
  };
}

/** Alertas do meu posto: primeiro os abertos. O app verifica de poucos em poucos segundos. */
agentRouter.get('/alerts', async (req, res) => {
  const since = new Date(Date.now() - 7 * 24 * 3600_000);
  const list = await SosAlertModel.find({ ...mineFilter(req), $or: [{ status: { $ne: 'closed' } }, { createdAt: { $gte: since } }] })
    .sort({ createdAt: -1 })
    .limit(40);
  const alerts = await Promise.all(list.map((a) => alertSummary(a, req.station)));
  alerts.sort((a, b) => Number(b.open) - Number(a.open) || b.createdAt.getTime() - a.createdAt.getTime());
  res.json({ open: alerts.filter((a) => a.open).length, alerts, agent: agentOut(req.agent, req.station) });
});

/**
 * O alerta e a sua corrida, para quem tem direito a vê-los (o agente de um
 * posto avisado ou a pessoa de confiança). Com `here`, inclui a distância ao posto.
 */
export async function alertForViewer(alert: Alert, here?: StationDoc) {
  const ride = await RideModel.findById(alert.ride);
  const [driver, passenger] = await Promise.all([
    ride?.driver ? DriverModel.findById(ride.driver) : null,
    ride ? PassengerModel.findById(ride.passenger) : null,
  ]);
  const open = alert.status !== 'closed';
  const coords = driver?.location?.coordinates;
  const v = driver?.vehicle;
  const party = (p: { name?: string | null; phone?: string | null; photo?: string | null } | null) =>
    p ? { name: p.name || '(sem nome)', phone: p.phone ?? null, photoUrl: p.photo ? `/uploads/${p.photo}` : null } : null;
  const who = alert.role === 'driver' ? driver : passenger;
  return {
    id: alert.id as string,
    createdAt: alert.get('createdAt') as Date,
    open,
    role: alert.role,
    name: who?.name || '—',
    lat: alert.lat ?? null,
    lng: alert.lng ?? null,
    distanceM: here && alert.lat != null && alert.lng != null ? Math.round(haversineM({ lat: here.lat, lng: here.lng }, { lat: alert.lat, lng: alert.lng })) : null,
    assignedName: alert.assignedName ?? null,
    escalated: Boolean(alert.escalatedAt),
    audioLast: open ? (alert.audio.at(-1)?.seq ?? 0) : 0,
    closedBy: alert.closedBy ?? null,
    closeNote: alert.closeNote ?? null,
    cancelledByUser: alert.cancelledByUser,
    by: party(who),
    // Depois de fechado o alerta, os dados da corrida deixam de ser mostrados.
    ride:
      open && ride
        ? {
            status: ride.status,
            from: { address: ride.pickup?.address ?? '', lat: ride.pickup?.lat ?? null, lng: ride.pickup?.lng ?? null },
            to: ride.dropoff?.address ? { address: ride.dropoff.address, lat: ride.dropoff.lat ?? null, lng: ride.dropoff.lng ?? null } : null,
            passenger: party(passenger),
            driver: party(driver),
            vehicle: v ? { label: `${v.make} ${v.carModel}`, color: v.color, plate: v.plate } : null,
            live: coords?.length === 2 ? { lat: coords[1], lng: coords[0], at: driver?.locationUpdatedAt ?? null } : null,
          }
        : null,
  };
}

/** A corrida de um alerta aberto: pessoas, viatura, percurso e posição actual. */
agentRouter.get('/alerts/:id', async (req, res) => {
  const alert = await SosAlertModel.findOne({ _id: parse(objectId, req.params.id), ...mineFilter(req) });
  if (!alert) throw new HttpError(404, 'Alerta não encontrado.');
  const recent = await AuthorityQueryModel.exists({
    user: req.agent._id,
    kind: 'alert',
    target: { $regex: `#${alert.id}$` },
    createdAt: { $gte: new Date(Date.now() - 3600_000) },
  });
  if (!recent) await log(req, 'alert', `Alerta #${alert.id}`, alert.status !== 'closed' ? 'Alerta de perigo aberto' : 'Alerta fechado (só o resumo)');
  res.json({ ...(await alertForViewer(alert, req.station)), mine: String(alert.assignedTo ?? '') === req.agent.id });
});

/** Um bloco do som da viagem. Só enquanto o alerta está aberto, como o resto da corrida. */
agentRouter.get('/alerts/:id/audio/:seq', async (req, res) => {
  const seq = parse(z.coerce.number().int().min(1), req.params.seq);
  const alert = await SosAlertModel.findOne({ _id: parse(objectId, req.params.id), ...mineFilter(req), status: { $ne: 'closed' } });
  const chunk = alert?.audio.find((c) => c.seq === seq);
  if (!alert || !chunk) throw new HttpError(404, 'Som não encontrado.');
  const listened = await AuthorityQueryModel.exists({ user: req.agent._id, kind: 'audio', target: { $regex: `#${alert.id}$` } });
  if (!listened) await log(req, 'audio', `Alerta #${alert.id}`, 'Ouviu o som da viagem');
  await sendFile(res, chunk.file, 'audio');
});

/** "Assumo este alerta": os colegas ficam a saber quem está com o caso, e quem pediu ajuda também. */
agentRouter.post('/alerts/:id/assume', async (req, res) => {
  const name = `${req.agent.rank ? `${req.agent.rank} ` : ''}${req.agent.name} (${req.station.name})`;
  const alert = await SosAlertModel.findOneAndUpdate(
    { _id: parse(objectId, req.params.id), ...mineFilter(req), status: { $ne: 'closed' }, assignedTo: null },
    { assignedTo: req.agent._id, assignedName: name, assignedAt: new Date() },
    { returnDocument: 'after' },
  );
  if (!alert) throw new HttpError(409, 'Este alerta já foi assumido por outro agente, ou já está fechado.');
  await log(req, 'assume', `Alerta #${alert.id}`, 'Assumiu o alerta');
  res.json({ ok: true });
});

/** Fecha o alerta com o relato do que foi feito; a partir daí deixa-se de ver a corrida. */
agentRouter.post('/alerts/:id/close', async (req, res) => {
  const body = parse(z.object({ note: z.string().trim().min(5, 'Escreva o que foi feito.').max(300) }), req.body);
  const alert = await SosAlertModel.findOneAndUpdate(
    { _id: parse(objectId, req.params.id), ...mineFilter(req), status: { $ne: 'closed' } },
    { status: 'closed', closedAt: new Date(), closedBy: `${req.agent.name} (${req.station.name})`, closeNote: body.note },
  );
  if (!alert) throw new HttpError(409, 'Este alerta já estava fechado.');
  await log(req, 'close', `Alerta #${alert.id}`, body.note);
  res.json({ ok: true });
});

// ── Encaminhar os alertas para os postos ────────────────────────────────────

/** Avisa os agentes de serviço de um conjunto de postos; sem ninguém de serviço, vai um SMS ao posto. */
async function notifyStations(stations: StationDoc[], alert: Alert, title: string) {
  const who = alert.role === 'driver' ? 'Um motorista' : 'Um passageiro';
  for (const s of stations) {
    const agents = await AgentModel.find({ station: s._id, active: true, onDuty: true }).select('pushTokens');
    const tokens = agents.flatMap((a) => a.pushTokens);
    if (tokens.length) {
      const gone = await pushToTokens(tokens, { title, body: `${who} pediu ajuda. Abra o Bazá para ver onde está.`, urgent: true, voice: 'alerta_perigo' });
      if (gone.length) await AgentModel.updateMany({ station: s._id }, { $pull: { pushTokens: { $in: gone } } });
    } else if (s.phone && !config.isDev) {
      // Rede de segurança: ninguém de serviço neste posto. (Em desenvolvimento não se gastam SMS.)
      const where = alert.lat != null ? ` Local: https://maps.google.com/?q=${alert.lat},${alert.lng}` : '';
      await sendSms(s.phone, `Bazá: alerta de perigo numa viatura.${where} Abra o Bazá para acompanhar.`).catch((err) => console.warn('SMS ao posto falhou:', (err as Error).message));
    }
  }
}

/**
 * Um alerta novo vai para os postos a menos de 10 km do local; se não houver
 * nenhum, para os dois mais próximos. Sem posição do alerta, usa-se a recolha.
 */
export async function routeAlert(alert: Alert) {
  let at = alert.lat != null && alert.lng != null ? { lat: alert.lat, lng: alert.lng } : null;
  if (!at) {
    const ride = await RideModel.findById(alert.ride).select('pickup');
    if (ride?.pickup?.lat != null) at = { lat: ride.pickup.lat, lng: ride.pickup.lng };
  }
  const all = await StationModel.find({ active: true });
  if (!all.length) return [];
  const ranked = at
    ? all.map((s) => ({ s, d: haversineM(at!, { lat: s.lat, lng: s.lng }) })).sort((a, b) => a.d - b.d)
    : all.map((s) => ({ s, d: Number.POSITIVE_INFINITY }));
  let chosen = ranked.filter((x) => x.d <= NEAR_M);
  if (!chosen.length) chosen = ranked.slice(0, 2);
  alert.stations = chosen.map((x) => x.s._id);
  await alert.save();
  await notifyStations(chosen.map((x) => x.s), alert, 'ALERTA DE PERIGO');
  return chosen.map((x) => ({ name: x.s.name, distanceM: Number.isFinite(x.d) ? Math.round(x.d) : null }));
}

/** Alertas que ninguém assumiu a tempo sobem para os comandos provinciais. Corre de 30 em 30 segundos. */
export async function escalateStaleAlerts() {
  const stale = await SosAlertModel.find({
    status: { $ne: 'closed' },
    assignedTo: null,
    escalatedAt: null,
    createdAt: { $lte: new Date(Date.now() - ESCALATE_MS) },
  }).limit(20);
  for (const alert of stale) {
    const notified = await StationModel.find({ _id: { $in: alert.stations } });
    const provinces = [...new Set(notified.map((s) => s.province))];
    const commands = await StationModel.find({
      active: true,
      command: true,
      _id: { $nin: alert.stations },
      ...(provinces.length ? { province: { $in: provinces } } : {}),
    });
    alert.escalatedAt = new Date();
    alert.stations.push(...commands.map((c) => c._id));
    await alert.save();
    console.warn(`[SOS] alerta ${alert.id} sem resposta há 2 minutos: ${commands.length ? `enviado a ${commands.map((c) => c.name).join(', ')}` : 'sem comando provincial registado'}.`);
    await notifyStations(commands, alert, 'ALERTA SEM RESPOSTA');
  }
}

/** O som dos alertas é apagado 30 dias depois de o alerta ser fechado. Corre de hora a hora. */
export async function purgeOldAudio() {
  const old = await SosAlertModel.find({ status: 'closed', closedAt: { $lte: new Date(Date.now() - 30 * 24 * 3600_000) }, 'audio.0': { $exists: true } }).limit(20);
  for (const alert of old) {
    for (const c of alert.audio) await deleteFile(c.file);
    await alert.updateOne({ $set: { audio: [] } });
  }
}

/** O que quem pediu ajuda vê: a que postos foi o alerta e quem o assumiu. */
export async function alertStatusForUser(alert: Alert) {
  const stations = await StationModel.find({ _id: { $in: alert.stations } }).select('name lat lng');
  return {
    id: alert.id as string,
    open: alert.status !== 'closed',
    stations: stations.map((s) => ({
      name: s.name,
      distanceM: alert.lat != null && alert.lng != null ? Math.round(haversineM({ lat: alert.lat, lng: alert.lng }, { lat: s.lat, lng: s.lng })) : null,
    })),
    assignedName: alert.assignedName ?? null,
    audioChunks: alert.audio.length,
    closed: alert.status === 'closed' ? { by: alert.closedBy ?? null, note: alert.cancelledByUser ? null : (alert.closeNote ?? null), cancelledByUser: alert.cancelledByUser } : null,
  };
}

import { randomBytes } from 'node:crypto';
import { Router, type Request } from 'express';
import rateLimit from 'express-rate-limit';
import helmet from 'helmet';
import { z } from 'zod';
import { config } from '../config.js';
import { HttpError, parse, requireAuth } from '../http.js';
import { DriverModel, PassengerModel } from '../models/accounts.js';
import bcrypt from 'bcryptjs';
import { MessageModel, SosAlertModel } from '../models/misc.js';
import express from 'express';
import { saveAudio } from '../services/files.js';
import { alertForViewer, alertStatusForUser, routeAlert } from './agent.js';
import { sendFile } from '../services/files.js';
import { ACTIVE_STATUSES, RideModel } from '../models/Ride.js';
import { getRoute } from '../services/geo.js';
import { emitToUser } from '../services/realtime.js';

// Partilha da viagem: o passageiro (ou o motorista) gera um link que qualquer
// pessoa pode abrir no browser, sem a app, para acompanhar a viagem em directo.
// Botão SOS: fica registado um alerta com a posição de quem o accionou.

/** Depois de a viagem terminar, o link ainda mostra o resultado durante este tempo. */
const SHARE_GRACE_MS = 30 * 60_000;

const firstName = (name?: string | null) => (name ?? '').trim().split(/\s+/)[0] || 'Passageiro';

export const safetyRouter = Router();
safetyRouter.use(requireAuth);

const mine = (req: Request) =>
  req.role === 'passenger' ? { passenger: req.account._id } : { driver: req.account._id };

/** Cria (ou devolve) o link de acompanhamento de uma corrida em curso. */
safetyRouter.post('/:id/share', async (req, res) => {
  const id = parse(z.string().regex(/^[0-9a-f]{24}$/i), req.params.id);
  const ride = await RideModel.findOne({
    _id: id,
    ...mine(req),
    status: { $in: ACTIVE_STATUSES },
  });
  if (!ride) throw new HttpError(409, 'Só é possível partilhar uma viagem em curso.');
  if (!ride.shareToken) {
    // Aleatório e longo: quem não tiver o link não o consegue adivinhar.
    ride.shareToken = randomBytes(18).toString('base64url');
    await ride.save();
  }
  res.json({ url: `${config.publicUrl}/acompanhar/${ride.shareToken}` });
});

/** Regista um alerta SOS. A chamada de emergência é feita pelo telemóvel. */
safetyRouter.post('/:id/sos', async (req, res) => {
  const id = parse(z.string().regex(/^[0-9a-f]{24}$/i), req.params.id);
  const body = parse(
    z.object({
      lat: z.number().min(-90).max(90).optional(),
      lng: z.number().min(-180).max(180).optional(),
    }),
    req.body,
  );
  const ride = await RideModel.findOne({ _id: id, ...mine(req) });
  if (!ride) throw new HttpError(404, 'Corrida não encontrada.');
  // Tocar várias vezes não cria vários alertas: actualiza a posição do que está aberto.
  // É este alerta que dá às autoridades acesso à corrida, e só enquanto estiver aberto.
  let alert = await SosAlertModel.findOneAndUpdate(
    { ride: ride._id, user: req.account._id, status: { $ne: 'closed' } },
    { ...(body.lat !== undefined ? { lat: body.lat, lng: body.lng } : {}) },
    { returnDocument: 'after' },
  );
  if (!alert) {
    alert = await SosAlertModel.create({ ride: ride._id, role: req.role, user: req.account._id, lat: body.lat, lng: body.lng });
    // Alerta novo: avisa os postos policiais mais próximos.
    await routeAlert(alert).catch((err) => console.error('[SOS] falha ao avisar os postos:', err));
    // E a pessoa de confiança, se o contacto de emergência tiver conta no Bazá.
    const phone = req.account.emergencyContact?.phone;
    const friend = phone ? await PassengerModel.findOne({ phone }).select('_id') : null;
    if (friend && friend.id !== req.account.id) {
      await alert.updateOne({ guardian: friend._id });
      emitToUser(friend.id, 'guardian:alert', {
        alertId: alert.id,
        title: `${req.account.name || 'Um contacto seu'} pediu ajuda`,
        body: 'Accionou o alerta de perigo numa viagem. Abra o Bazá para acompanhar.',
      });
    }
  }
  console.warn(
    `[SOS] ${req.role} ${req.account.name} (${req.account.phone ?? req.account.email ?? req.account.id}) ` +
      `na corrida ${ride.id}` +
      (body.lat !== undefined ? ` em ${body.lat},${body.lng}` : ''),
  );
  res.status(201).json({ ...(await alertStatusForUser(alert)), emergencyNumber: config.emergencyNumber });
});

/** O estado do meu alerta nesta corrida: a que postos foi e quem o assumiu. */
safetyRouter.get('/:id/sos', async (req, res) => {
  const id = parse(z.string().regex(/^[0-9a-f]{24}$/i), req.params.id);
  const alert = await SosAlertModel.findOne({ ride: id, user: req.account._id }).sort({ createdAt: -1 });
  res.json({ alert: alert ? await alertStatusForUser(alert) : null });
});

/** Blocos de som por alerta: cerca de 1 hora, com blocos de 8 segundos. */
const MAX_AUDIO_CHUNKS = 450;

/**
 * Som da viagem durante um alerta de perigo. Só quem accionou o alerta o envia,
 * por escolha sua, e só enquanto o alerta estiver aberto. O corpo do pedido é
 * um bloco WAV de poucos segundos.
 */
safetyRouter.put('/:id/sos/audio', express.raw({ type: () => true, limit: '600kb' }), async (req, res) => {
  const id = parse(z.string().regex(/^[0-9a-f]{24}$/i), req.params.id);
  const alert = await SosAlertModel.findOne({ ride: id, user: req.account._id, status: { $ne: 'closed' } });
  // 409: o app pára de gravar (alerta fechado ou cancelado).
  if (!alert) throw new HttpError(409, 'O alerta já não está activo.');
  if (alert.audio.length >= MAX_AUDIO_CHUNKS) throw new HttpError(409, 'Atingiu o limite de som deste alerta.');
  const file = await saveAudio(req.body, `alert:${alert.id}`);
  const seq = (alert.audio.at(-1)?.seq ?? 0) + 1;
  await alert.updateOne({ $push: { audio: { seq, file, at: new Date() } } });
  res.status(201).json({ seq });
});

/**
 * Cancelar o alerta (foi engano). Pede a senha, para que ninguém obrigue a
 * vítima a cancelar com um simples toque; os agentes ficam a saber que foi
 * cancelado por quem o accionou.
 */
safetyRouter.post('/:id/sos/cancel', async (req, res) => {
  const id = parse(z.string().regex(/^[0-9a-f]{24}$/i), req.params.id);
  const body = parse(z.object({ password: z.string().min(1).max(72) }), req.body);
  if (!req.account.passwordHash || !(await bcrypt.compare(body.password, req.account.passwordHash))) {
    throw new HttpError(401, 'Senha incorrecta. O alerta continua activo.');
  }
  const alert = await SosAlertModel.findOneAndUpdate(
    { ride: id, user: req.account._id, status: { $ne: 'closed' } },
    { status: 'closed', closedAt: new Date(), closedBy: 'Quem accionou o alerta', closeNote: 'Cancelado por quem o accionou, com a senha.', cancelledByUser: true },
  );
  if (!alert) throw new HttpError(404, 'Não tem nenhum alerta activo nesta corrida.');
  res.json({ ok: true });
});

// ── Chat entre passageiro e motorista ───────────────────────────────────────
// Só existe entre as duas pessoas de uma corrida com motorista atribuído. Depois
// de a corrida terminar pode ler-se, mas já não se pode escrever.

const CHAT_STATUSES = ['accepted', 'arrived', 'in_progress'] as const;
const MAX_MESSAGES_PER_RIDE = 300;

const serializeMessage = (m: { id?: unknown; role: string; text: string; get(path: string): unknown }) => ({
  id: String(m.id),
  from: m.role,
  text: m.text,
  createdAt: m.get('createdAt') as Date,
});

safetyRouter.get('/:id/messages', async (req, res) => {
  const id = parse(z.string().regex(/^[0-9a-f]{24}$/i), req.params.id);
  const ride = await RideModel.findOne({ _id: id, ...mine(req), driver: { $exists: true } }).select('status');
  if (!ride) throw new HttpError(404, 'Corrida não encontrada.');
  const messages = await MessageModel.find({ ride: ride._id }).sort({ createdAt: 1 }).limit(MAX_MESSAGES_PER_RIDE);
  res.json({ messages: messages.map(serializeMessage), open: (CHAT_STATUSES as readonly string[]).includes(ride.status) });
});

safetyRouter.post('/:id/messages', async (req, res) => {
  const id = parse(z.string().regex(/^[0-9a-f]{24}$/i), req.params.id);
  const body = parse(z.object({ text: z.string().trim().min(1).max(500) }), req.body);
  const ride = await RideModel.findOne({ _id: id, ...mine(req), status: { $in: [...CHAT_STATUSES] } }).select(
    'passenger driver',
  );
  if (!ride || !ride.driver) throw new HttpError(409, 'Só pode enviar mensagens durante uma corrida em curso.');
  if ((await MessageModel.countDocuments({ ride: ride._id })) >= MAX_MESSAGES_PER_RIDE) {
    throw new HttpError(429, 'Esta conversa atingiu o limite de mensagens. Ligue à outra pessoa.');
  }
  const message = serializeMessage(await MessageModel.create({ ride: ride._id, role: req.role, text: body.text }));
  // Entrega em tempo real à outra pessoa da corrida.
  const other = req.role === 'passenger' ? ride.driver : ride.passenger;
  emitToUser(String(other), 'chat:message', { rideId: ride.id, message });
  res.status(201).json({ message });
});

// ── Acompanhamento em tempo real ────────────────────────────────────────────
// Percurso e tempo que faltam ao motorista: até ao ponto de recolha enquanto
// vai a caminho, e até ao destino (pelas paragens) durante a viagem.
const etaCache = new Map<string, { at: number; data: unknown }>();
const ETA_TTL_MS = 12_000;

safetyRouter.get('/:id/eta', async (req, res) => {
  const id = parse(z.string().regex(/^[0-9a-f]{24}$/i), req.params.id);
  const ride = await RideModel.findOne({ _id: id, ...mine(req), status: { $in: [...CHAT_STATUSES] } });
  if (!ride?.driver) throw new HttpError(409, 'A corrida não está em curso.');
  const cacheKey = `${ride.id}:${ride.status}`;
  const hit = etaCache.get(cacheKey);
  if (hit && Date.now() - hit.at < ETA_TTL_MS) {
    res.json(hit.data);
    return;
  }
  const driver = await DriverModel.findById(ride.driver).select('location locationUpdatedAt');
  const coords = driver?.location?.coordinates;
  if (coords?.length !== 2) throw new HttpError(409, 'Ainda não há posição do motorista.');
  const from = { lat: coords[1]!, lng: coords[0]! };
  const toDropoff = ride.status === 'in_progress';
  const route = toDropoff ? await getRoute(from, ride.dropoff, ride.stops) : await getRoute(from, ride.pickup);
  const data = {
    target: toDropoff ? 'dropoff' : 'pickup',
    distanceM: route.distanceM,
    durationS: route.durationS,
    geometry: route.geometry,
    driverLocation: from,
    locationAt: driver?.locationUpdatedAt ?? null,
  };
  if (etaCache.size > 2000) etaCache.clear();
  etaCache.set(cacheKey, { at: Date.now(), data });
  res.json(data);
});

/** Servidores (STUN/TURN) que o app usa para estabelecer a chamada de voz. */
safetyRouter.get('/:id/call-config', async (req, res) => {
  const id = parse(z.string().regex(/^[0-9a-f]{24}$/i), req.params.id);
  if (!(await RideModel.exists({ _id: id, ...mine(req), status: { $in: [...CHAT_STATUSES] } }))) {
    throw new HttpError(409, 'Só pode ligar durante uma corrida em curso.');
  }
  res.set('Cache-Control', 'no-store').json({ iceServers: config.iceServers });
});

// ── Página pública de acompanhamento ────────────────────────────────────────
export const shareRouter = Router();
const limiter = rateLimit({ windowMs: 60_000, limit: 120, standardHeaders: true, legacyHeaders: false });
shareRouter.use(limiter);

/** O que o link mostra: o suficiente para acompanhar, sem telefones nem apelidos. */
shareRouter.get('/:token/dados', async (req, res) => {
  const token = String(req.params.token);
  const ride = /^[\w-]{20,40}$/.test(token) ? await RideModel.findOne({ shareToken: token }) : null;
  const finishedAt = ride?.completedAt ?? ride?.cancelledAt;
  const expired = !!finishedAt && Date.now() - finishedAt.getTime() > SHARE_GRACE_MS;
  if (!ride || expired || ride.status === 'no_drivers') throw new HttpError(404, 'Este link já não está activo.');

  const [passenger, driver] = await Promise.all([
    PassengerModel.findById(ride.passenger).select('name'),
    ride.driver ? DriverModel.findById(ride.driver) : null,
  ]);
  const active = ['accepted', 'arrived', 'in_progress'].includes(ride.status);
  const coords = active ? driver?.location?.coordinates : undefined;
  res.set('Cache-Control', 'no-store');
  res.json({
    status: ride.status,
    passenger: firstName(passenger?.name),
    pickup: ride.pickup,
    dropoff: ride.dropoff,
    stops: ride.stops,
    route: ride.routeGeometry ?? null,
    driver: driver
      ? {
          name: firstName(driver.name),
          vehicle: driver.vehicle
            ? `${driver.vehicle.color} · ${driver.vehicle.make} ${driver.vehicle.carModel}`
            : null,
          plate: driver.vehicle?.plate ?? null,
        }
      : null,
    driverLocation: coords?.length === 2 ? { lat: coords[1], lng: coords[0] } : null,
    locationAt: active ? (driver?.locationUpdatedAt ?? null) : null,
    finishedAt: finishedAt ?? null,
  });
});

const PAGE_JS = String.raw`
const token = location.pathname.split('/').filter(Boolean).pop();
const $ = (id) => document.getElementById(id);
const STATUS = {
  searching: 'À procura de motorista',
  accepted: 'O motorista vai a caminho do ponto de recolha',
  arrived: 'O motorista chegou ao ponto de recolha',
  in_progress: 'Em viagem',
  completed: 'A viagem terminou',
  cancelled: 'A viagem foi cancelada',
};
let map, carMarker, drawn = false;

// Polyline codificada (precisão 5), como a que o servidor guarda.
function decode(str) {
  const out = []; let i = 0, lat = 0, lng = 0;
  const next = () => { let r = 0, s = 0, b; do { b = str.charCodeAt(i++) - 63; r |= (b & 31) << s; s += 5; } while (b >= 32 && i < str.length); return r & 1 ? -(r >> 1) - 1 : r >> 1; };
  while (i < str.length) { lat += next(); if (i >= str.length) break; lng += next(); out.push([lat / 1e5, lng / 1e5]); }
  return out;
}
const dot = (color) => L.divIcon({ className: '', html: '<div class="dot" style="background:' + color + '"></div>', iconSize: [18, 18], iconAnchor: [9, 9] });
const time = (iso) => new Date(iso).toLocaleTimeString('pt-PT', { hour: '2-digit', minute: '2-digit' });

async function refresh() {
  let d;
  try {
    const r = await fetch('/acompanhar/' + token + '/dados');
    if (r.status === 404) { $('status').textContent = 'Este link já não está activo.'; $('details').hidden = true; $('map').hidden = true; return; }
    d = await r.json();
  } catch { $('updated').textContent = 'Sem ligação. A tentar de novo…'; return setTimeout(refresh, 8000); }

  $('title').textContent = d.passenger + ' está a viajar com o Bazá';
  $('status').textContent = STATUS[d.status] || d.status;
  $('from').textContent = d.pickup.address;
  $('to').textContent = d.dropoff.address;
  $('driver').textContent = d.driver ? d.driver.name : 'Ainda sem motorista';
  $('vehicle').textContent = d.driver && d.driver.vehicle ? d.driver.vehicle : '—';
  $('plate').textContent = d.driver && d.driver.plate ? d.driver.plate : '—';
  $('details').hidden = false;

  if (!map) {
    map = L.map('map', { zoomControl: false }).setView([d.pickup.lat, d.pickup.lng], 14);
    L.tileLayer('__TILES__', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map);
  }
  if (!drawn) {
    drawn = true;
    L.marker([d.pickup.lat, d.pickup.lng], { icon: dot('#16a34a') }).addTo(map);
    L.marker([d.dropoff.lat, d.dropoff.lng], { icon: dot('#dc2626') }).addTo(map);
    const line = d.route ? decode(d.route) : [[d.pickup.lat, d.pickup.lng], [d.dropoff.lat, d.dropoff.lng]];
    L.polyline(line, { color: '#14161a', weight: 4 }).addTo(map);
    map.fitBounds(L.latLngBounds(line), { padding: [40, 40] });
  }
  if (d.driverLocation) {
    const p = [d.driverLocation.lat, d.driverLocation.lng];
    if (!carMarker) carMarker = L.marker(p, { icon: L.divIcon({ className: '', html: '<div class="car">🚕</div>', iconSize: [36, 36], iconAnchor: [18, 18] }), zIndexOffset: 1000 }).addTo(map);
    else carMarker.setLatLng(p);
    $('updated').textContent = d.locationAt ? 'Posição actualizada às ' + time(d.locationAt) : '';
  } else {
    if (carMarker) { carMarker.remove(); carMarker = null; }
    $('updated').textContent = d.finishedAt ? 'Terminou às ' + time(d.finishedAt) : '';
  }
  if (d.status !== 'completed' && d.status !== 'cancelled') setTimeout(refresh, 5000);
}
refresh();
`;

const PAGE_HTML = `<!doctype html>
<html lang="pt">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Acompanhar viagem — Bazá Tranquilo</title>
<link rel="stylesheet" href="/painel/vendor/leaflet/leaflet.css">
<style>
  * { box-sizing: border-box; }
  html, body { height: 100%; margin: 0; font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; color: #14161a; }
  body { display: flex; flex-direction: column; }
  header { padding: 14px 16px; background: #ffc400; }
  header .brand { font-weight: 900; font-size: 20px; }
  h1 { margin: 4px 0 0; font-size: 17px; font-weight: 700; }
  #map { flex: 1; min-height: 240px; }
  #panel { padding: 14px 16px 18px; box-shadow: 0 -4px 16px rgba(0,0,0,.15); }
  #status { font-size: 19px; font-weight: 800; margin: 0 0 4px; }
  #updated { color: #6b7280; font-size: 13px; min-height: 18px; }
  dl { display: grid; grid-template-columns: auto 1fr; gap: 6px 12px; margin: 12px 0 0; font-size: 15px; }
  dt { color: #6b7280; }
  dd { margin: 0; font-weight: 600; }
  #plate { display: inline-block; border: 2px solid #14161a; border-radius: 6px; padding: 1px 8px; letter-spacing: .5px; }
  .dot { width: 18px; height: 18px; border-radius: 50%; border: 3px solid #fff; box-shadow: 0 0 4px rgba(0,0,0,.5); }
  .car { width: 36px; height: 36px; border-radius: 50%; background: #ffc400; display: grid; place-items: center; font-size: 20px; box-shadow: 0 0 6px rgba(0,0,0,.5); }
</style>
</head>
<body>
<header><div class="brand">Bazá <span style="font-weight:500">Tranquilo</span></div><h1 id="title">A carregar…</h1></header>
<div id="map"></div>
<div id="panel">
  <p id="status">A carregar a viagem…</p>
  <div id="updated"></div>
  <dl id="details" hidden>
    <dt>De</dt><dd id="from"></dd>
    <dt>Para</dt><dd id="to"></dd>
    <dt>Motorista</dt><dd id="driver"></dd>
    <dt>Viatura</dt><dd id="vehicle"></dd>
    <dt>Matrícula</dt><dd><span id="plate"></span></dd>
  </dl>
</div>
<script src="/painel/vendor/leaflet/leaflet.js"></script>
<script src="/acompanhar/pagina.js"></script>
</body>
</html>`;

// Esta página carrega o mapa (Leaflet) e as imagens do OpenStreetMap: precisa de
// uma política de conteúdos própria, mais aberta do que a do resto da API.
const pageCsp = helmet.contentSecurityPolicy({
  useDefaults: false,
  directives: {
    defaultSrc: ["'self'"],
    scriptSrc: ["'self'"],
    styleSrc: ["'self'", "'unsafe-inline'"],
    imgSrc: ["'self'", 'data:', 'https://tile.openstreetmap.org'],
    connectSrc: ["'self'"],
    baseUri: ["'none'"],
    frameAncestors: ["'none'"],
  },
});

shareRouter.get('/pagina.js', (_req, res) => {
  res.type('text/javascript').set('Cache-Control', 'public, max-age=300').send(
    PAGE_JS.replace(
      '__TILES__',
      config.tileUpstream ? '/map/tiles/{z}/{x}/{y}.png' : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    ),
  );
});

shareRouter.get('/:token', pageCsp, (_req, res) => {
  res.type('html').set('Cache-Control', 'no-store').set('Referrer-Policy', 'no-referrer').send(PAGE_HTML);
});

// ── Pessoa de confiança ─────────────────────────────────────────────────────
// Quem é contacto de emergência de alguém, e tem conta no Bazá, acompanha no app
// a viagem dessa pessoa enquanto o alerta dela estiver aberto: mapa, viatura e,
// se ela o partilhar, o som.
export const guardianRouter = Router();
guardianRouter.use(requireAuth);
const objectId24 = z.string().regex(/^[0-9a-f]{24}$/i);

guardianRouter.get('/alerts', async (req, res) => {
  const list = await SosAlertModel.find({ guardian: req.account._id, status: { $ne: 'closed' } }).sort({ createdAt: -1 }).limit(5);
  res.json({ alerts: await Promise.all(list.map((a) => alertForViewer(a))) });
});

guardianRouter.get('/alerts/:id', async (req, res) => {
  const alert = await SosAlertModel.findOne({ _id: parse(objectId24, req.params.id), guardian: req.account._id });
  if (!alert) throw new HttpError(404, 'Alerta não encontrado.');
  res.json(await alertForViewer(alert));
});

guardianRouter.get('/alerts/:id/audio/:seq', async (req, res) => {
  const seq = parse(z.coerce.number().int().min(1), req.params.seq);
  const alert = await SosAlertModel.findOne({ _id: parse(objectId24, req.params.id), guardian: req.account._id, status: { $ne: 'closed' } });
  const chunk = alert?.audio.find((c) => c.seq === seq);
  if (!chunk) throw new HttpError(404, 'Som não encontrado.');
  await sendFile(res, chunk.file, 'audio');
});

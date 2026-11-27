import { randomInt } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import bcrypt from 'bcryptjs';
import express, { Router, type NextFunction, type Request, type Response } from 'express';
import rateLimit from 'express-rate-limit';
import helmet from 'helmet';
import jwt from 'jsonwebtoken';
import { z } from 'zod';
import { config, service, services, type RideCategory } from '../config.js';
import { HttpError, parse } from '../http.js';
import {
  DriverModel,
  PassengerModel,
  assertPhoneFreeForRole,
  documentFile,
  reviewDocument,
  vehicleDocsComplete,
  verification,
  type DriverDoc,
} from '../models/accounts.js';
import {
  CommissionEntryModel,
  LocalModel,
  PaymentRequestModel,
  NoticeModel,
  SosAlertModel,
  SubscriptionPaymentModel,
  PaymentModel,
  TicketModel,
  searchKeyOf,
} from '../models/misc.js';
import {
  AdminModel,
  AuthorityQueryModel,
  CompanyModel,
  CompanyPaymentModel,
  EXPENSE_KINDS,
  FleetExpenseModel,
  FleetHandoverModel,
  FleetModel,
  FleetShiftModel,
  FleetTermModel,
  FleetVehicleModel,
  PanelUserModel,
  type FleetDoc,
  type PanelUserDoc,
} from '../models/panel.js';
import { AgentModel, StationModel } from '../models/police.js';
import { monthStart } from '../services/corporate.js';
import { RideModel } from '../models/Ride.js';
import { emailLayout, notifyByEmail, p } from '../services/email.js';
import { sendFile } from '../services/files.js';
import { extendSubscription, payCommission, requestOut, reviewPaymentRequest } from '../services/billing.js';
import { clearSearchCache } from '../services/geo.js';
import { pushToUser } from '../services/push.js';
import {
  MAX_COMMISSION_RATE,
  NEGOTIATED,
  isNegotiated,
  monthlyFee,
  setCommissionRate,
  setMonthlyFees,
  settings,
  subscriptionState,
  setIntercityCommissionRate,
  setOtpEnabled,
  setSignupSmsEnabled,
  setFreeRides,
} from '../services/settings.js';
import { balanceOf, freeRidesLeft } from '../services/balance.js';
import { referenceMode, sessionView, settlePayment, simulationOn } from '../services/gateway.js';
import { IntercityRouteModel, IntercityTripModel } from '../models/intercity.js';
import {
  DEFAULT_SURGE,
  FARE_STEP,
  TARIFF_KEYS,
  activeSchedule,
  fareBreakdown,
  luandaClock,
  pricing,
  setSurge,
  setTariffs,
  tariffOf,
} from '../services/pricing.js';
import { smsBalance } from '../services/sms.js';
import { emitToUser } from '../services/realtime.js';
import { normalizePhone } from './auth.js';

// Painel web (HTML) para o administrador da plataforma e para as frotas.
// Usa contas próprias (colecções `administradores` e `frotas`) e tokens que
// não servem nas rotas do app, e vice-versa.

// Duas instituições usam o painel: o Bazá (administradores) e as frotas. Os
// postos policiais não têm painel: os agentes usam a aplicação (routes/agent.ts).
// Em `req.panel.id` fica o id da instituição — para o administrador, o da sua conta.
type PanelRole = 'admin' | 'fleet';
declare global {
  namespace Express {
    interface Request {
      panel: { role: PanelRole; id: string; fleet?: FleetDoc; user?: PanelUserDoc };
    }
  }
}

const objectId = z.string().regex(/^[0-9a-f]{24}$/i, 'identificador inválido');
const escapeRegex = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const ON_TRIP = ['accepted', 'arrived', 'in_progress'] as const;
const startOfDay = (daysAgo = 0) => {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  d.setDate(d.getDate() - daysAgo);
  return d;
};

const signPanel = (role: PanelRole, id: string) =>
  jwt.sign({ sub: id, panel: role }, config.jwtSecret, { expiresIn: '12h' });

function auth(...roles: PanelRole[]) {
  return async (req: Request, _res: Response, next: NextFunction) => {
    const header = req.headers.authorization ?? '';
    let payload: unknown = null;
    try {
      payload = header.startsWith('Bearer ') ? jwt.verify(header.slice(7), config.jwtSecret) : null;
    } catch {
      payload = null;
    }
    const p = payload as { sub?: string; panel?: PanelRole } | null;
    if (!p?.sub || !p.panel || !roles.includes(p.panel)) throw new HttpError(401, 'Sessão inválida. Entre novamente.');
    if (p.panel === 'admin') {
      if (!(await AdminModel.exists({ _id: p.sub }))) throw new HttpError(401, 'Sessão inválida. Entre novamente.');
      req.panel = { role: 'admin', id: p.sub };
    } else {
      // Frota ou entidade: a sessão é do utilizador; os dados são os da sua instituição.
      const user = await PanelUserModel.findById(p.sub);
      if (!user || !user.active || user.kind !== p.panel) throw new HttpError(401, 'Sessão inválida. Entre novamente.');
      const fleet = await FleetModel.findById(user.institution);
      if (!fleet) throw new HttpError(401, 'Sessão inválida. Entre novamente.');
      if (fleet.status !== 'active') {
        throw new HttpError(403, fleet.status === 'pending' ? 'A sua frota ainda está em análise.' : 'A sua frota está suspensa.');
      }
      req.panel = { role: 'fleet', id: fleet.id, fleet, user };
    }
    next();
  };
}

/**
 * Conta de administrador por defeito, só em desenvolvimento, para o painel
 * funcionar logo à primeira. Em produção nunca é criada: aí o primeiro
 * administrador vem de ADMIN_EMAIL / ADMIN_PASSWORD.
 */
export const DEFAULT_ADMIN = { email: 'admin@baza.ao', password: 'baza-admin' } as const;

/** Garante que existe pelo menos um administrador para entrar no painel. */
export async function ensureFirstAdmin() {
  if (await AdminModel.exists({})) return;
  if (config.adminEmail && config.adminPassword) {
    await AdminModel.create({
      name: 'Administrador',
      email: config.adminEmail.toLowerCase(),
      passwordHash: await bcrypt.hash(config.adminPassword, 11),
    });
    console.log(`Administrador do painel criado: ${config.adminEmail}`);
    return;
  }
  if (!config.isDev) {
    console.warn('Painel sem administrador: defina ADMIN_EMAIL e ADMIN_PASSWORD e reinicie o servidor.');
    return;
  }
  await AdminModel.create({
    name: 'Administrador',
    email: DEFAULT_ADMIN.email,
    passwordHash: await bcrypt.hash(DEFAULT_ADMIN.password, 11),
    defaultPassword: true,
  });
  console.log(
    `Administrador por defeito criado — email: ${DEFAULT_ADMIN.email} · palavra-passe: ${DEFAULT_ADMIN.password} (troque-a no painel).`,
  );
}

/**
 * As frotas registadas antes de haver utilizadores por instituição entravam com
 * o e-mail e a palavra-passe da própria frota: passam a ter um gestor com os
 * mesmos dados, para continuarem a entrar como antes.
 */
export async function ensureFleetUsers() {
  for (const fleet of await FleetModel.find({ passwordHash: { $exists: true, $ne: null } })) {
    if (await PanelUserModel.exists({ kind: 'fleet', institution: fleet._id })) continue;
    if ((await PanelUserModel.exists({ email: fleet.email })) || (await AdminModel.exists({ email: fleet.email }))) continue;
    await PanelUserModel.create({
      name: fleet.name,
      email: fleet.email,
      passwordHash: fleet.passwordHash!,
      kind: 'fleet',
      institution: fleet._id,
      role: 'manager',
    });
  }
}

/** Um e-mail só pode ter uma conta no painel, seja de que instituição for. */
async function emailTaken(email: string) {
  return Boolean((await AdminModel.exists({ email })) || (await PanelUserModel.exists({ email })));
}

export const panelApi = Router();
const loginLimiter = rateLimit({ windowMs: 10 * 60_000, limit: 20, standardHeaders: true, legacyHeaders: false });

// ── Entrar e registar frota ─────────────────────────────────────────────────
panelApi.post('/login', loginLimiter, async (req, res) => {
  const body = parse(z.object({ email: z.email(), password: z.string().min(1).max(100) }), req.body);
  const email = body.email.toLowerCase();
  const admin = await AdminModel.findOne({ email });
  if (admin && (await bcrypt.compare(body.password, admin.passwordHash))) {
    res.json({
      token: signPanel('admin', admin.id),
      role: 'admin',
      name: admin.name,
      // O painel avisa para trocar a palavra-passe por defeito.
      mustChangePassword: admin.defaultPassword,
    });
    return;
  }
  const user = await PanelUserModel.findOne({ email });
  if (user && (await bcrypt.compare(body.password, user.passwordHash))) {
    if (!user.active) throw new HttpError(403, 'O seu acesso foi desactivado. Fale com o gestor da sua instituição.');
    if (user.kind !== 'fleet') throw new HttpError(401, 'Email ou palavra-passe incorrectos.');
    const fleet = await FleetModel.findById(user.institution);
    if (!fleet) throw new HttpError(401, 'Email ou palavra-passe incorrectos.');
    if (fleet.status === 'pending') {
      throw new HttpError(403, 'O registo da sua frota está em análise. Receberá acesso assim que for aprovado.');
    }
    if (fleet.status === 'suspended') throw new HttpError(403, 'A sua frota está suspensa. Contacte o suporte do Bazá.');
    const institution = fleet.name;
    user.lastLoginAt = new Date();
    await user.save();
    res.json({
      token: signPanel('fleet', user.id),
      role: 'fleet',
      name: user.name,
      institution,
      userRole: user.role,
      mustChangePassword: user.mustChangePassword,
    });
    return;
  }
  throw new HttpError(401, 'Email ou palavra-passe incorrectos.');
});

/** Código curto e legível, sem caracteres que se confundem (0/O, 1/I). */
function newJoinCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return Array.from({ length: 6 }, () => alphabet[randomInt(alphabet.length)]).join('');
}

panelApi.post('/frotas/registo', loginLimiter, async (req, res) => {
  const body = parse(
    z.object({
      name: z.string().trim().min(2).max(80),
      nif: z.string().trim().min(5).max(20),
      email: z.email(),
      phone: z.string().min(6).max(20),
      password: z.string().min(8).max(100),
    }),
    req.body,
  );
  const email = body.email.toLowerCase();
  if ((await FleetModel.exists({ email })) || (await emailTaken(email))) {
    throw new HttpError(409, 'Já existe uma conta com este email.');
  }
  const created = await FleetModel.create({
    name: body.name,
    nif: body.nif,
    email,
    phone: normalizePhone(body.phone),
    joinCode: newJoinCode(),
  });
  // Quem regista a frota é o seu primeiro gestor.
  await PanelUserModel.create({
    name: body.name,
    email,
    passwordHash: await bcrypt.hash(body.password, 11),
    kind: 'fleet',
    institution: created._id,
    role: 'manager',
  });
  res.status(201).json({ ok: true });
});

// ── Dados partilhados por administrador e frota ─────────────────────────────

/** Linha de um motorista nas tabelas do painel. */
async function driverRows(drivers: DriverDoc[]) {
  const ids = drivers.map((d) => d._id);
  const [busy, today] = await Promise.all([
    RideModel.distinct('driver', { driver: { $in: ids }, status: { $in: ON_TRIP } }),
    RideModel.aggregate<{ _id: unknown; rides: number; total: number }>([
      { $match: { driver: { $in: ids }, status: 'completed', completedAt: { $gte: startOfDay() } } },
      { $group: { _id: '$driver', rides: { $sum: 1 }, total: { $sum: '$fare' } } },
    ]),
  ]);
  const busySet = new Set(busy.map(String));
  const todayBy = new Map(today.map((t) => [String(t._id), t]));
  return drivers.map((d) => {
    const coords = d.location?.coordinates;
    return {
      id: d.id as string,
      name: d.name || '(sem nome)',
      photoUrl: d.photo ? `/uploads/${d.photo}` : null,
      phone: d.phone ?? null,
      phoneVerified: d.phoneVerified !== false,
      email: d.email ?? null,
      fleet: d.fleetName ?? null,
      verification: verification(d),
      blocked: d.blocked,
      blockedReason: d.blockedReason ?? null,
      star: !!d.star,
      online: d.isOnline,
      onTrip: busySet.has(d.id),
      vehicle: d.vehicle
        ? {
            label: `${d.vehicle.make} ${d.vehicle.carModel}`,
            plate: d.vehicle.plate,
            color: d.vehicle.color,
            category: service(d.vehicle.category).label,
          }
        : null,
      rating: d.ratingCount ? Math.round((d.ratingSum / d.ratingCount) * 10) / 10 : null,
      ridesToday: todayBy.get(d.id)?.rides ?? 0,
      revenueToday: todayBy.get(d.id)?.total ?? 0,
      position: d.isOnline && coords?.length === 2 ? { lat: coords[1], lng: coords[0] } : null,
      positionAt: d.locationUpdatedAt ?? null,
      createdAt: d.get('createdAt') as Date,
    };
  });
}

async function rideRows(filter: Record<string, unknown>) {
  const rides = await RideModel.find(filter)
    .sort({ createdAt: -1 })
    .limit(100)
    .populate<{ passenger: { name: string } | null }>('passenger', 'name')
    .populate<{ driver: { name: string } | null }>('driver', 'name');
  return rides.map((r) => ({
    id: r.id as string,
    createdAt: r.get('createdAt') as Date,
    passenger: r.passenger?.name || '—',
    driver: r.driver?.name || '—',
    service: service(r.category).label,
    from: r.pickup.address,
    to: r.dropoff.address,
    status: r.status,
    fare: r.fare,
    commission: r.commission,
    payment: r.paymentMethod,
  }));
}

async function totals(match: Record<string, unknown>) {
  const [t] = await RideModel.aggregate<{ rides: number; revenue: number; commission: number }>([
    { $match: { ...match, status: 'completed' } },
    { $group: { _id: null, rides: { $sum: 1 }, revenue: { $sum: '$fare' }, commission: { $sum: '$commission' } } },
  ]);
  return { rides: t?.rides ?? 0, revenue: t?.revenue ?? 0, commission: t?.commission ?? 0 };
}

/** Corridas concluídas e valor por dia, nos últimos 7 dias (para o gráfico do resumo). */
async function lastDays() {
  const out: { date: string; rides: number; revenue: number }[] = [];
  for (let i = 6; i >= 0; i--) {
    const from = startOfDay(i);
    const to = i === 0 ? new Date() : startOfDay(i - 1);
    const t = await totals({ completedAt: { $gte: from, $lt: to } });
    out.push({ date: from.toISOString(), rides: t.rides, revenue: t.revenue });
  }
  return out;
}

const pendingReviewFilter = {
  $or: [
    { 'license.status': 'pending', 'license.frontPhoto': { $exists: true }, 'license.backPhoto': { $exists: true } },
    {
      vehicles: {
        $elemMatch: {
          status: 'pending',
          registrationPhoto: { $exists: true },
          ownershipPhoto: { $exists: true },
          insurancePhoto: { $exists: true },
        },
      },
    },
  ],
};

// ── Administrador ───────────────────────────────────────────────────────────
const admin = Router();
admin.use(auth('admin'));

admin.get('/resumo', async (_req, res) => {
  const [passengers, drivers, online, pendingDocs, pendingFleets, onTrip, sosToday, today, week, openTickets, placesToReview, pendingPayments, commissionDue] = await Promise.all([
    PassengerModel.countDocuments(),
    DriverModel.countDocuments(),
    DriverModel.countDocuments({ isOnline: true }),
    DriverModel.countDocuments(pendingReviewFilter),
    FleetModel.countDocuments({ status: 'pending' }),
    RideModel.countDocuments({ status: { $in: ON_TRIP } }),
    SosAlertModel.countDocuments({ createdAt: { $gte: startOfDay() } }),
    totals({ completedAt: { $gte: startOfDay() } }),
    totals({ completedAt: { $gte: startOfDay(6) } }),
    TicketModel.countDocuments({ status: 'open' }),
    LocalModel.countDocuments({ reviewed: false }),
    PaymentRequestModel.countDocuments({ status: 'pending' }),
    DriverModel.aggregate<{ total: number }>([{ $group: { _id: null, total: { $sum: '$commissionDue' } } }]),
  ]);
  // Saldo de SMS (códigos de confirmação); null se os SMS não forem reais.
  const sms = await smsBalance();
  res.json({
    passengers,
    drivers,
    online,
    pendingDocs,
    pendingFleets,
    onTrip,
    sosToday,
    today,
    week,
    sms,
    openTickets,
    placesToReview,
    pendingPayments,
    commissionDue: commissionDue[0]?.total ?? 0,
    commissionRate: settings.commissionRate,
    days: await lastDays(),
  });
});

admin.get('/motoristas', async (req, res) => {
  const q = parse(z.object({ q: z.string().trim().max(60).optional() }), req.query);
  const rx = q.q ? new RegExp(escapeRegex(q.q), 'i') : null;
  const filter = rx ? { $or: [{ name: rx }, { phone: rx }, { email: rx }, { 'vehicle.plate': rx }, { fleetName: rx }] } : {};
  res.json({ drivers: await driverRows(await DriverModel.find(filter).sort({ createdAt: -1 }).limit(200)) });
});

admin.post('/motoristas/:id/bloqueio', async (req, res) => {
  const body = parse(z.object({ blocked: z.boolean(), reason: z.string().trim().max(300).optional() }), req.body);
  const driver = await DriverModel.findById(parse(objectId, req.params.id));
  if (!driver) throw new HttpError(404, 'Motorista não encontrado.');
  // Suspender exige um motivo: fica registado e é o que o motorista lê.
  if (body.blocked && (body.reason ?? '').length < 5) throw new HttpError(400, 'Escreva o motivo da suspensão.');
  driver.blocked = body.blocked;
  if (body.blocked) {
    driver.isOnline = false;
    driver.blockedReason = body.reason;
    driver.blockedAt = new Date();
    driver.blockedBy = (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador';
  } else {
    driver.blockedReason = undefined;
    driver.blockedAt = undefined;
    driver.blockedBy = undefined;
  }
  await driver.save();
  emitToUser(driver.id, 'account:update', {});
  res.json({ ok: true });
});

/** Ficha do motorista: tudo o que a equipa precisa de rever antes de o suspender ou reactivar. */
admin.get('/motoristas/:id', async (req, res) => {
  const d = await DriverModel.findById(parse(objectId, req.params.id));
  if (!d) throw new HttpError(404, 'Motorista não encontrado.');
  res.json(await driverFileData(d));
});

async function driverFileData(d: DriverDoc) {
  const since30 = startOfDay(30);
  const [done, cancelled, lateCancelled, last30, lowRatings, sos, tickets, recent] = await Promise.all([
    totals({ driver: d._id }),
    RideModel.countDocuments({ driver: d._id, status: 'cancelled', cancelledBy: 'driver' }),
    RideModel.countDocuments({ driver: d._id, status: 'cancelled', cancelledBy: 'driver', lateCancel: true }),
    totals({ driver: d._id, completedAt: { $gte: since30 } }),
    RideModel.countDocuments({ driver: d._id, driverRating: { $lte: 2 } }),
    SosAlertModel.countDocuments({ ride: { $in: await RideModel.find({ driver: d._id }).distinct('_id') } }),
    TicketModel.find({ account: d._id }).sort({ createdAt: -1 }).limit(5),
    RideModel.find({ driver: d._id }).sort({ createdAt: -1 }).limit(8),
  ]);
  const expired = (date?: Date | null) => !!date && date.getTime() < Date.now();
  return {
    id: d.id,
    name: d.name || '(sem nome)',
    phone: d.phone ?? null,
    email: d.email ?? null,
    photoUrl: d.photo ? `/uploads/${d.photo}` : null,
    createdAt: d.get('createdAt') as Date,
    fleet: d.fleetName ?? null,
    star: !!d.star,
    online: d.isOnline,
    verification: verification(d),
    blocked: d.blocked,
    blockedReason: d.blockedReason ?? null,
    blockedAt: d.blockedAt ?? null,
    blockedBy: d.blockedBy ?? null,
    rating: d.ratingCount ? Math.round((d.ratingSum / d.ratingCount) * 10) / 10 : null,
    ratingCount: d.ratingCount,
    commissionDue: d.commissionDue,
    license: d.license
      ? {
          number: d.license.number,
          category: d.license.category,
          expiresAt: d.license.expiresAt,
          expired: expired(d.license.expiresAt),
          status: d.license.status,
          note: d.license.reviewNote ?? null,
          photos: [d.license.frontPhoto ? ['carta-frente', 'Frente'] : null, d.license.backPhoto ? ['carta-verso', 'Verso'] : null].filter(Boolean),
        }
      : null,
    vehicles: d.vehicles.map((v) => ({
      id: String(v._id),
      label: `${v.make} ${v.carModel}`,
      color: v.color,
      plate: v.plate,
      category: service(v.category).label,
      active: d.vehicle?.id === String(v._id),
      status: v.status,
      note: v.reviewNote ?? null,
      insuranceExpiresAt: v.insuranceExpiresAt ?? null,
      insuranceExpired: expired(v.insuranceExpiresAt),
      photos: [
        v.registrationPhoto ? [`livrete-${String(v._id)}`, 'Livrete'] : null,
        v.ownershipPhoto ? [`titulo-${String(v._id)}`, 'Título'] : null,
        v.insurancePhoto ? [`seguro-${String(v._id)}`, 'Seguro'] : null,
      ].filter(Boolean),
    })),
    stats: {
      rides: done.rides,
      revenue: done.revenue,
      rides30: last30.rides,
      cancelled,
      lateCancelled,
      lowRatings,
      sos,
    },
    tickets: tickets.map((t) => ({ category: t.category, message: t.message, status: t.status, createdAt: t.get('createdAt') as Date })),
    recent: recent.map((r) => ({
      createdAt: r.get('createdAt') as Date,
      from: r.pickup?.address ?? '',
      to: r.dropoff?.address ?? '',
      status: r.status,
      fare: r.fare,
      rating: r.driverRating ?? null,
      cancelledBy: r.cancelledBy ?? null,
    })),
  };
}

// Utilizador estrela: pode registar locais no mapa a partir do app.
for (const kind of ['motoristas', 'passageiros'] as const) {
  admin.post(`/${kind}/:id/estrela`, async (req, res) => {
    const body = parse(z.object({ star: z.boolean() }), req.body);
    const id = parse(objectId, req.params.id);
    const account = kind === 'motoristas' ? await DriverModel.findById(id) : await PassengerModel.findById(id);
    if (!account) throw new HttpError(404, 'Conta não encontrada.');
    account.star = body.star;
    await account.save();
    emitToUser(account.id, 'account:update', {});
    res.json({ ok: true });
  });
}

// Repor a senha de uma conta: para quem a esqueceu e não recebe o código SMS.
// A senha provisória aparece uma só vez, para a equipa a dizer ao utilizador.
for (const kind of ['motoristas', 'passageiros'] as const) {
  admin.post(`/${kind}/:id/senha`, async (req, res) => {
    const id = parse(objectId, req.params.id);
    const account = kind === 'motoristas' ? await DriverModel.findById(id) : await PassengerModel.findById(id);
    if (!account) throw new HttpError(404, 'Conta não encontrada.');
    const temporary = String(randomInt(0, 100_000_000)).padStart(8, '0');
    account.passwordHash = await bcrypt.hash(temporary, 11);
    await account.save();
    console.log(`Senha reposta no painel (${kind}, conta ${account.id}).`);
    res.json({ password: temporary });
  });
}

// ── Postos policiais e agentes ──────────────────────────────────────────────
// Os agentes usam a aplicação (routes/agent.ts); aqui o administrador regista-os.
const queryOut = (q: InstanceType<typeof AuthorityQueryModel>) => ({
  createdAt: q.get('createdAt') as Date,
  authority: q.authorityName ?? '',
  user: q.userName ?? '',
  kind: q.kind,
  target: q.target,
  reason: q.reason,
  results: q.results,
});

const stationBody = z.object({
  name: z.string().trim().min(3).max(100),
  province: z.string().trim().min(2).max(40),
  municipality: z.string().trim().max(60).default(''),
  phone: z.string().trim().max(20).default(''),
  lat: z.coerce.number().min(-90).max(90),
  lng: z.coerce.number().min(-180).max(180),
  command: z.coerce.boolean().default(false),
});
const stationPhone = (raw: string) => (raw ? normalizePhone(raw) : '');

/** Postos policiais (com os seus agentes) e o registo do que os agentes consultaram. */
admin.get('/postos', async (_req, res) => {
  const [stations, agents, queries, open] = await Promise.all([
    StationModel.find().sort({ province: 1, municipality: 1, name: 1 }),
    AgentModel.find().sort({ name: 1 }),
    AuthorityQueryModel.find().sort({ createdAt: -1 }).limit(80),
    SosAlertModel.countDocuments({ status: { $ne: 'closed' } }),
  ]);
  res.json({
    openAlerts: open,
    stations: stations.map((s) => ({
      id: s.id as string,
      name: s.name,
      province: s.province,
      municipality: s.municipality,
      phone: s.phone,
      lat: s.lat,
      lng: s.lng,
      command: s.command,
      active: s.active,
      agents: agents
        .filter((a) => String(a.station) === s.id)
        .map((a) => ({
          id: a.id as string,
          name: a.name,
          rank: a.rank,
          phone: a.phone,
          active: a.active,
          onDuty: a.onDuty,
          hasDevice: Boolean(a.deviceId),
          lastLoginAt: a.lastLoginAt ?? null,
        })),
    })),
    queries: queries.map(queryOut),
  });
});

admin.post('/postos', async (req, res) => {
  const body = parse(stationBody, req.body);
  const created = await StationModel.create({ ...body, phone: stationPhone(body.phone) });
  res.status(201).json({ id: created.id });
});

admin.post('/postos/:id', async (req, res) => {
  const body = parse(stationBody.extend({ active: z.coerce.boolean().default(true) }), req.body);
  const s = await StationModel.findByIdAndUpdate(parse(objectId, req.params.id), { ...body, phone: stationPhone(body.phone) });
  if (!s) throw new HttpError(404, 'Posto não encontrado.');
  // Posto desactivado: os seus agentes deixam de estar de serviço.
  if (!body.active) await AgentModel.updateMany({ station: s._id }, { onDuty: false });
  res.json({ ok: true });
});

admin.delete('/postos/:id', async (req, res) => {
  const id = parse(objectId, req.params.id);
  if (await AgentModel.exists({ station: id })) throw new HttpError(409, 'Este posto tem agentes registados. Remova-os primeiro, ou desactive o posto.');
  await StationModel.deleteOne({ _id: id });
  res.json({ ok: true });
});

/** Regista um agente num posto. O número fica exclusivo: não pode ter conta de passageiro nem de motorista. */
admin.post('/postos/:id/agentes', async (req, res) => {
  const body = parse(
    z.object({ name: z.string().trim().min(2).max(80), rank: z.string().trim().max(40).default(''), phone: z.string().min(6).max(20) }),
    req.body,
  );
  const station = await StationModel.findById(parse(objectId, req.params.id));
  if (!station) throw new HttpError(404, 'Posto não encontrado.');
  const phone = normalizePhone(body.phone);
  if (await AgentModel.exists({ phone })) throw new HttpError(409, 'Já existe um agente com este número.');
  if ((await PassengerModel.exists({ phone })) || (await DriverModel.exists({ phone }))) {
    throw new HttpError(409, 'Este número já tem conta de passageiro ou de motorista. O número de um agente tem de ser exclusivo: use outro, ou peça à pessoa para eliminar essa conta no app.');
  }
  await AgentModel.create({ name: body.name, rank: body.rank, phone, station: station._id });
  res.status(201).json({ ok: true });
});

/** Activar ou desactivar um agente, ou autorizar a entrada num telemóvel novo. */
admin.post('/agentes/:id', async (req, res) => {
  const body = parse(z.object({ active: z.boolean().optional(), resetDevice: z.boolean().optional(), resetPassword: z.boolean().optional() }), req.body);
  const agent = await AgentModel.findById(parse(objectId, req.params.id));
  if (!agent) throw new HttpError(404, 'Agente não encontrado.');
  if (body.active !== undefined) {
    agent.active = body.active;
    if (!body.active) agent.onDuty = false;
  }
  if (body.resetDevice) agent.deviceId = undefined;
  // Senha esquecida: o agente escolhe outra na próxima entrada (depois do código SMS).
  if (body.resetPassword) agent.set('passwordHash', undefined);
  await agent.save();
  res.json({ ok: true });
});

admin.delete('/agentes/:id', async (req, res) => {
  const result = await AgentModel.deleteOne({ _id: parse(objectId, req.params.id) });
  if (!result.deletedCount) throw new HttpError(404, 'Agente não encontrado.');
  res.json({ ok: true });
});

// ── Avisos enviados pela equipa a passageiros e motoristas ──────────────────
admin.post('/avisos', async (req, res) => {
  const body = parse(
    z.object({
      kind: z.enum(['motoristas', 'passageiros']),
      /** Sem `id`, o aviso vai para todos os motoristas ou todos os passageiros. */
      id: objectId.optional(),
      title: z.string().trim().min(3).max(80),
      message: z.string().trim().min(5).max(600),
    }),
    req.body,
  );
  const role = body.kind === 'motoristas' ? ('driver' as const) : ('passenger' as const);
  const Model = (role === 'driver' ? DriverModel : PassengerModel) as typeof PassengerModel;
  const ids = body.id ? (await Model.exists({ _id: body.id }) ? [body.id] : []) : (await Model.find().distinct('_id')).map(String);
  if (!ids.length) throw new HttpError(404, body.id ? 'Conta não encontrada.' : 'Ainda não há contas a quem enviar.');
  const sentBy = (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador';
  const created = await NoticeModel.insertMany(
    ids.map((account) => ({ account, role, title: body.title, message: body.message, sentBy, broadcast: !body.id })),
  );
  for (const n of created) emitToUser(String(n.account), 'notice:new', { id: n.id, title: n.title, message: n.message });
  res.status(201).json({ sent: created.length });
});

/** Avisos enviados (os de envio geral aparecem uma vez, com quantos já leram). */
admin.get('/avisos', async (_req, res) => {
  const list = await NoticeModel.find().sort({ createdAt: -1 }).limit(400);
  const names = new Map<string, string>();
  for (const M of [DriverModel, PassengerModel] as (typeof PassengerModel)[]) {
    for (const a of await M.find({ _id: { $in: list.filter((n) => !n.broadcast).map((n) => n.account) } }).select('name phone')) {
      names.set(a.id, a.name || a.phone || '(sem nome)');
    }
  }
  const out: { key: string; createdAt: Date; role: string; to: string; title: string; message: string; sentBy: string; sent: number; read: number }[] = [];
  const groups = new Map<string, (typeof out)[number]>();
  for (const n of list) {
    const createdAt = n.get('createdAt') as Date;
    // Um envio geral cria um aviso por conta: junta-se pelo minuto, título e destinatários.
    const key = n.broadcast ? `${n.role}|${n.title}|${Math.floor(createdAt.getTime() / 60_000)}` : n.id;
    let g = groups.get(key);
    if (!g) {
      g = {
        key,
        createdAt,
        role: n.role,
        to: n.broadcast ? (n.role === 'driver' ? 'Todos os motoristas' : 'Todos os passageiros') : (names.get(String(n.account)) ?? '(conta eliminada)'),
        title: n.title,
        message: n.message,
        sentBy: n.sentBy ?? '',
        sent: 0,
        read: 0,
      };
      groups.set(key, g);
      out.push(g);
    }
    g.sent += 1;
    if (n.readAt) g.read += 1;
  }
  res.json({ notices: out.slice(0, 60) });
});

// ── Táxi intermunicipal: rotas, preços e viagens publicadas ─────────────────
const rotaBody = z.object({
  from: z.string().trim().min(2).max(60),
  to: z.string().trim().min(2).max(60),
  price: z.coerce.number().int().min(100).max(1_000_000),
  /** Vazio ou 0: preço fixo. */
  maxPrice: z.preprocess((v) => (v === '' || v === null || v === undefined ? undefined : v), z.coerce.number().int().min(0).max(1_000_000).optional()),
  distanceKm: z.preprocess((v) => (v === '' || v === null || v === undefined ? undefined : v), z.coerce.number().min(0).max(5000).optional()),
  active: z.boolean().default(true),
});
const sameRoute = (a: string, b: string) => a.localeCompare(b, 'pt', { sensitivity: 'base' }) === 0;

admin.get('/intermunicipal', async (_req, res) => {
  const [routes, trips] = await Promise.all([
    IntercityRouteModel.find().sort({ from: 1, to: 1 }),
    IntercityTripModel.find().sort({ departAt: -1 }).limit(60),
  ]);
  res.json({
    commissionRate: settings.intercityCommissionRate,
    routes: routes.map((r) => ({
      id: r.id,
      from: r.from,
      to: r.to,
      price: r.price,
      maxPrice: r.maxPrice ?? null,
      distanceKm: r.distanceKm ?? null,
      active: r.active,
    })),
    trips: trips.map((t) => ({
      id: t.id,
      from: t.from,
      to: t.to,
      departAt: t.departAt,
      driver: t.driverName ?? '—',
      phone: t.driverPhone ?? null,
      vehicle: t.vehicle?.plate ? `${t.vehicle.label} · ${t.vehicle.plate}` : '—',
      seats: t.seats,
      seatsTaken: t.seatsTaken,
      pending: t.bookings.filter((b) => b.status === 'pending').length,
      price: t.price,
      status: t.status,
      commission: t.commission,
    })),
  });
});

admin.post('/intermunicipal/rotas', async (req, res) => {
  const body = parse(rotaBody, req.body);
  if (sameRoute(body.from, body.to)) throw new HttpError(400, 'A origem e o destino têm de ser diferentes.');
  if (body.maxPrice && body.maxPrice < body.price) throw new HttpError(400, 'O preço máximo não pode ser inferior ao preço da rota.');
  const all = await IntercityRouteModel.find();
  // Uma rota serve nos dois sentidos: "Soyo → Mbanza Kongo" é a mesma que "Mbanza Kongo → Soyo".
  if (all.some((r) => (sameRoute(r.from, body.from) && sameRoute(r.to, body.to)) || (sameRoute(r.from, body.to) && sameRoute(r.to, body.from)))) {
    throw new HttpError(409, 'Essa rota já existe (cada rota serve nos dois sentidos).');
  }
  const route = await IntercityRouteModel.create({ ...body, maxPrice: body.maxPrice || undefined });
  res.status(201).json({ id: route.id });
});

admin.post('/intermunicipal/rotas/:id', async (req, res) => {
  const body = parse(rotaBody.pick({ price: true, maxPrice: true, distanceKm: true, active: true }), req.body);
  if (body.maxPrice && body.maxPrice < body.price) throw new HttpError(400, 'O preço máximo não pode ser inferior ao preço da rota.');
  const route = await IntercityRouteModel.findById(parse(objectId, req.params.id));
  if (!route) throw new HttpError(404, 'Rota não encontrada.');
  route.price = body.price;
  route.maxPrice = body.maxPrice || undefined;
  route.distanceKm = body.distanceKm;
  route.active = body.active;
  await route.save();
  res.json({ ok: true });
});

admin.delete('/intermunicipal/rotas/:id', async (req, res) => {
  const id = parse(objectId, req.params.id);
  if (await IntercityTripModel.exists({ route: id, status: { $in: ['open', 'departed'] } })) {
    throw new HttpError(409, 'Há viagens publicadas nesta rota. Desactive-a em vez de a apagar.');
  }
  await IntercityRouteModel.deleteOne({ _id: id });
  res.json({ ok: true });
});

admin.post('/intermunicipal/comissao', async (req, res) => {
  const body = parse(z.object({ percent: z.coerce.number().min(0).max(MAX_COMMISSION_RATE * 100) }), req.body);
  const rate = Math.round(body.percent * 10) / 1000;
  await setIntercityCommissionRate(rate, (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador');
  res.json({ rate });
});

// Entrada no app: com ou sem código SMS.
admin.get('/acesso', async (_req, res) => {
  const [passengers, drivers] = await Promise.all(
    [PassengerModel, DriverModel].map(async (M) => ({
      total: await (M as typeof PassengerModel).countDocuments({}),
      withPassword: await (M as typeof PassengerModel).countDocuments({ passwordHash: { $exists: true, $ne: null } }),
      unverified: await (M as typeof PassengerModel).countDocuments({ phoneVerified: false }),
    })),
  );
  res.json({ otp: settings.otpEnabled, signupSms: settings.signupSmsEnabled, passengers, drivers });
});

admin.post('/acesso', async (req, res) => {
  const body = parse(z.object({ otp: z.boolean().optional(), signupSms: z.boolean().optional() }), req.body);
  const by = (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador';
  if (body.otp !== undefined) await setOtpEnabled(body.otp, by);
  if (body.signupSms !== undefined) await setSignupSmsEnabled(body.signupSms, by);
  res.json({ otp: settings.otpEnabled, signupSms: settings.signupSmsEnabled });
});

/** Documentos à espera de revisão. */
admin.get('/revisoes', async (_req, res) => {
  const drivers = await DriverModel.find(pendingReviewFilter).sort({ updatedAt: 1 }).limit(100);
  res.json({
    drivers: drivers.map((d) => ({
      id: d.id as string,
      name: d.name || '(sem nome)',
      phone: d.phone ?? d.email ?? null,
      fleet: d.fleetName ?? null,
      photoUrl: d.photo ? `/uploads/${d.photo}` : null,
      license:
        d.license?.frontPhoto && d.license.backPhoto && d.license.status === 'pending'
          ? { number: d.license.number, category: d.license.category, expiresAt: d.license.expiresAt }
          : null,
      vehicles: d.vehicles
        .filter((v) => vehicleDocsComplete(v) && v.status === 'pending')
        .map((v) => ({
          id: String(v._id),
          label: `${v.make} ${v.carModel}`,
          color: v.color,
          plate: v.plate,
          category: service(v.category).label,
          insuranceExpiresAt: v.insuranceExpiresAt ?? null,
        })),
    })),
  });
});

/** :doc = "carta-frente", "carta-verso", ou "livrete-", "titulo-" ou "seguro-" seguido do id da viatura. */
admin.get('/documentos/:id/:doc', async (req, res) => {
  const driver = await DriverModel.findById(parse(objectId, req.params.id));
  if (!driver) throw new HttpError(404, 'Motorista não encontrado.');
  await sendDriverDocument(res, driver, String(req.params.doc));
});

async function sendDriverDocument(res: Response, driver: DriverDoc, doc: string) {
  const kinds = { livrete: 'registration', titulo: 'ownership', seguro: 'insurance' } as const;
  const [prefix, vehicleId] = doc.split('-') as [keyof typeof kinds, string | undefined];
  const file =
    prefix in kinds
      ? documentFile(driver, { vehicleId: parse(objectId, vehicleId), doc: kinds[prefix] })
      : documentFile(driver, { license: doc === 'carta-frente' ? 'front' : 'back' });
  await sendFile(res, file, 'document');
}

admin.post('/revisoes/:id', async (req, res) => {
  const body = parse(
    z.object({
      /** "carta" ou o id da viatura cujo livrete se está a rever. */
      target: z.union([z.literal('carta'), objectId]),
      approve: z.boolean(),
      note: z.string().trim().max(200).optional(),
    }),
    req.body,
  );
  if (!body.approve && !body.note) throw new HttpError(400, 'Indique o motivo da rejeição.');
  const driver = await DriverModel.findById(parse(objectId, req.params.id));
  if (!driver) throw new HttpError(404, 'Motorista não encontrado.');
  reviewDocument(driver, body.target === 'carta' ? 'license' : { vehicleId: body.target }, body.approve, body.note);
  // Com um documento rejeitado o motorista deixa de receber pedidos.
  if (verification(driver) !== 'approved') driver.isOnline = false;
  await driver.save();
  emitToUser(driver.id, 'account:update', {});
  if (!body.approve) {
    notifyByEmail(
      driver.email,
      'Bazá: um documento precisa de ser corrigido',
      emailLayout(
        'Documento não aceite',
        p(`${body.target === 'carta' ? 'A sua carta de condução não foi aceite' : 'Os documentos de uma das suas viaturas não foram aceites'}. Motivo: ${body.note}`) +
          p('Abra o app e envie uma nova fotografia para voltar a receber corridas.'),
      ),
    );
  }
  res.json({ ok: true });
});

admin.get('/passageiros', async (req, res) => {
  const q = parse(z.object({ q: z.string().trim().max(60).optional() }), req.query);
  const rx = q.q ? new RegExp(escapeRegex(q.q), 'i') : null;
  const list = await PassengerModel.find(rx ? { $or: [{ name: rx }, { phone: rx }, { email: rx }] } : {})
    .sort({ createdAt: -1 })
    .limit(200);
  const counts = await RideModel.aggregate<{ _id: unknown; n: number }>([
    { $match: { passenger: { $in: list.map((p) => p._id) }, status: 'completed' } },
    { $group: { _id: '$passenger', n: { $sum: 1 } } },
  ]);
  const by = new Map(counts.map((c) => [String(c._id), c.n]));
  res.json({
    passengers: list.map((p) => ({
      id: p.id as string,
      name: p.name || '(sem nome)',
      photoUrl: p.photo ? `/uploads/${p.photo}` : null,
      phone: p.phone ?? p.formerPhone ?? null,
      /** Desactivada (o número era também de um motorista): não entra no app. */
      deactivated: Boolean(p.deactivatedAt),
      /** false: conta criada quando o SMS falhou; o número está por confirmar. */
      phoneVerified: p.phoneVerified !== false,
      email: p.email ?? null,
      star: !!p.star,
      rides: by.get(p.id) ?? 0,
      rating: p.ratingCount ? Math.round((p.ratingSum / p.ratingCount) * 10) / 10 : null,
      createdAt: p.get('createdAt') as Date,
    })),
  });
});

admin.get('/corridas', async (_req, res) => {
  res.json({ rides: await rideRows({}) });
});

/** Alertas SOS, com quem accionou, a posição e a corrida em que aconteceu. */
async function sosRows(filter: Record<string, unknown>) {
  const alerts = await SosAlertModel.find(filter).sort({ createdAt: -1 }).limit(100);
  const [passengers, drivers, rides] = await Promise.all([
    PassengerModel.find({ _id: { $in: alerts.filter((a) => a.role === 'passenger').map((a) => a.user) } }),
    DriverModel.find({ _id: { $in: alerts.filter((a) => a.role === 'driver').map((a) => a.user) } }),
    RideModel.find({ _id: { $in: alerts.map((a) => a.ride) } })
      .populate('driver', 'name phone vehicle')
      .populate('passenger', 'name phone'),
  ]);
  const people = new Map([...passengers, ...drivers].map((p) => [p.id as string, p]));
  const rideBy = new Map(rides.map((r) => [r.id as string, r]));
  type Party = { name?: string; phone?: string; vehicle?: { plate?: string } } | null;
  return alerts.map((a) => {
    const who = people.get(String(a.user));
    const r = rideBy.get(String(a.ride));
    const driver = r?.driver as unknown as Party;
    const passenger = r?.passenger as unknown as Party;
    return {
      id: a.id as string,
      createdAt: a.get('createdAt') as Date,
      role: a.role,
      name: who?.name || '—',
      phone: who?.phone ?? who?.email ?? null,
      ride: String(a.ride),
      lat: a.lat ?? null,
      lng: a.lng ?? null,
      open: a.status !== 'closed',
      closedAt: a.closedAt ?? null,
      closedBy: a.closedBy ?? null,
      closeNote: a.closeNote ?? null,
      // A corrida em que o alerta foi dado, para se saber quem ia com quem.
      trip: r
        ? {
            from: r.pickup?.address ?? '',
            to: r.dropoff?.address ?? '',
            driver: driver?.name || '—',
            driverPhone: driver?.phone ?? null,
            passenger: passenger?.name || '—',
            passengerPhone: passenger?.phone ?? null,
            // Viatura que o motorista tem activa agora (a corrida não guarda a matrícula).
            plate: driver?.vehicle?.plate ?? null,
          }
        : null,
    };
  });
}

admin.get('/sos', async (_req, res) => {
  res.json({ alerts: await sosRows({}) });
});

admin.get('/frotas', async (_req, res) => {
  const fleets = await FleetModel.find().sort({ createdAt: -1 }).limit(200);
  const counts = await DriverModel.aggregate<{ _id: unknown; n: number }>([
    { $match: { fleet: { $in: fleets.map((f) => f._id) } } },
    { $group: { _id: '$fleet', n: { $sum: 1 } } },
  ]);
  const by = new Map(counts.map((c) => [String(c._id), c.n]));
  res.json({
    fleets: fleets.map((f) => ({
      id: f.id as string,
      name: f.name,
      nif: f.nif,
      email: f.email,
      phone: f.phone,
      status: f.status,
      drivers: by.get(f.id) ?? 0,
      createdAt: f.get('createdAt') as Date,
    })),
  });
});

admin.post('/frotas/:id/estado', async (req, res) => {
  const body = parse(z.object({ status: z.enum(['active', 'suspended']) }), req.body);
  const fleet = await FleetModel.findByIdAndUpdate(parse(objectId, req.params.id), { status: body.status });
  if (!fleet) throw new HttpError(404, 'Frota não encontrada.');
  if (body.status === 'active' && fleet.status !== 'active') {
    notifyByEmail(
      fleet.email,
      'Bazá: a sua frota foi aprovada',
      emailLayout(
        'Frota aprovada',
        p(`A frota ${fleet.name} foi aprovada. Já pode entrar no painel com o seu e-mail e palavra-passe, registar motoristas e acompanhá-los no mapa.`),
      ),
    );
  }
  res.json({ ok: true });
});

// Contas de administrador
// ── Locais registados (pontos conhecidos por província) ──
const localBody = z.object({
  name: z.string().trim().min(2).max(80),
  zone: z.string().trim().max(60).default(''),
  province: z.string().trim().min(2).max(40),
  lat: z.coerce.number().min(-18.2).max(-4.2),
  lng: z.coerce.number().min(11.4).max(24.2),
});

admin.get('/locais', async (req, res) => {
  const q = parse(z.object({ q: z.string().trim().max(60).optional(), provincia: z.string().trim().max(40).optional(), porRever: z.string().optional() }), req.query);
  const filter: Record<string, unknown> = {};
  if (q.provincia) filter.province = q.provincia;
  if (q.porRever) filter.reviewed = false;
  if (q.q) filter.searchKey = new RegExp(searchKeyOf(q.q).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  const [locais, provinces, total, toReview] = await Promise.all([
    LocalModel.find(filter).sort({ province: 1, zone: 1, name: 1 }).limit(500).lean(),
    LocalModel.aggregate<{ _id: string; n: number }>([{ $group: { _id: '$province', n: { $sum: 1 } } }, { $sort: { _id: 1 } }]),
    LocalModel.countDocuments(),
    LocalModel.countDocuments({ reviewed: false }),
  ]);
  res.json({
    total,
    toReview,
    needApproval: config.starPlacesNeedApproval,
    provinces: provinces.map((p) => ({ name: p._id, count: p.n })),
    locais: locais.map((l) => ({
      id: String(l._id),
      name: l.name,
      zone: l.zone,
      province: l.province,
      lat: l.lat,
      lng: l.lng,
      addedBy: l.addedByName ?? null,
      reviewed: l.reviewed !== false,
    })),
  });
});

admin.post('/locais', async (req, res) => {
  const body = parse(localBody, req.body);
  const searchKey = searchKeyOf(`${body.name} ${body.zone}`);
  if (await LocalModel.exists({ searchKey, province: body.province })) {
    throw new HttpError(409, 'Já existe um local com este nome e zona nesta província.');
  }
  const local = await LocalModel.create({ ...body, searchKey });
  clearSearchCache();
  res.status(201).json({ id: local.id });
});

admin.delete('/locais/:id', async (req, res) => {
  const result = await LocalModel.deleteOne({ _id: parse(objectId, req.params.id) });
  if (!result.deletedCount) throw new HttpError(404, 'Local não encontrado.');
  clearSearchCache();
  res.json({ ok: true });
});

// ── Comissões: dívida de cada motorista e pagamentos recebidos ──
admin.get('/comissoes', async (_req, res) => {
  const [owing, total, entries] = await Promise.all([
    DriverModel.find({ commissionDue: { $gt: 0 } }).sort({ commissionDue: -1 }).limit(300),
    DriverModel.aggregate<{ total: number }>([{ $match: { commissionDue: { $gt: 0 } } }, { $group: { _id: null, total: { $sum: '$commissionDue' } } }]),
    CommissionEntryModel.find({ type: { $in: ['payment', 'payout'] } }).sort({ createdAt: -1 }).limit(30).populate('driver', 'name'),
  ]);
  // Motoristas a quem o Bazá deve (corridas por conta de empresas): saldo negativo.
  const toPay = await DriverModel.find({ commissionDue: { $lt: 0 } }).sort({ commissionDue: 1 }).limit(300);
  res.json({
    toPay: toPay.map((d) => ({ id: d.id as string, name: d.name || '(sem nome)', phone: d.phone ?? null, fleet: d.fleetName ?? null, amount: -d.commissionDue })),
    totalToPay: toPay.reduce((n, d) => n - d.commissionDue, 0),
    rate: settings.commissionRate,
    enforced: config.commission.enforced,
    limit: config.commission.debtLimit,
    walletEnabled: config.walletEnabled,
    /** Saldo pré-pago: viagens grátis dos motoristas novos e o saldo de cada motorista. */
    freeRides: settings.freeRides,
    balances: (await DriverModel.find({ deactivatedAt: { $exists: false } }).sort({ commissionDue: -1 }).limit(300)).map((d) => ({
      id: d.id as string,
      name: d.name || '(sem nome)',
      phone: d.phone ?? null,
      fleet: d.fleetName ?? null,
      balance: balanceOf(d),
      freeRidesLeft: freeRidesLeft(d),
    })),
    totalDue: total[0]?.total ?? 0,
    drivers: owing.map((d) => ({
      id: d.id as string,
      name: d.name || '(sem nome)',
      phone: d.phone ?? null,
      fleet: d.fleetName ?? null,
      due: d.commissionDue,
      overLimit: d.commissionDue > config.commission.debtLimit,
    })),
    payments: entries.map((e) => ({
      id: e.id as string,
      driver: (e.driver as unknown as { name?: string } | null)?.name ?? '(conta eliminada)',
      amount: e.amount,
      type: e.type,
      note: e.note ?? '',
      by: e.by ?? '',
      createdAt: e.get('createdAt') as Date,
    })),
  });
});

/** O Bazá pagou ao motorista o que lhe devia (corridas por conta de empresas). */
admin.post('/comissoes/:id/pagar-motorista', async (req, res) => {
  const body = parse(z.object({ amount: z.coerce.number().int().positive().max(100_000_000), note: z.string().trim().max(120).default('') }), req.body);
  const driver = await DriverModel.findById(parse(objectId, req.params.id));
  if (!driver) throw new HttpError(404, 'Motorista não encontrado.');
  if (body.amount > -driver.commissionDue) throw new HttpError(400, 'O valor é superior ao que o Bazá deve a este motorista.');
  driver.commissionDue += body.amount;
  await driver.save();
  await CommissionEntryModel.create({
    driver: driver._id,
    type: 'payout',
    amount: body.amount,
    note: body.note,
    by: (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador',
    dueAfter: driver.commissionDue,
  });
  res.json({ due: driver.commissionDue });
});

// ── Empresas clientes: colaboradores autorizados e a conta de cada mês ──────
const companyBody = z.object({
  name: z.string().trim().min(2).max(100),
  nif: z.string().trim().max(20).default(''),
  contactName: z.string().trim().max(80).default(''),
  phone: z.string().trim().max(20).default(''),
  email: z.preprocess((v) => (v === '' ? undefined : v), z.email().optional()),
  monthlyLimit: z.coerce.number().int().min(0).max(1_000_000_000).default(0),
  active: z.coerce.boolean().default(true),
});
const monthKey = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;

admin.get('/empresas', async (_req, res) => {
  const now = new Date();
  const thisMonth = monthStart(now);
  const lastMonth = new Date(now.getFullYear(), now.getMonth() - 1, 1);
  const [companies, rides, payments] = await Promise.all([
    CompanyModel.find().sort({ name: 1 }),
    RideModel.aggregate<{ _id: { company: unknown; month: string }; total: number; rides: number }>([
      { $match: { company: { $ne: null }, status: 'completed', completedAt: { $gte: lastMonth } } },
      { $group: { _id: { company: '$company', month: { $dateToString: { format: '%Y-%m', date: '$completedAt', timezone: 'Africa/Luanda' } } }, total: { $sum: '$fare' }, rides: { $sum: 1 } } },
    ]),
    CompanyPaymentModel.find({ month: { $in: [monthKey(thisMonth), monthKey(lastMonth)] } }),
  ]);
  const of = (id: string, month: string) => rides.find((r) => String(r._id.company) === id && r._id.month === month);
  const paid = (id: string, month: string) => payments.filter((p) => String(p.company) === id && p.month === month).reduce((n, p) => n + p.amount, 0);
  res.json({
    months: { current: monthKey(thisMonth), previous: monthKey(lastMonth) },
    companies: companies.map((c) => ({
      id: c.id as string,
      name: c.name,
      nif: c.nif,
      contactName: c.contactName,
      phone: c.phone,
      email: c.email,
      monthlyLimit: c.monthlyLimit,
      active: c.active,
      members: c.members.map((m) => ({ id: String(m._id), phone: m.phone, name: m.name, active: m.active })),
      current: { total: of(c.id, monthKey(thisMonth))?.total ?? 0, rides: of(c.id, monthKey(thisMonth))?.rides ?? 0 },
      previous: { total: of(c.id, monthKey(lastMonth))?.total ?? 0, rides: of(c.id, monthKey(lastMonth))?.rides ?? 0, paid: paid(c.id, monthKey(lastMonth)) },
    })),
  });
});

admin.post('/empresas', async (req, res) => {
  const body = parse(companyBody, req.body);
  const c = await CompanyModel.create({ ...body, email: body.email ?? '', phone: body.phone ? normalizePhone(body.phone) : '' });
  res.status(201).json({ id: c.id });
});

admin.post('/empresas/:id', async (req, res) => {
  const body = parse(companyBody, req.body);
  const c = await CompanyModel.findByIdAndUpdate(parse(objectId, req.params.id), { ...body, email: body.email ?? '', phone: body.phone ? normalizePhone(body.phone) : '' });
  if (!c) throw new HttpError(404, 'Empresa não encontrada.');
  res.json({ ok: true });
});

/** Autoriza um colaborador, pelo telefone com que entra no app como passageiro. */
admin.post('/empresas/:id/colaboradores', async (req, res) => {
  const body = parse(z.object({ name: z.string().trim().max(80).default(''), phone: z.string().min(6).max(20) }), req.body);
  const phone = normalizePhone(body.phone);
  if (await CompanyModel.exists({ 'members.phone': phone })) throw new HttpError(409, 'Este número já está autorizado numa empresa.');
  const c = await CompanyModel.findByIdAndUpdate(parse(objectId, req.params.id), { $push: { members: { phone, name: body.name } } });
  if (!c) throw new HttpError(404, 'Empresa não encontrada.');
  res.status(201).json({ ok: true });
});

admin.delete('/empresas/:id/colaboradores/:member', async (req, res) => {
  const c = await CompanyModel.findByIdAndUpdate(parse(objectId, req.params.id), { $pull: { members: { _id: parse(objectId, req.params.member) } } });
  if (!c) throw new HttpError(404, 'Empresa não encontrada.');
  res.json({ ok: true });
});

/** A conta de um mês: cada corrida, para enviar à empresa. */
admin.get('/empresas/:id/conta', async (req, res) => {
  const q = parse(z.object({ mes: z.string().regex(/^\d{4}-\d{2}$/) }), req.query);
  const c = await CompanyModel.findById(parse(objectId, req.params.id));
  if (!c) throw new HttpError(404, 'Empresa não encontrada.');
  const [y, m] = q.mes.split('-').map(Number) as [number, number];
  const rides = await RideModel.find({ company: c._id, status: 'completed', completedAt: { $gte: new Date(y, m - 1, 1), $lt: new Date(y, m, 1) } })
    .sort({ completedAt: 1 })
    .populate('passenger', 'name phone');
  const payments = await CompanyPaymentModel.find({ company: c._id, month: q.mes }).sort({ createdAt: 1 });
  const total = rides.reduce((n, r) => n + r.fare, 0);
  const paidTotal = payments.reduce((n, p) => n + p.amount, 0);
  res.json({
    company: c.name,
    month: q.mes,
    total,
    paid: paidTotal,
    balance: total - paidTotal,
    rides: rides.map((r) => {
      const p = r.passenger as unknown as { name?: string; phone?: string } | null;
      return { completedAt: r.completedAt ?? null, passenger: p?.name || '(sem nome)', phone: p?.phone ?? null, from: r.pickup?.address ?? '', to: r.dropoff?.address ?? '', fare: r.fare };
    }),
    payments: payments.map((p) => ({ createdAt: p.get('createdAt') as Date, amount: p.amount, note: p.note, by: p.by ?? '' })),
  });
});

admin.post('/empresas/:id/pagamento', async (req, res) => {
  const body = parse(z.object({ month: z.string().regex(/^\d{4}-\d{2}$/), amount: z.coerce.number().int().positive().max(1_000_000_000), note: z.string().trim().max(120).default('') }), req.body);
  const c = await CompanyModel.findById(parse(objectId, req.params.id));
  if (!c) throw new HttpError(404, 'Empresa não encontrada.');
  await CompanyPaymentModel.create({ company: c._id, month: body.month, amount: body.amount, note: body.note, by: (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador' });
  res.status(201).json({ ok: true });
});

admin.post('/comissoes/:id/pagamento', async (req, res) => {
  const body = parse(z.object({ amount: z.coerce.number().int().positive().max(10_000_000), note: z.string().trim().max(120).default('') }), req.body);
  const driver = await DriverModel.findById(parse(objectId, req.params.id));
  if (!driver) throw new HttpError(404, 'Motorista não encontrado.');
  await payCommission(driver, body.amount, { note: body.note, by: (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador' });
  res.json({ due: driver.commissionDue });
});

admin.post('/viagens-gratis', async (req, res) => {
  const body = parse(z.object({ count: z.coerce.number().int().min(0).max(1000) }), req.body);
  await setFreeRides(body.count, (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador');
  res.json({ freeRides: settings.freeRides });
});

/** Muda as viagens grátis que restam a um motorista (ex.: oferecer mais). */
admin.post('/motoristas/:id/viagens-gratis', async (req, res) => {
  const body = parse(z.object({ count: z.coerce.number().int().min(0).max(1000) }), req.body);
  const driver = await DriverModel.findByIdAndUpdate(parse(objectId, req.params.id), { freeRidesLeft: body.count }, { returnDocument: 'after' });
  if (!driver) throw new HttpError(404, 'Motorista não encontrado.');
  emitToUser(driver.id, 'account:update', {});
  res.json({ freeRidesLeft: freeRidesLeft(driver) });
});

/** Referências geradas pelos motoristas para carregar o saldo. */
admin.get('/carregamentos', async (_req, res) => {
  const list = await PaymentModel.find({ purpose: 'driver_fee' }).sort({ createdAt: -1 }).limit(100).populate('user', 'name phone');
  res.json({
    simulation: simulationOn(),
    /** real | simulation | testers | off */
    mode: referenceMode(),
    payments: list.map((p) => ({ ...sessionView(p), driver: (p.user as unknown as { name?: string } | null)?.name ?? '(conta eliminada)', settledAt: p.settledAt ?? null })),
  });
});

/** Simulação: dar uma referência de teste por paga (só referências simuladas). */
admin.post('/carregamentos/:id/simular', async (req, res) => {
  const payment = await PaymentModel.findById(parse(objectId, req.params.id));
  if (!payment?.simulated) throw new HttpError(400, 'Só as referências de simulação se podem dar por pagas aqui.');
  const done = await settlePayment(payment.id as string, 'paid', (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador');
  if (!done) throw new HttpError(409, 'Esta referência já não está por pagar.');
  res.json({ ok: true });
});

admin.post('/comissoes/percentagem', async (req, res) => {
  const body = parse(z.object({ percent: z.coerce.number().min(0).max(MAX_COMMISSION_RATE * 100) }), req.body);
  const rate = Math.round(body.percent * 10) / 1000; // uma casa decimal: 12,5 % → 0,125
  await setCommissionRate(rate, (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador');
  res.json({ rate });
});

// ── Mensalidades das viaturas de preço combinado ──
admin.get('/mensalidades', async (_req, res) => {
  const drivers = await DriverModel.find({ 'vehicles.category': { $in: NEGOTIATED } }).sort({ name: 1 }).limit(500);
  const monthStart = new Date();
  monthStart.setDate(1);
  monthStart.setHours(0, 0, 0, 0);
  const [received, payments] = await Promise.all([
    SubscriptionPaymentModel.aggregate<{ total: number }>([
      { $match: { createdAt: { $gte: monthStart } } },
      { $group: { _id: null, total: { $sum: '$amount' } } },
    ]),
    SubscriptionPaymentModel.find().sort({ createdAt: -1 }).limit(30).populate('driver', 'name'),
  ]);
  const vehicles = drivers.flatMap((d) =>
    d.vehicles
      .filter((v) => isNegotiated(v.category))
      .map((v) => ({
        driverId: d.id as string,
        driver: d.name || '(sem nome)',
        phone: d.phone ?? null,
        vehicleId: String(v._id),
        label: `${v.make} ${v.carModel}`,
        plate: v.plate,
        category: v.category,
        categoryLabel: service(v.category).label,
        fee: monthlyFee(v.category),
        state: subscriptionState(v.category, v.paidUntil),
        paidUntil: v.paidUntil ?? null,
      })),
  );
  res.json({
    trialDays: config.subscriptionTrialDays,
    fees: NEGOTIATED.map((k) => ({ category: k, label: service(k).label, fee: monthlyFee(k) })),
    receivedThisMonth: received[0]?.total ?? 0,
    vehicles,
    payments: payments.map((p) => ({
      driver: (p.driver as unknown as { name?: string } | null)?.name ?? '(conta eliminada)',
      plate: p.plate ?? '',
      months: p.months,
      amount: p.amount,
      paidUntil: p.paidUntil,
      note: p.note ?? '',
      by: p.by ?? '',
      createdAt: p.get('createdAt') as Date,
    })),
  });
});

// ── Tarifas e taxa por procura ──────────────────────────────────────────────

const tariffsOut = () => ({
  step: FARE_STEP,
  stopFee: pricing.stopFee,
  tariffs: TARIFF_KEYS.map((k) => {
    const s = service(k);
    return { category: k, label: s.label, ...tariffOf(k), defaults: { base: s.base, perKm: s.perKm, perMin: s.perMin, minimum: s.minimum } };
  }),
  surge: pricing.surge,
  defaultSurge: DEFAULT_SURGE,
  /** O que vale neste momento (hora de Luanda). */
  now: (() => {
    const c = luandaClock();
    const sched = activeSchedule();
    return { day: c.day, time: `${String(Math.floor(c.minutes / 60)).padStart(2, '0')}:${String(c.minutes % 60).padStart(2, '0')}`, schedule: sched ? { label: sched.label, multiplier: sched.multiplier } : null };
  })(),
});

admin.get('/tarifas', (_req, res) => {
  res.json(tariffsOut());
});

const kzField = (max: number) => z.coerce.number().int('Use números inteiros (kwanzas).').min(0).max(max);
admin.post('/tarifas', async (req, res) => {
  const tariff = z.object({ base: kzField(1_000_000), perKm: kzField(100_000), perMin: kzField(100_000), minimum: kzField(1_000_000) });
  const body = parse(z.object({ tariffs: z.record(z.string(), tariff), stopFee: kzField(100_000) }), req.body);
  for (const k of Object.keys(body.tariffs)) if (!(TARIFF_KEYS as string[]).includes(k)) throw new HttpError(400, `Categoria sem tarifa: ${k}.`);
  for (const [k, t] of Object.entries(body.tariffs)) {
    if (t.minimum % FARE_STEP !== 0) throw new HttpError(400, `${service(k as RideCategory).label}: o mínimo tem de ser múltiplo de ${FARE_STEP} Kz.`);
  }
  await setTariffs(body.tariffs, body.stopFee, (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador');
  res.json(tariffsOut());
});

const multiplier = z.coerce.number().min(1, 'O multiplicador mínimo é ×1.').max(3, 'O multiplicador máximo é ×3.');
const clockTime = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'Hora inválida (use HH:MM).');
admin.post('/tarifas/procura', async (req, res) => {
  const body = parse(
    z.object({
      autoEnabled: z.boolean(),
      radiusKm: z.coerce.number().min(0.5).max(20),
      windowMin: z.coerce.number().int().min(2).max(60),
      tiers: z.array(z.object({ ratio: z.coerce.number().min(1).max(20), multiplier })).max(8),
      schedules: z
        .array(z.object({ label: z.string().trim().min(2, 'Dê um nome ao horário.').max(40), days: z.array(z.number().int().min(0).max(6)).min(1, 'Escolha pelo menos um dia.'), start: clockTime, end: clockTime, multiplier }))
        .max(20),
      maxMultiplier: multiplier,
    }),
    req.body,
  );
  if (body.tiers.some((t) => t.multiplier > body.maxMultiplier) || body.schedules.some((r) => r.multiplier > body.maxMultiplier)) {
    throw new HttpError(400, `Nenhum multiplicador pode passar do tecto (×${body.maxMultiplier}).`);
  }
  await setSurge(body, (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador');
  res.json(tariffsOut());
});

/** Simulador: o cálculo de uma corrida, passo a passo, com as tarifas em vigor. */
admin.post('/tarifas/simular', (req, res) => {
  const body = parse(
    z.object({
      category: z.enum(TARIFF_KEYS as [string, ...string[]]),
      km: z.coerce.number().min(0).max(1000),
      min: z.coerce.number().min(0).max(1440),
      stops: z.coerce.number().int().min(0).max(3).default(0),
      multiplier: z.coerce.number().min(1).max(3).default(1),
    }),
    req.body,
  );
  res.json(fareBreakdown(body.category as RideCategory, body.km * 1000, body.min * 60, body.stops, body.multiplier));
});

admin.post('/mensalidades/taxas', async (req, res) => {
  const body = parse(z.object({ fees: z.record(z.string(), z.coerce.number().min(0).max(5_000_000)) }), req.body);
  await setMonthlyFees(body.fees, (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador');
  res.json({ fees: settings.monthlyFees });
});

admin.post('/mensalidades/:driver/:vehicle/pagamento', async (req, res) => {
  const body = parse(
    z.object({
      months: z.coerce.number().int().min(1).max(24),
      amount: z.coerce.number().int().min(0).max(100_000_000).optional(),
      note: z.string().trim().max(120).default(''),
    }),
    req.body,
  );
  const driver = await DriverModel.findById(parse(objectId, req.params.driver));
  if (!driver) throw new HttpError(404, 'Viatura não encontrada.');
  const from = await extendSubscription(driver, parse(objectId, req.params.vehicle), body.months, {
    amount: body.amount,
    note: body.note,
    by: (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador',
  });
  res.json({ paidUntil: from });
});

// ── Pagamentos comunicados pelos motoristas, à espera de confirmação ──
admin.get('/pagamentos', async (req, res) => {
  const q = parse(z.object({ estado: z.enum(['pending', 'confirmed', 'rejected']).default('pending') }), req.query);
  const list = await PaymentRequestModel.find({ status: q.estado }).sort({ createdAt: q.estado === 'pending' ? 1 : -1 }).limit(200);
  res.json({
    pending: await PaymentRequestModel.countDocuments({ status: 'pending' }),
    requests: list.map((r) => ({
      ...requestOut(r),
      driver: r.driverName || '(sem nome)',
      phone: r.phone ?? null,
      categoryLabel: r.category && r.category in services ? services[r.category as keyof typeof services].label : null,
      reviewedBy: r.reviewedBy ?? null,
    })),
  });
});

admin.post('/pagamentos/:id', async (req, res) => {
  const body = parse(z.object({ approve: z.boolean(), note: z.string().trim().max(200).optional() }), req.body);
  const by = (await AdminModel.findById(req.panel.id))?.name ?? 'Administrador';
  await reviewPaymentRequest(parse(objectId, req.params.id), body.approve, { note: body.note || undefined, by });
  res.json({ ok: true });
});

// ── Suporte: pedidos enviados pelo app ──
admin.get('/suporte', async (req, res) => {
  const q = parse(z.object({ estado: z.enum(['open', 'resolved']).default('open') }), req.query);
  const tickets = await TicketModel.find({ status: q.estado }).sort({ createdAt: q.estado === 'open' ? 1 : -1 }).limit(200);
  const rides = await RideModel.find({ _id: { $in: tickets.map((t) => t.ride).filter(Boolean) } }).select('pickup dropoff fare completedAt createdAt');
  const rideBy = new Map(rides.map((r) => [r.id as string, r]));
  res.json({
    open: await TicketModel.countDocuments({ status: 'open' }),
    tickets: tickets.map((t) => {
      const ride = t.ride ? rideBy.get(String(t.ride)) : null;
      return {
        id: t.id as string,
        role: t.role,
        name: t.name || '(sem nome)',
        phone: t.phone ?? null,
        category: t.category,
        message: t.message,
        ride: ride ? { from: ride.pickup.address, to: ride.dropoff.address, fare: ride.fare, at: ride.completedAt ?? (ride.get('createdAt') as Date) } : null,
        status: t.status,
        reply: t.reply ?? null,
        repliedBy: t.repliedBy ?? null,
        createdAt: t.get('createdAt') as Date,
      };
    }),
  });
});

admin.post('/suporte/:id/resposta', async (req, res) => {
  const body = parse(z.object({ reply: z.string().trim().min(2).max(1500) }), req.body);
  const ticket = await TicketModel.findById(parse(objectId, req.params.id));
  if (!ticket) throw new HttpError(404, 'Pedido não encontrado.');
  ticket.status = 'resolved';
  ticket.reply = body.reply;
  ticket.repliedBy = (await AdminModel.findById(req.panel.id))?.name ?? 'Equipa Bazá';
  ticket.repliedAt = new Date();
  await ticket.save();
  // Avisa o utilizador: no app aberto e, se estiver fechado, por notificação.
  emitToUser(String(ticket.account), 'support:reply', { ticketId: ticket.id });
  void pushToUser(String(ticket.account), { title: 'Resposta do suporte Bazá', body: body.reply.slice(0, 140) });
  res.json({ ok: true });
});

admin.post('/locais/:id/aprovar', async (req, res) => {
  const result = await LocalModel.updateOne({ _id: parse(objectId, req.params.id) }, { reviewed: true });
  if (!result.matchedCount) throw new HttpError(404, 'Local não encontrado.');
  clearSearchCache();
  res.json({ ok: true });
});

admin.get('/administradores', async (req, res) => {
  const admins = await AdminModel.find().sort({ createdAt: 1 });
  res.json({
    admins: admins.map((a) => ({
      id: a.id as string,
      name: a.name,
      email: a.email,
      you: a.id === req.panel.id,
      defaultPassword: a.defaultPassword,
      createdAt: a.get('createdAt') as Date,
    })),
  });
});

admin.post('/administradores', async (req, res) => {
  const body = parse(
    z.object({ name: z.string().trim().min(2).max(80), email: z.email(), password: z.string().min(8).max(100) }),
    req.body,
  );
  const email = body.email.toLowerCase();
  if (await emailTaken(email)) throw new HttpError(409, 'Já existe uma conta com este email.');
  await AdminModel.create({ name: body.name, email, passwordHash: await bcrypt.hash(body.password, 11) });
  res.status(201).json({ ok: true });
});

admin.delete('/administradores/:id', async (req, res) => {
  const id = parse(objectId, req.params.id);
  if (id === req.panel.id) throw new HttpError(400, 'Não pode remover a sua própria conta.');
  const result = await AdminModel.deleteOne({ _id: id });
  if (!result.deletedCount) throw new HttpError(404, 'Administrador não encontrado.');
  res.json({ ok: true });
});

admin.post('/palavra-passe', async (req, res) => {
  const body = parse(z.object({ current: z.string().min(1).max(100), next: z.string().min(8).max(100) }), req.body);
  const me = await AdminModel.findById(req.panel.id);
  if (!me || !(await bcrypt.compare(body.current, me.passwordHash))) {
    throw new HttpError(403, 'A palavra-passe actual está incorrecta.');
  }
  if (body.next === DEFAULT_ADMIN.password) throw new HttpError(400, 'Escolha uma palavra-passe diferente da palavra-passe por defeito.');
  me.passwordHash = await bcrypt.hash(body.next, 11);
  me.defaultPassword = false;
  await me.save();
  res.json({ ok: true });
});

panelApi.use('/admin', admin);

// ── Frota ───────────────────────────────────────────────────────────────────
const fleet = Router();
fleet.use(auth('fleet'));

const myDrivers = (req: Request) => DriverModel.find({ fleet: req.panel.id }).sort({ name: 1 }).limit(500);

fleet.get('/resumo', async (req, res) => {
  const f = req.panel.fleet!;
  const drivers = await myDrivers(req);
  const ids = drivers.map((d) => d._id);
  const [onTrip, today, week] = await Promise.all([
    RideModel.countDocuments({ driver: { $in: ids }, status: { $in: ON_TRIP } }),
    totals({ driver: { $in: ids }, completedAt: { $gte: startOfDay() } }),
    totals({ driver: { $in: ids }, completedAt: { $gte: startOfDay(6) } }),
  ]);
  res.json({
    fleet: { name: f.name, nif: f.nif, email: f.email, phone: f.phone, joinCode: f.joinCode },
    drivers: drivers.length,
    online: drivers.filter((d) => d.isOnline).length,
    pending: drivers.filter((d) => verification(d) !== 'approved').length,
    onTrip,
    today,
    week,
  });
});

fleet.get('/motoristas', async (req, res) => {
  res.json({ drivers: await driverRows(await myDrivers(req)) });
});

/** Regista um motorista novo na frota; ele entra no app com este telefone. */
fleet.post('/motoristas', async (req, res) => {
  const body = parse(z.object({ name: z.string().trim().min(2).max(80), phone: z.string().min(6).max(20) }), req.body);
  const phone = normalizePhone(body.phone);
  const existing = await DriverModel.findOne({ phone });
  if (existing) {
    throw new HttpError(
      409,
      String(existing.fleet ?? '') === req.panel.id
        ? 'Esse motorista já está na sua frota.'
        : `Já existe um motorista com esse número. Peça-lhe para introduzir o código ${req.panel.fleet!.joinCode} no app, em "Frota".`,
    );
  }
  await assertPhoneFreeForRole(
    'driver',
    phone,
    'Esse número já tem conta de passageiro no Bazá. Cada número só pode ter um tipo de conta: o motorista tem de usar outro número.',
  );
  await DriverModel.create({ name: body.name, phone, fleet: req.panel.id, fleetName: req.panel.fleet!.name, freeRidesLeft: settings.freeRides });
  res.status(201).json({ ok: true });
});

/** Retira o motorista da frota; a conta dele continua a existir, independente. */
fleet.delete('/motoristas/:id', async (req, res) => {
  const result = await DriverModel.updateOne(
    { _id: parse(objectId, req.params.id), fleet: req.panel.id },
    { $unset: { fleet: 1, fleetName: 1 } },
  );
  if (!result.modifiedCount) throw new HttpError(404, 'Motorista não encontrado na sua frota.');
  res.json({ ok: true });
});

fleet.get('/corridas', async (req, res) => {
  const ids = (await myDrivers(req)).map((d) => d._id);
  res.json({ rides: await rideRows({ driver: { $in: ids } }) });
});

/** Ficha de um motorista da frota: os mesmos dados que a equipa do Bazá vê, só para consulta. */
const myDriver = async (req: Request) => {
  const d = await DriverModel.findOne({ _id: parse(objectId, req.params.id), fleet: req.panel.id });
  if (!d) throw new HttpError(404, 'Motorista não encontrado na sua frota.');
  return d;
};
fleet.get('/motoristas/:id', async (req, res) => {
  res.json(await driverFileData(await myDriver(req)));
});
fleet.get('/documentos/:id/:doc', async (req, res) => {
  await sendDriverDocument(res, await myDriver(req), String(req.params.doc));
});

/** Aviso da frota aos seus motoristas (a um, ou a todos). */
fleet.post('/avisos', async (req, res) => {
  const body = parse(
    z.object({ id: objectId.optional(), title: z.string().trim().min(3).max(80), message: z.string().trim().min(5).max(600) }),
    req.body,
  );
  const ids = (await DriverModel.find({ fleet: req.panel.id, ...(body.id ? { _id: body.id } : {}) }).distinct('_id')).map(String);
  if (!ids.length) throw new HttpError(404, body.id ? 'Motorista não encontrado na sua frota.' : 'A frota ainda não tem motoristas.');
  const created = await NoticeModel.insertMany(
    ids.map((account) => ({
      account,
      role: 'driver' as const,
      title: body.title,
      message: body.message,
      sentBy: `${req.panel.fleet!.name} (${req.panel.user!.name})`,
      broadcast: !body.id,
    })),
  );
  for (const n of created) emitToUser(String(n.account), 'notice:new', { id: n.id, title: n.title, message: n.message });
  res.status(201).json({ sent: created.length });
});

/** Alertas SOS em corridas dos motoristas da frota. */
fleet.get('/sos', async (req, res) => {
  const ids = (await myDrivers(req)).map((d) => d._id);
  res.json({ alerts: await sosRows({ ride: { $in: await RideModel.find({ driver: { $in: ids } }).distinct('_id') } }) });
});

/** Contas por motorista num período: corridas, facturação, comissão e o que deve ao Bazá. */
fleet.get('/contas', async (req, res) => {
  const q = parse(z.object({ dias: z.coerce.number().int().min(1).max(366).default(30) }), req.query);
  const drivers = await myDrivers(req);
  const since = startOfDay(q.dias - 1);
  const rows = await RideModel.aggregate<{ _id: unknown; rides: number; revenue: number; commission: number }>([
    { $match: { driver: { $in: drivers.map((d) => d._id) }, status: 'completed', completedAt: { $gte: since } } },
    { $group: { _id: '$driver', rides: { $sum: 1 }, revenue: { $sum: '$fare' }, commission: { $sum: '$commission' } } },
  ]);
  const by = new Map(rows.map((r) => [String(r._id), r]));
  const list = drivers.map((d) => {
    const r = by.get(d.id);
    return {
      id: d.id as string,
      name: d.name || '(sem nome)',
      phone: d.phone ?? null,
      plate: d.vehicle?.plate ?? null,
      rides: r?.rides ?? 0,
      revenue: r?.revenue ?? 0,
      commission: r?.commission ?? 0,
      commissionDue: d.commissionDue,
    };
  });
  const sum = (k: 'rides' | 'revenue' | 'commission' | 'commissionDue') => list.reduce((n, x) => n + x[k], 0);
  res.json({
    days: q.dias,
    since,
    drivers: list.sort((a, b) => b.revenue - a.revenue),
    totals: { rides: sum('rides'), revenue: sum('revenue'), commission: sum('commission'), commissionDue: sum('commissionDue') },
  });
});

/** Dados da empresa, que o gestor pode corrigir. */
fleet.post('/empresa', async (req, res) => {
  if (req.panel.user!.role !== 'manager') throw new HttpError(403, 'Só um gestor pode alterar os dados da empresa.');
  const body = parse(z.object({ name: z.string().trim().min(2).max(80), phone: z.string().min(6).max(20) }), req.body);
  const f = req.panel.fleet!;
  const renamed = f.name !== body.name;
  f.name = body.name;
  f.phone = normalizePhone(body.phone);
  await f.save();
  if (renamed) await DriverModel.updateMany({ fleet: f._id }, { fleetName: f.name });
  res.json({ ok: true });
});

// ── Acerto de contas entre a frota e cada motorista ─────────────────────────
const whoAmI = (req: Request) => req.panel.user!.name;

/** Quanto o motorista deve entregar à frota desde que a regra começou a contar. */
async function owedSince(driverId: unknown, term: { mode: string; value: number; startAt: Date }) {
  const rows = await RideModel.aggregate<{ _id: string; revenue: number }>([
    { $match: { driver: driverId, status: 'completed', completedAt: { $gte: term.startAt } } },
    { $group: { _id: { $dateToString: { format: '%Y-%m-%d', date: '$completedAt', timezone: 'Africa/Luanda' } }, revenue: { $sum: '$fare' } } },
  ]);
  const revenue = rows.reduce((n, r) => n + r.revenue, 0);
  const days = rows.length;
  return { revenue, days, owed: Math.round(term.mode === 'percent' ? (revenue * term.value) / 100 : days * term.value) };
}

fleet.get('/acertos', async (req, res) => {
  const drivers = await myDrivers(req);
  const [terms, handovers] = await Promise.all([
    FleetTermModel.find({ fleet: req.panel.id }),
    FleetHandoverModel.find({ fleet: req.panel.id }).sort({ createdAt: -1 }).limit(400),
  ]);
  const termBy = new Map(terms.map((t) => [String(t.driver), t]));
  const rows = await Promise.all(
    drivers.map(async (d) => {
      const term = termBy.get(d.id);
      const mine = handovers.filter((h) => String(h.driver) === d.id && (!term || h.get('createdAt') >= term.startAt));
      const delivered = mine.reduce((n, h) => n + h.amount, 0);
      const calc = term ? await owedSince(d._id, term) : { revenue: 0, days: 0, owed: 0 };
      return {
        id: d.id as string,
        name: d.name || '(sem nome)',
        phone: d.phone ?? null,
        photoUrl: d.photo ? `/uploads/${d.photo}` : null,
        term: term ? { mode: term.mode, value: term.value, startAt: term.startAt } : null,
        ...calc,
        delivered,
        balance: calc.owed - delivered,
        lastHandover: mine[0] ? (mine[0].get('createdAt') as Date) : null,
      };
    }),
  );
  const nameOf = new Map(drivers.map((d) => [d.id as string, d.name || '(sem nome)']));
  res.json({
    drivers: rows,
    totals: { owed: rows.reduce((n, r) => n + r.owed, 0), delivered: rows.reduce((n, r) => n + r.delivered, 0), balance: rows.reduce((n, r) => n + Math.max(0, r.balance), 0) },
    handovers: handovers.slice(0, 40).map((h) => ({ createdAt: h.get('createdAt') as Date, driver: nameOf.get(String(h.driver)) ?? '(saiu da frota)', amount: h.amount, note: h.note, by: h.by ?? '' })),
  });
});

/** Define ou muda a regra; a contagem recomeça a partir de hoje (ou da data indicada). */
fleet.post('/acertos/:id', async (req, res) => {
  const body = parse(
    z.object({ mode: z.enum(['percent', 'daily']), value: z.coerce.number().min(0).max(10_000_000), startAt: z.coerce.date().optional() }),
    req.body,
  );
  if (body.mode === 'percent' && body.value > 100) throw new HttpError(400, 'A percentagem não pode passar de 100.');
  const d = await myDriver(req);
  await FleetTermModel.findOneAndUpdate(
    { fleet: req.panel.id, driver: d._id },
    { mode: body.mode, value: body.value, startAt: body.startAt ?? startOfDay() },
    { upsert: true },
  );
  res.json({ ok: true });
});

fleet.post('/acertos/:id/entrega', async (req, res) => {
  const body = parse(z.object({ amount: z.coerce.number().int().positive().max(100_000_000), note: z.string().trim().max(120).default('') }), req.body);
  const d = await myDriver(req);
  await FleetHandoverModel.create({ fleet: req.panel.id, driver: d._id, amount: body.amount, note: body.note, by: whoAmI(req) });
  res.status(201).json({ ok: true });
});

// ── Viaturas da frota: a quem estão entregues, datas e despesas ─────────────
const optionalDate = z.preprocess((v) => (v === '' || v === null || v === undefined ? undefined : v), z.coerce.date().optional());
const vehicleBody = z.object({
  plate: z.string().trim().min(3).max(15),
  label: z.string().trim().min(2).max(60),
  driver: z.preprocess((v) => (v === '' || v === null ? undefined : v), objectId.optional()),
  insuranceDue: optionalDate,
  inspectionDue: optionalDate,
  serviceDue: optionalDate,
  notes: z.string().trim().max(300).default(''),
});

fleet.get('/viaturas', async (req, res) => {
  const [vehicles, drivers, expenses] = await Promise.all([
    FleetVehicleModel.find({ fleet: req.panel.id }).sort({ plate: 1 }),
    myDrivers(req),
    FleetExpenseModel.find({ fleet: req.panel.id }).sort({ date: -1 }).limit(600),
  ]);
  const nameOf = new Map(drivers.map((d) => [d.id as string, d.name || '(sem nome)']));
  const month = startOfDay(new Date().getDate() - 1);
  const plateOf = new Map(vehicles.map((v) => [v.id as string, v.plate]));
  res.json({
    drivers: drivers.map((d) => ({ id: d.id as string, name: d.name || '(sem nome)' })),
    vehicles: vehicles.map((v) => {
      const mine = expenses.filter((e) => String(e.vehicle) === v.id);
      return {
        id: v.id as string,
        plate: v.plate,
        label: v.label,
        driverId: v.driver ? String(v.driver) : null,
        driver: v.driver ? (nameOf.get(String(v.driver)) ?? null) : null,
        insuranceDue: v.insuranceDue ?? null,
        inspectionDue: v.inspectionDue ?? null,
        serviceDue: v.serviceDue ?? null,
        notes: v.notes,
        spentMonth: mine.filter((e) => e.date >= month).reduce((n, e) => n + e.amount, 0),
        spentTotal: mine.reduce((n, e) => n + e.amount, 0),
      };
    }),
    spentMonth: expenses.filter((e) => e.date >= month).reduce((n, e) => n + e.amount, 0),
    expenses: expenses.slice(0, 60).map((e) => ({ id: e.id as string, date: e.date, plate: plateOf.get(String(e.vehicle)) ?? '—', kind: e.kind, amount: e.amount, note: e.note, by: e.by ?? '' })),
  });
});

async function saveVehicle(req: Request, id?: string) {
  const body = parse(vehicleBody, req.body);
  if (body.driver && !(await DriverModel.exists({ _id: body.driver, fleet: req.panel.id }))) throw new HttpError(400, 'Esse motorista não é da sua frota.');
  const plate = body.plate.toUpperCase();
  const clash = await FleetVehicleModel.findOne({ fleet: req.panel.id, plate, ...(id ? { _id: { $ne: id } } : {}) });
  if (clash) throw new HttpError(409, 'Já registou uma viatura com esta matrícula.');
  const data = { ...body, plate };
  if (!id) return FleetVehicleModel.create({ ...data, fleet: req.panel.id });
  const set: Record<string, unknown> = { plate, label: body.label, notes: body.notes };
  const unset: Record<string, 1> = {};
  for (const k of ['driver', 'insuranceDue', 'inspectionDue', 'serviceDue'] as const) {
    if (body[k] === undefined) unset[k] = 1;
    else set[k] = body[k];
  }
  const v = await FleetVehicleModel.findOneAndUpdate({ _id: id, fleet: req.panel.id }, { $set: set, ...(Object.keys(unset).length ? { $unset: unset } : {}) });
  if (!v) throw new HttpError(404, 'Viatura não encontrada.');
  return v;
}
fleet.post('/viaturas', async (req, res) => {
  const v = await saveVehicle(req);
  res.status(201).json({ id: v.id });
});
fleet.post('/viaturas/:id', async (req, res) => {
  await saveVehicle(req, parse(objectId, req.params.id));
  res.json({ ok: true });
});
fleet.delete('/viaturas/:id', async (req, res) => {
  const id = parse(objectId, req.params.id);
  const r = await FleetVehicleModel.deleteOne({ _id: id, fleet: req.panel.id });
  if (!r.deletedCount) throw new HttpError(404, 'Viatura não encontrada.');
  await FleetExpenseModel.deleteMany({ fleet: req.panel.id, vehicle: id });
  res.json({ ok: true });
});
fleet.post('/viaturas/:id/despesas', async (req, res) => {
  const body = parse(
    z.object({ kind: z.enum(EXPENSE_KINDS), amount: z.coerce.number().int().positive().max(100_000_000), date: z.coerce.date(), note: z.string().trim().max(120).default('') }),
    req.body,
  );
  const v = await FleetVehicleModel.findOne({ _id: parse(objectId, req.params.id), fleet: req.panel.id });
  if (!v) throw new HttpError(404, 'Viatura não encontrada.');
  await FleetExpenseModel.create({ ...body, fleet: req.panel.id, vehicle: v._id, by: whoAmI(req) });
  res.status(201).json({ ok: true });
});
fleet.delete('/despesas/:id', async (req, res) => {
  const r = await FleetExpenseModel.deleteOne({ _id: parse(objectId, req.params.id), fleet: req.panel.id });
  if (!r.deletedCount) throw new HttpError(404, 'Despesa não encontrada.');
  res.json({ ok: true });
});

// ── Turnos: quem devia estar a trabalhar agora ──────────────────────────────
const hhmm = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'Hora inválida (use HH:MM).');
/** Minutos desde a meia-noite, e dia da semana, na hora de Luanda. */
function luandaNow() {
  const parts = new Intl.DateTimeFormat('en-GB', { timeZone: 'Africa/Luanda', weekday: 'short', hour: '2-digit', minute: '2-digit', hour12: false }).formatToParts(new Date());
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '';
  return { day: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(get('weekday')), minutes: Number(get('hour')) * 60 + Number(get('minute')) };
}
const toMinutes = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3));
/** Se o turno está a decorrer agora (os turnos podem passar da meia-noite). */
function onShiftNow(s: { days: number[]; start: string; end: string }) {
  const now = luandaNow();
  const a = toMinutes(s.start), b = toMinutes(s.end);
  if (a <= b) return s.days.includes(now.day) && now.minutes >= a && now.minutes < b;
  return (s.days.includes(now.day) && now.minutes >= a) || (s.days.includes((now.day + 6) % 7) && now.minutes < b);
}

fleet.get('/turnos', async (req, res) => {
  const [drivers, shifts] = await Promise.all([myDrivers(req), FleetShiftModel.find({ fleet: req.panel.id })]);
  const by = new Map(shifts.map((s) => [String(s.driver), s]));
  const rows = drivers.map((d) => {
    const s = by.get(d.id);
    const expected = s ? onShiftNow(s) : false;
    return {
      id: d.id as string,
      name: d.name || '(sem nome)',
      phone: d.phone ?? null,
      photoUrl: d.photo ? `/uploads/${d.photo}` : null,
      online: d.isOnline,
      shift: s ? { days: s.days, start: s.start, end: s.end } : null,
      expected,
      // Devia estar a trabalhar e não está online.
      missing: expected && !d.isOnline,
    };
  });
  res.json({ drivers: rows, expected: rows.filter((r) => r.expected).length, missing: rows.filter((r) => r.missing).length });
});

fleet.post('/turnos/:id', async (req, res) => {
  const body = parse(z.object({ days: z.array(z.coerce.number().int().min(0).max(6)).max(7), start: hhmm, end: hhmm }), req.body);
  const d = await myDriver(req);
  if (!body.days.length) {
    await FleetShiftModel.deleteOne({ fleet: req.panel.id, driver: d._id });
  } else {
    await FleetShiftModel.findOneAndUpdate({ fleet: req.panel.id, driver: d._id }, { days: [...new Set(body.days)].sort(), start: body.start, end: body.end }, { upsert: true });
  }
  res.json({ ok: true });
});

panelApi.use('/frota', fleet);

// ── Utilizadores de cada instituição (frotas e entidades) ───────────────────
const team = Router();
team.use(auth('fleet'));
const mine = (req: Request) => ({ kind: 'fleet' as const, institution: req.panel.id });
const onlyManager = (req: Request) => {
  if (req.panel.user!.role !== 'manager') throw new HttpError(403, 'Só um gestor pode gerir os utilizadores.');
};
const userOut = (u: PanelUserDoc, me: string) => ({
  id: u.id as string,
  name: u.name,
  email: u.email,
  role: u.role,
  active: u.active,
  you: u.id === me,
  lastLoginAt: u.lastLoginAt ?? null,
  createdAt: u.get('createdAt') as Date,
});

team.get('/utilizadores', async (req, res) => {
  const users = await PanelUserModel.find(mine(req)).sort({ createdAt: 1 });
  res.json({ users: users.map((u) => userOut(u, req.panel.user!.id)), canManage: req.panel.user!.role === 'manager' });
});

team.post('/utilizadores', async (req, res) => {
  onlyManager(req);
  const body = parse(
    z.object({
      name: z.string().trim().min(2).max(80),
      email: z.email(),
      password: z.string().min(8).max(100),
      role: z.enum(['manager', 'operator']).default('operator'),
    }),
    req.body,
  );
  const email = body.email.toLowerCase();
  if (await emailTaken(email)) throw new HttpError(409, 'Já existe uma conta com este email.');
  await PanelUserModel.create({
    ...mine(req),
    name: body.name,
    email,
    role: body.role,
    passwordHash: await bcrypt.hash(body.password, 11),
    mustChangePassword: true,
  });
  res.status(201).json({ ok: true });
});

/** Mudar o papel ou desactivar; tem de ficar sempre pelo menos um gestor activo. */
team.post('/utilizadores/:id', async (req, res) => {
  onlyManager(req);
  const body = parse(z.object({ role: z.enum(['manager', 'operator']).optional(), active: z.boolean().optional() }), req.body);
  const user = await PanelUserModel.findOne({ _id: parse(objectId, req.params.id), ...mine(req) });
  if (!user) throw new HttpError(404, 'Utilizador não encontrado.');
  if (body.role) user.role = body.role;
  if (body.active !== undefined) user.active = body.active;
  if (user.role !== 'manager' || !user.active) {
    const others = await PanelUserModel.countDocuments({ ...mine(req), role: 'manager', active: true, _id: { $ne: user._id } });
    if (!others) throw new HttpError(409, 'Tem de ficar pelo menos um gestor activo.');
  }
  await user.save();
  res.json({ ok: true });
});

team.delete('/utilizadores/:id', async (req, res) => {
  onlyManager(req);
  const id = parse(objectId, req.params.id);
  if (id === req.panel.user!.id) throw new HttpError(409, 'Não pode remover a sua própria conta.');
  const result = await PanelUserModel.deleteOne({ _id: id, ...mine(req) });
  if (!result.deletedCount) throw new HttpError(404, 'Utilizador não encontrado.');
  res.json({ ok: true });
});

team.post('/palavra-passe', async (req, res) => {
  const body = parse(z.object({ current: z.string().min(1).max(100), next: z.string().min(8).max(100) }), req.body);
  const user = req.panel.user!;
  if (!(await bcrypt.compare(body.current, user.passwordHash))) throw new HttpError(400, 'A palavra-passe actual não está correcta.');
  user.passwordHash = await bcrypt.hash(body.next, 11);
  user.mustChangePassword = false;
  await user.save();
  res.json({ ok: true });
});

panelApi.use('/equipa', team);

// ── Ficheiros do painel (HTML, CSS, JS) ─────────────────────────────────────
// O mapa de monitorização usa o Leaflet e as imagens do OpenStreetMap, e as
// fotos dos documentos são mostradas a partir de blobs.
export const panelStatic = Router();
panelStatic.use(
  helmet.contentSecurityPolicy({
    useDefaults: false,
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'"],
      styleSrc: ["'self'", "'unsafe-inline'"],
      imgSrc: ["'self'", 'data:', 'blob:', 'https://tile.openstreetmap.org'],
      connectSrc: ["'self'"],
      baseUri: ["'none'"],
      frameAncestors: ["'none'"],
    },
  }),
  express.static(fileURLToPath(new URL('../../panel', import.meta.url)), { maxAge: 0, etag: true }),
);

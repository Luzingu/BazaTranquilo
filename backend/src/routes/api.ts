import { Router, type Request } from 'express';
import { z } from 'zod';
import { MAX_HELPERS, MAX_STOPS, SERVICE_KEYS, config } from '../config.js';
import {
  HttpError,
  parse,
  requireAuth,
  requireCompleteDriver,
  requireDriver,
  requirePassenger,
} from '../http.js';
import {
  DriverModel,
  activateVehicle,
  driverIsComplete,
  addVehicle,
  driverParty,
  publicAccount,
  removeVehicle,
  updateVehicle,
} from '../models/accounts.js';
import { CommissionEntryModel, LocalModel, PaymentRequestModel, WalletTxModel, WithdrawalModel, searchKeyOf } from '../models/misc.js';
import { FleetModel } from '../models/panel.js';
import { ACTIVE_STATUSES, RideModel } from '../models/Ride.js';
import { clearSearchCache, haversineM, regionOf, reverseGeocode, searchPlaces } from '../services/geo.js';
import { adjustWallet, createPayment, electronicPaymentsAvailable } from '../services/payments.js';
import { PAYMENT_METHODS, accountNote, createPaymentRequest, driverAccount, paySubscriptionFromBalance, requestOut } from '../services/billing.js';
import { createTopup, sessionView } from '../services/gateway.js';
import { PaymentModel } from '../models/misc.js';
import { balanceOf, freeRidesLeft } from '../services/balance.js';
import { companyStatus } from '../services/corporate.js';
import { settings } from '../services/settings.js';
import {
  acceptBid,
  acceptRide,
  advanceRide,
  availableDriverIds,
  cancelRide,
  catalog,
  changePrice,
  createRide,
  declineBid,
  declineRide,
  estimate,
  offersForDriver,
  placeBid,
  rateRide,
  serializeRide,
  setDriverOnline,
  updateDriverLocation,
  withdrawBid,
} from '../services/rides.js';

const lat = z.coerce.number().min(-90).max(90);
const lng = z.coerce.number().min(-180).max(180);
const point = z.object({ lat, lng });
const place = point.extend({ address: z.string().trim().min(1).max(200) });
const objectId = z.string().regex(/^[0-9a-f]{24}$/i, 'identificador inválido');
const param = (req: Request, name = 'id') => parse(objectId, req.params[name]);
/** Filtro das corridas de quem faz o pedido, seja passageiro ou motorista. */
const mine = (req: Request) =>
  req.role === 'passenger' ? { passenger: req.account._id } : { driver: req.account._id };

/** O passageiro vê as propostas de todos os motoristas; o motorista só a sua. */
const viewer = (req: Request) =>
  req.role === 'passenger' ? ('passenger' as const) : { driverId: req.account.id as string };

// ── Locais ──────────────────────────────────────────────────────────────────
export const placesRouter = Router();
placesRouter.use(requireAuth);

/**
 * Locais registados (equipa e utilizadores estrela) dentro da zona do mapa que o
 * app está a mostrar: aparecem no mapa com o nome, onde o mapa aberto é pobre.
 */
placesRouter.get('/near', async (req, res) => {
  const q = parse(z.object({ south: lat, north: lat, west: lng, east: lng }), req.query);
  // Zona demasiado grande (mapa muito afastado): não vale a pena encher o mapa.
  if (q.north - q.south > 1.2 || q.east - q.west > 1.2 || q.north < q.south || q.east < q.west) {
    res.json({ places: [] });
    return;
  }
  const found = await LocalModel.find({
    lat: { $gte: q.south, $lte: q.north },
    lng: { $gte: q.west, $lte: q.east },
    ...(config.starPlacesNeedApproval ? { reviewed: { $ne: false } } : {}),
  })
    .limit(120)
    .lean();
  res.json({ places: found.map((l) => ({ id: String(l._id), name: l.name, lat: l.lat, lng: l.lng })) });
});

placesRouter.get('/search', async (req, res) => {
  const q = parse(
    z.object({ q: z.string().trim().min(1).max(120), lat: lat.optional(), lng: lng.optional() }),
    req.query,
  );
  const near = q.lat !== undefined && q.lng !== undefined ? { lat: q.lat, lng: q.lng } : undefined;
  try {
    res.json({ places: await searchPlaces(q.q, near) });
  } catch {
    throw new HttpError(502, 'Pesquisa de endereços indisponível. Tente novamente.');
  }
});

// ── Utilizadores estrela: registar locais no mapa, no sítio onde estão ──────
const MAX_CONTRIBUTIONS_PER_DAY = 60;

function requireStar(req: Request) {
  if (!req.account.star) throw new HttpError(403, 'Só utilizadores estrela podem registar locais.');
}

const localOut = (l: { _id: unknown; name: string; zone: string; province: string; lat: number; lng: number; createdAt?: Date }) => ({
  id: String(l._id),
  name: l.name,
  zone: l.zone,
  province: l.province,
  lat: l.lat,
  lng: l.lng,
  createdAt: l.createdAt ?? null,
});

placesRouter.get('/contributions', async (req, res) => {
  requireStar(req);
  const mine = await LocalModel.find({ addedBy: req.account._id }).sort({ createdAt: -1 }).limit(200).lean();
  res.json({ places: mine.map(localOut), total: await LocalModel.countDocuments({ addedBy: req.account._id }) });
});

placesRouter.post('/contributions', async (req, res) => {
  requireStar(req);
  const body = parse(
    z.object({ name: z.string().trim().min(2).max(80), zone: z.string().trim().max(60).optional(), lat, lng }),
    req.body,
  );
  const since = new Date(Date.now() - 24 * 3600_000);
  if ((await LocalModel.countDocuments({ addedBy: req.account._id, createdAt: { $gte: since } })) >= MAX_CONTRIBUTIONS_PER_DAY) {
    throw new HttpError(429, 'Atingiu o limite de locais por dia. Continue amanhã.');
  }
  const region = await regionOf(body);
  const zone = body.zone ?? region.zone;
  const province = region.province || 'Por classificar';
  const searchKey = searchKeyOf(`${body.name} ${zone}`);
  // O mesmo nome a menos de ~150 m já está registado.
  const near = await LocalModel.findOne({
    searchKey,
    lat: { $gt: body.lat - 0.0015, $lt: body.lat + 0.0015 },
    lng: { $gt: body.lng - 0.0015, $lt: body.lng + 0.0015 },
  });
  if (near) throw new HttpError(409, 'Este local já está registado aqui.');
  const local = await LocalModel.create({
    name: body.name,
    zone,
    province,
    lat: body.lat,
    lng: body.lng,
    searchKey,
    addedBy: req.account._id,
    addedByRole: req.role,
    addedByName: req.account.name,
    reviewed: false,
  });
  clearSearchCache();
  res.status(201).json({ place: localOut(local) });
});

placesRouter.delete('/contributions/:id', async (req, res) => {
  requireStar(req);
  const id = parse(z.string().regex(/^[0-9a-f]{24}$/i), req.params.id);
  const result = await LocalModel.deleteOne({ _id: id, addedBy: req.account._id });
  if (!result.deletedCount) throw new HttpError(404, 'Local não encontrado.');
  clearSearchCache();
  res.json({ ok: true });
});

/** Destinos recentes do passageiro, mostrados antes de começar a escrever. */
placesRouter.get('/recent', requirePassenger, async (req, res) => {
  const rides = await RideModel.find({ passenger: req.passenger._id, status: { $ne: 'cancelled' } })
    .sort({ createdAt: -1 })
    .limit(30)
    .select('dropoff');
  const seen = new Set<string>();
  const places = [];
  for (const r of rides) {
    if (seen.has(r.dropoff.address)) continue;
    seen.add(r.dropoff.address);
    const [title = r.dropoff.address, ...rest] = r.dropoff.address.split(', ');
    places.push({ title, subtitle: rest.join(', '), address: r.dropoff.address, lat: r.dropoff.lat, lng: r.dropoff.lng });
    if (places.length === 5) break;
  }
  res.json({ places });
});

// Locais guardados do passageiro: Casa, Trabalho e outros com nome à escolha.
const MAX_SAVED_PLACES = 12;
const savedPlace = place.extend({
  kind: z.enum(['home', 'work', 'other']).default('other'),
  label: z.string().trim().min(1).max(40),
});
const listSaved = (p: Request['passenger']) => {
  const order = { home: 0, work: 1, other: 2 };
  return p.savedPlaces
    .map((s) => ({ id: String(s._id), kind: s.kind, label: s.label, address: s.address, lat: s.lat, lng: s.lng }))
    .sort((a, b) => order[a.kind] - order[b.kind] || a.label.localeCompare(b.label));
};

placesRouter.get('/saved', requirePassenger, (req, res) => {
  res.json({ places: listSaved(req.passenger) });
});

placesRouter.post('/saved', requirePassenger, async (req, res) => {
  const body = parse(savedPlace, req.body);
  const places = req.passenger.savedPlaces;
  // Só há uma Casa e um Trabalho: guardar outra vez substitui.
  const existing = body.kind === 'other' ? null : places.find((s) => s.kind === body.kind);
  if (existing) existing.set(body);
  else {
    if (places.length >= MAX_SAVED_PLACES) {
      throw new HttpError(400, `Pode guardar até ${MAX_SAVED_PLACES} locais.`);
    }
    places.push(body);
  }
  await req.passenger.save();
  res.status(201).json({ places: listSaved(req.passenger) });
});

placesRouter.put('/saved/:id', requirePassenger, async (req, res) => {
  const item = req.passenger.savedPlaces.id(param(req));
  if (!item) throw new HttpError(404, 'Local não encontrado.');
  const body = parse(savedPlace, req.body);
  item.set({ ...body, kind: item.kind }); // o tipo (Casa/Trabalho) não muda ao editar
  await req.passenger.save();
  res.json({ places: listSaved(req.passenger) });
});

placesRouter.delete('/saved/:id', requirePassenger, async (req, res) => {
  req.passenger.savedPlaces.id(param(req))?.deleteOne();
  await req.passenger.save();
  res.json({ places: listSaved(req.passenger) });
});

placesRouter.get('/reverse', async (req, res) => {
  res.json({ place: await reverseGeocode(parse(point, req.query)) });
});

// ── Corridas ────────────────────────────────────────────────────────────────
export const ridesRouter = Router();
ridesRouter.use(requireAuth);

ridesRouter.post('/estimate', requirePassenger, async (req, res) => {
  const body = parse(
    z.object({ pickup: point, dropoff: point, stops: z.array(point).max(MAX_STOPS).optional() }),
    req.body,
  );
  // Colaborador de uma empresa cliente: pode viajar por conta dela.
  // Só com o número confirmado: senão, quem criasse conta com o número de um
  // colaborador viajaria por conta da empresa dele.
  const verified = req.passenger.phoneVerified !== false;
  const company = verified ? await companyStatus(req.passenger.phone) : null;
  const companyLocked = !verified && Boolean(await companyStatus(req.passenger.phone));
  res.json({
    ...(await estimate(body.pickup, body.dropoff, body.stops, req.passenger.id as string)),
    company,
    /** É colaborador de uma empresa, mas tem de confirmar o número para viajar por conta dela. */
    ...(companyLocked ? { companyLocked: true } : {}),
    paymentMethods: [
      ...(company ? ['corporate'] : []),
      'cash',
      ...(config.walletEnabled ? ['wallet'] : []),
      ...(electronicPaymentsAvailable() ? ['multicaixa'] : []),
    ],
  });
});

ridesRouter.post('/', requirePassenger, async (req, res) => {
  const body = parse(
    z.object({
      pickup: place,
      /** Opcional nos serviços de preço combinado. */
      dropoff: place.optional(),
      stops: z.array(place).max(MAX_STOPS).optional(),
      category: z.enum(SERVICE_KEYS),
      /** Só para serviços de carga. */
      cargoNote: z.string().trim().max(200).optional(),
      helpers: z.number().int().min(0).max(MAX_HELPERS).optional(),
      /** Preço que o passageiro propõe, em vez do preço da tarifa. */
      offeredFare: z.number().int().positive().optional(),
      paymentMethod: z.enum(['cash', 'wallet', 'multicaixa', 'corporate']),
      /** Chamar primeiro um dos motoristas preferidos. */
      preferredDriverId: objectId.optional(),
    }),
    req.body,
  );
  if (body.paymentMethod === 'wallet' && !config.walletEnabled) {
    throw new HttpError(400, 'O pagamento por carteira não está disponível de momento.');
  }
  if (body.paymentMethod === 'multicaixa' && !electronicPaymentsAvailable()) {
    throw new HttpError(503, 'Pagamento por Multicaixa Express ainda não está disponível.');
  }
  res.status(201).json({ ride: await createRide(req.passenger, body) });
});

/** Corrida em curso de quem faz o pedido. */
ridesRouter.get('/active', async (req, res) => {
  const ride = await RideModel.findOne({ ...mine(req), status: { $in: ACTIVE_STATUSES } }).sort({
    createdAt: -1,
  });
  res.json({ ride: ride ? await serializeRide(ride, viewer(req)) : null });
});

ridesRouter.get('/history', async (req, res) => {
  const rides = await RideModel.find({ ...mine(req), status: { $in: ['completed', 'cancelled'] } })
    .sort({ createdAt: -1 })
    .limit(50);
  res.json({ rides: await Promise.all(rides.map((r) => serializeRide(r))) });
});

ridesRouter.get('/:id', async (req, res) => {
  const ride = await RideModel.findOne({ _id: param(req), ...mine(req) });
  if (!ride) throw new HttpError(404, 'Corrida não encontrada.');
  res.json({ ride: await serializeRide(ride, viewer(req)) });
});

ridesRouter.post('/:id/cancel', async (req, res) => {
  res.json({ ride: await cancelRide(req.role, req.account.id, param(req)) });
});

ridesRouter.post('/:id/rate', async (req, res) => {
  const body = parse(z.object({ stars: z.number().int().min(1).max(5) }), req.body);
  await rateRide(req.role, req.account.id, param(req), body.stars);
  res.json({ ok: true });
});

ridesRouter.post('/:id/accept', requireCompleteDriver, async (req, res) => {
  res.json({ ride: await acceptRide(req.driver, param(req)) });
});

ridesRouter.post('/:id/decline', requireCompleteDriver, async (req, res) => {
  await declineRide(req.driver, param(req));
  res.json({ ok: true });
});

// Negociação de preço
const amount = z.object({ amount: z.number().int().positive() });

ridesRouter.post('/:id/price', requirePassenger, async (req, res) => {
  res.json({ ride: await changePrice(req.passenger, param(req), parse(amount, req.body).amount) });
});

ridesRouter.post('/:id/bids', requireCompleteDriver, async (req, res) => {
  res.status(201).json({ ride: await placeBid(req.driver, param(req), parse(amount, req.body).amount) });
});

ridesRouter.delete('/:id/bids', requireCompleteDriver, async (req, res) => {
  await withdrawBid(req.driver, param(req));
  res.json({ ok: true });
});

ridesRouter.post('/:id/bids/:driverId/accept', requirePassenger, async (req, res) => {
  res.json({ ride: await acceptBid(req.passenger, param(req), param(req, 'driverId')) });
});

ridesRouter.post('/:id/bids/:driverId/decline', requirePassenger, async (req, res) => {
  res.json({ ride: await declineBid(req.passenger, param(req), param(req, 'driverId')) });
});

ridesRouter.post('/:id/status', requireCompleteDriver, async (req, res) => {
  const body = parse(z.object({ status: z.enum(['arrived', 'in_progress', 'completed']) }), req.body);
  res.json({ ride: await advanceRide(req.driver, param(req), body.status) });
});

// ── Motoristas preferidos (passageiro) ──────────────────────────────────────
export const favoritesRouter = Router();
favoritesRouter.use(requireAuth, requirePassenger);

favoritesRouter.get('/', async (req, res) => {
  const q = parse(z.object({ lat: lat.optional(), lng: lng.optional() }), req.query);
  const ids = req.passenger.favoriteDrivers;
  const [drivers, available] = await Promise.all([
    DriverModel.find({ _id: { $in: ids } }),
    availableDriverIds(ids),
  ]);
  const list = drivers.map((d) => {
    const isAvailable = available.has(d.id);
    const coords = d.location?.coordinates;
    const distanceM =
      isAvailable && q.lat !== undefined && q.lng !== undefined && coords?.length === 2
        ? Math.round(haversineM({ lat: q.lat, lng: q.lng }, { lat: coords[1]!, lng: coords[0]! }))
        : null;
    return { ...driverParty(d), available: isAvailable, distanceM };
  });
  // Disponíveis primeiro, depois por nome.
  list.sort((a, b) => Number(b.available) - Number(a.available) || a.name.localeCompare(b.name));
  res.json({ drivers: list });
});

favoritesRouter.put('/:driverId', async (req, res) => {
  const driverId = param(req, 'driverId');
  // Só se pode preferir um motorista com quem já se viajou.
  const travelled = await RideModel.exists({
    passenger: req.passenger._id,
    driver: driverId,
    status: 'completed',
  });
  if (!travelled) throw new HttpError(403, 'Só pode adicionar motoristas com quem já viajou.');
  if (req.passenger.favoriteDrivers.length >= 30) {
    throw new HttpError(400, 'Atingiu o limite de 30 motoristas preferidos.');
  }
  await req.passenger.updateOne({ $addToSet: { favoriteDrivers: driverId } });
  res.json({ ok: true });
});

favoritesRouter.delete('/:driverId', async (req, res) => {
  await req.passenger.updateOne({ $pull: { favoriteDrivers: param(req, 'driverId') } });
  res.json({ ok: true });
});

// ── Catálogo de serviços ────────────────────────────────────────────────────
export const catalogRouter = Router();
catalogRouter.get('/', (_req, res) => {
  res.json({ services: catalog() });
});

// ── Garagem: as viaturas do motorista ───────────────────────────────────────
export const vehiclesRouter = Router();
vehiclesRouter.use(requireAuth, requireDriver);

const vehicleBody = z.object({
  make: z.string().trim().min(1).max(40),
  carModel: z.string().trim().min(1).max(40),
  color: z.string().trim().min(1).max(30),
  plate: z.string().trim().min(3).max(15).transform((v) => v.toUpperCase()),
  category: z.enum(SERVICE_KEYS),
  hasAC: z.boolean().optional(),
  insuranceExpiresAt: z.coerce.date().optional(),
});

/** Trocar de viatura muda os pedidos que o motorista recebe: só offline. */
function requireOffline(req: Request) {
  if (req.driver.isOnline) throw new HttpError(409, 'Fique offline para alterar as suas viaturas.');
}

vehiclesRouter.post('/', async (req, res) => {
  addVehicle(req.driver, parse(vehicleBody, req.body));
  await req.driver.save();
  res.status(201).json({ user: publicAccount('driver', req.driver) });
});

vehiclesRouter.put('/:id', async (req, res) => {
  const id = param(req);
  if (req.driver.vehicle?.id === id) requireOffline(req);
  updateVehicle(req.driver, id, parse(vehicleBody, req.body));
  await req.driver.save();
  res.json({ user: publicAccount('driver', req.driver) });
});

vehiclesRouter.post('/:id/activate', async (req, res) => {
  requireOffline(req);
  activateVehicle(req.driver, param(req));
  await req.driver.save();
  res.json({ user: publicAccount('driver', req.driver) });
});

vehiclesRouter.delete('/:id', async (req, res) => {
  removeVehicle(req.driver, param(req));
  await req.driver.save();
  res.json({ user: publicAccount('driver', req.driver) });
});

// ── Motorista ───────────────────────────────────────────────────────────────
export const driverRouter = Router();
driverRouter.use(requireAuth, requireDriver);

driverRouter.post('/online', async (req, res) => {
  const body = parse(z.object({ online: z.boolean(), location: point.optional() }), req.body);
  // Ficar offline é sempre permitido; só ficar online exige o registo completo.
  if (body.online && !driverIsComplete(req.driver)) {
    throw new HttpError(403, 'Complete o registo: foto de perfil, carta de condução e documentos da viatura.');
  }
  if (body.online && !body.location && !req.driver.location?.coordinates?.length) {
    throw new HttpError(400, 'Active a localização para ficar online.');
  }
  await setDriverOnline(req.driver, body.online, body.location);
  res.json({ user: publicAccount('driver', req.driver), offers: await offersForDriver(req.driver) });
});

driverRouter.post('/location', requireCompleteDriver, async (req, res) => {
  const body = parse(point.extend({ heading: z.number().optional() }), req.body);
  await updateDriverLocation(req.driver.id, body);
  res.json({ ok: true });
});

/** Ofertas pendentes para o motorista (complementa os eventos em tempo real). */
driverRouter.get('/offers', requireCompleteDriver, async (req, res) => {
  res.json({ offers: await offersForDriver(req.driver) });
});

/** O motorista junta-se a uma frota com o código que a empresa lhe deu. */
driverRouter.post('/fleet', async (req, res) => {
  const body = parse(z.object({ code: z.string().trim().min(4).max(12) }), req.body);
  if (req.driver.fleet) throw new HttpError(409, 'Já pertence a uma frota. Saia dela primeiro.');
  const fleet = await FleetModel.findOne({ joinCode: body.code.toUpperCase(), status: 'active' });
  if (!fleet) throw new HttpError(404, 'Código de frota inválido.');
  req.driver.fleet = fleet._id;
  req.driver.fleetName = fleet.name;
  await req.driver.save();
  res.json({ user: publicAccount('driver', req.driver) });
});

driverRouter.delete('/fleet', async (req, res) => {
  req.driver.fleet = undefined;
  req.driver.fleetName = undefined;
  await req.driver.save();
  res.json({ user: publicAccount('driver', req.driver) });
});

driverRouter.get('/summary', async (req, res) => {
  const start = new Date();
  start.setHours(0, 0, 0, 0);
  const rides = await RideModel.find({
    driver: req.driver._id,
    status: 'completed',
    completedAt: { $gte: start },
  }).select('fare commission');
  res.json({
    ridesToday: rides.length,
    earningsToday: rides.reduce((sum, r) => sum + r.fare - r.commission, 0),
    currency: config.currency,
    commission: commissionState(req.driver),
    /** Nota da conta no ecrã principal, já escrita pelo servidor (o app só a mostra). */
    note: accountNote(req.driver),
  });
});

const commissionState = (d: { commissionDue: number; freeRidesLeft?: number | null }) => ({
  due: d.commissionDue,
  balance: balanceOf(d),
  freeRidesLeft: freeRidesLeft(d),
  rate: settings.commissionRate,
  limit: config.commission.debtLimit,
  enforced: config.commission.enforced,
  payInfo: config.commission.payInfo,
});

// ── Pagamentos ao Bazá: comissões e mensalidade por viatura ──
driverRouter.get('/account', async (req, res) => {
  res.json(await driverAccount(req.driver));
});

driverRouter.post('/payments', async (req, res) => {
  const body = parse(
    z.object({
      kind: z.enum(['subscription', 'commission']),
      vehicleId: objectId.optional(),
      months: z.number().int().min(1).max(24).optional(),
      amount: z.number().int().positive().max(100_000_000).optional(),
      method: z.enum(PAYMENT_METHODS),
      reference: z.string().trim().max(80).optional(),
    }),
    req.body,
  );
  res.status(201).json({ request: requestOut(await createPaymentRequest(req.driver, body)) });
});

// ── Saldo pré-pago: carregar por referência e pagar a mensalidade com o saldo ──
driverRouter.post('/topup', async (req, res) => {
  const body = parse(z.object({ amount: z.coerce.number().int() }), req.body);
  res.status(201).json({ payment: sessionView(await createTopup(req.driver, body.amount)) });
});

/** Referências geradas (as por pagar primeiro), para o motorista as voltar a ver. */
driverRouter.get('/topups', async (req, res) => {
  const list = await PaymentModel.find({ user: req.driver._id, role: 'driver', purpose: 'driver_fee' }).sort({ createdAt: -1 }).limit(10);
  res.json({ payments: list.map(sessionView) });
});

driverRouter.post('/subscription/pay', async (req, res) => {
  const body = parse(z.object({ vehicleId: objectId, months: z.coerce.number().int().min(1).max(24) }), req.body);
  const until = await paySubscriptionFromBalance(req.driver, body.vehicleId, body.months);
  res.json({ paidUntil: until, account: await driverAccount(req.driver) });
});

driverRouter.delete('/payments/:id', async (req, res) => {
  const result = await PaymentRequestModel.deleteOne({ _id: parse(objectId, req.params.id), driver: req.driver._id, status: 'pending' });
  if (!result.deletedCount) throw new HttpError(404, 'Pedido não encontrado ou já tratado.');
  res.json({ ok: true });
});

/** Conta-corrente das comissões do motorista: dívida actual e últimos movimentos. */
driverRouter.get('/commission', async (req, res) => {
  const entries = await CommissionEntryModel.find({ driver: req.driver._id }).sort({ createdAt: -1 }).limit(60);
  res.json({
    ...commissionState(req.driver),
    entries: entries.map((e) => ({
      id: e.id as string,
      type: e.type,
      amount: e.amount,
      note: e.note ?? null,
      dueAfter: e.dueAfter,
      createdAt: e.get('createdAt') as Date,
    })),
  });
});

// ── Carteira (passageiro e motorista têm cada um a sua) ─────────────────────
export const walletRouter = Router();
walletRouter.use(requireAuth, (_req, _res, next) => {
  if (!config.walletEnabled) throw new HttpError(403, 'A carteira não está disponível de momento.');
  next();
});

walletRouter.get('/', async (req, res) => {
  const [txs, withdrawals] = await Promise.all([
    WalletTxModel.find({ user: req.account._id, role: req.role }).sort({ createdAt: -1 }).limit(50),
    req.role === 'driver'
      ? WithdrawalModel.find({ driver: req.account._id, status: 'pending' }).sort({ createdAt: -1 })
      : [],
  ]);
  res.json({
    balance: req.account.walletBalance,
    currency: config.currency,
    topupAvailable: electronicPaymentsAvailable(),
    // Levantamentos: só motoristas, que recebem na carteira os ganhos das corridas.
    canWithdraw: req.role === 'driver',
    minWithdrawal: config.minWithdrawal,
    debtLimit: req.role === 'driver' ? config.driverDebtLimit : null,
    pendingWithdrawals: withdrawals.map((w) => ({
      id: w.id as string,
      amount: w.amount,
      iban: w.iban,
      createdAt: w.get('createdAt') as Date,
    })),
    transactions: txs.map((t) => ({
      id: t.id as string,
      amount: t.amount,
      type: t.type,
      description: t.description,
      createdAt: t.get('createdAt') as Date,
    })),
  });
});

walletRouter.post('/topup', async (req, res) => {
  const body = parse(z.object({ amount: z.number().int().min(500).max(500_000) }), req.body);
  const payment = await createPayment({
    role: req.role,
    userId: req.account._id,
    amount: body.amount,
    purpose: 'topup',
    phone: req.account.phone,
  });
  if (payment.status !== 'paid') throw new HttpError(402, 'O pagamento não foi aprovado.');
  await adjustWallet(req.role, req.account._id, body.amount, 'topup', 'Carregamento da carteira');
  res.json({ ok: true });
});

/**
 * Pedido de levantamento: o valor sai logo da carteira e fica pendente até a
 * transferência bancária ser feita (processo manual, fora da app).
 */
walletRouter.post('/withdraw', requireDriver, async (req, res) => {
  const body = parse(
    z.object({
      amount: z.number().int().min(config.minWithdrawal).max(5_000_000),
      iban: z
        .string()
        .transform((v) => v.replace(/\s+/g, '').toUpperCase())
        .refine((v) => /^AO\d{23}$/.test(v), 'IBAN angolano inválido (AO06 seguido de 21 dígitos)'),
    }),
    req.body,
  );
  const ok = await adjustWallet('driver', req.driver._id, -body.amount, 'withdrawal', 'Levantamento para conta bancária', {
    requireFunds: true,
  });
  if (!ok) throw new HttpError(402, 'Saldo insuficiente para este levantamento.');
  await WithdrawalModel.create({ driver: req.driver._id, amount: body.amount, iban: body.iban });
  res.status(201).json({ ok: true });
});

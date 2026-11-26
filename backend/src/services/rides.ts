import type { Types } from 'mongoose';
import {
  HELPER_FEE,
  MAX_HELPERS,
  MAX_STOPS,
  SERVICE_KEYS,
  config,
  service,
  type RideCategory,
} from '../config.js';
import { HttpError } from '../http.js';
import {
  DriverModel,
  PassengerModel,
  driverIsComplete,
  driverParty,
  passengerParty,
  servedCategories,
  verification,
  type DriverDoc,
  type PassengerDoc,
  type Role,
} from '../models/accounts.js';
import { ACTIVE_STATUSES, RideModel, type RideDoc, type RideStatus } from '../models/Ride.js';
import { getRoute, haversineM, type LatLng, type Place, type RouteInfo } from './geo.js';
import { CommissionEntryModel } from '../models/misc.js';
import { emailLayout, notifyByEmail, p } from './email.js';
import { adjustWallet, createPayment } from './payments.js';
import { authorizeCompanyRide } from './corporate.js';
import { commissionFor, isNegotiated, monthlyFee } from './settings.js';
import { sendSms } from './sms.js';
import { NO_SURGE, combineSurge, fareFor, pricing, type Surge } from './pricing.js';
import { balanceOf, coversFee, coversFeeFilter, driversFree, freeRidesLeft, noBalanceMessage } from './balance.js';
import { emitToUser } from './realtime.js';

type Id = Types.ObjectId | string;

const DRIVER_STALE_MS = 3 * 60_000;
const ON_TRIP: RideStatus[] = ['accepted', 'arrived', 'in_progress'];

/** Preço pela tarifa (fórmula e tarifas em services/pricing.ts, editáveis no painel). */
export function calcFare(category: RideCategory, route: RouteInfo, helpers = 0, stops = 0, multiplier = 1) {
  return fareFor(category, route.distanceM, route.durationS, stops, multiplier, helpers);
}

/**
 * Procura à volta de um ponto de recolha: pedidos à procura de motorista feitos
 * nos últimos minutos e motoristas livres (online, com posição recente, sem corrida).
 */
export async function demandAt(point: LatLng) {
  const s = pricing.surge;
  const radiusM = s.radiusKm * 1000;
  // Caixa à volta do ponto (1° de latitude ≈ 111 km), afinada depois pela distância real.
  const dLat = radiusM / 111_000;
  const dLng = radiusM / (111_000 * Math.max(0.2, Math.cos((point.lat * Math.PI) / 180)));
  const [searching, near, busy] = await Promise.all([
    RideModel.find({
      status: 'searching',
      createdAt: { $gte: new Date(Date.now() - s.windowMin * 60_000) },
      'pickup.lat': { $gte: point.lat - dLat, $lte: point.lat + dLat },
      'pickup.lng': { $gte: point.lng - dLng, $lte: point.lng + dLng },
    }).select('pickup'),
    DriverModel.find({
      ...availableFilter(),
      location: { $nearSphere: { $geometry: { type: 'Point', coordinates: [point.lng, point.lat] }, $maxDistance: radiusM } },
    })
      .select('_id')
      .limit(500),
    busyDriverIds(),
  ]);
  const busySet = new Set(busy.map(String));
  return {
    searching: searching.filter((r) => haversineM(point, r.pickup) <= radiusM).length,
    free: near.filter((d) => !busySet.has(d.id as string)).length,
  };
}

/** Taxa por procura para um ponto de recolha, neste momento. */
export async function surgeAt(point: LatLng): Promise<Surge> {
  const demand = pricing.surge.autoEnabled ? await demandAt(point).catch(() => null) : null;
  return combineSurge(demand);
}

// O preço que o passageiro viu na estimativa vale quando confirma o pedido
// (até 10 min e se a recolha não mudar mais de 1 km): a taxa por procura não
// pode subir entre o momento em que vê o preço e o momento em que pede.
const QUOTE_TTL_MS = 10 * 60_000;
const quotes = new Map<string, { surge: Surge; at: number; point: LatLng }>();

async function surgeForPassenger(passengerId: string | undefined, point: LatLng, fresh = false): Promise<Surge> {
  const key = passengerId ? String(passengerId) : '';
  const q = key ? quotes.get(key) : undefined;
  if (!fresh && q && Date.now() - q.at < QUOTE_TTL_MS && haversineM(q.point, point) <= 1000) return q.surge;
  const surge = await surgeAt(point);
  if (key) {
    quotes.set(key, { surge, at: Date.now(), point });
    if (quotes.size > 5000) for (const [k, v] of quotes) if (Date.now() - v.at > QUOTE_TTL_MS) quotes.delete(k);
  }
  return surge;
}

const surgeOut = (s: Surge) => (s.multiplier > 1 ? { multiplier: s.multiplier, reason: s.reason, label: s.label } : null);

/** O catálogo de serviços, como o app o mostra. */
export function catalog() {
  return SERVICE_KEYS.map((category) => {
    const t = service(category);
    return {
      category,
      group: t.group,
      label: t.label,
      description: t.description,
      seats: t.seats ?? null,
      capacityKg: t.capacityKg ?? null,
      helpers: t.helpers ?? false,
      negotiated: isNegotiated(category),
      monthlyFee: monthlyFee(category),
    };
  });
}

export async function estimate(pickup: LatLng, dropoff: LatLng, stops: LatLng[] = [], passengerId?: string) {
  const [route, surge] = await Promise.all([getRoute(pickup, dropoff, stops), surgeForPassenger(passengerId, pickup, true)]);
  return {
    distanceM: route.distanceM,
    durationS: route.durationS,
    geometry: route.geometry,
    currency: config.currency,
    helperFee: HELPER_FEE,
    maxHelpers: MAX_HELPERS,
    stopFee: pricing.stopFee,
    maxStops: MAX_STOPS,
    /** Regras da negociação de preço, para o app calcular os limites. */
    negotiation: { minFactor: config.minFareFactor, maxFactor: config.maxFareFactor, step: config.fareStep },
    // O preço já inclui as paragens pedidas.
    // Nos serviços de preço combinado não há tarifa: o preço acerta-se com o motorista.
    options: catalog().map((s) => ({ ...s, fare: s.negotiated ? null : calcFare(s.category, route, 0, stops.length, surge.multiplier) })),
    /** Taxa por procura em vigor (já incluída nos preços), para o app a explicar. */
    surge: surgeOut(surge),
  };
}

/** Limites e passo da negociação para um preço de tarifa. */
export function fareBounds(suggested: number, negotiated = false) {
  const step = config.fareStep;
  // Preço combinado: qualquer valor razoável, sem tarifa de referência.
  if (negotiated) return { min: step, max: 5_000_000, step };
  return {
    min: Math.max(step, Math.ceil((suggested * config.minFareFactor) / step) * step),
    max: Math.ceil((suggested * config.maxFareFactor) / step) * step,
    step,
  };
}

function checkAmount(suggested: number, amount: number, negotiated = false) {
  const { min, max, step } = fareBounds(suggested, negotiated);
  if (amount % step !== 0) throw new HttpError(400, `O preço tem de ser múltiplo de ${step} Kz.`);
  if (amount < min || amount > max) {
    throw new HttpError(400, `O preço tem de estar entre ${min} e ${max} Kz.`);
  }
}

/**
 * Quem vai ver a corrida: o passageiro vê todas as propostas dos motoristas;
 * cada motorista vê apenas a sua.
 */
type Viewer = 'passenger' | { driverId: string } | undefined;

export async function serializeRide(ride: RideDoc, viewer?: Viewer) {
  const [passenger, driver, preferred] = await Promise.all([
    PassengerModel.findById(ride.passenger),
    ride.driver ? DriverModel.findById(ride.driver) : null,
    ride.preferredDriver ? DriverModel.findById(ride.preferredDriver).select('name') : null,
  ]);
  const active = ON_TRIP.includes(ride.status);
  const coords = active ? driver?.location?.coordinates : undefined;
  return {
    id: ride.id as string,
    status: ride.status,
    pickup: ride.pickup,
    dropoff: ride.dropoff,
    stops: ride.stops,
    category: ride.category,
    group: service(ride.category).group,
    cargoNote: ride.cargoNote ?? null,
    helpers: ride.helpers,
    paymentMethod: ride.paymentMethod,
    companyName: ride.companyName ?? null,
    paymentStatus: ride.paymentStatus,
    distanceM: ride.distanceM,
    durationS: ride.durationS,
    routeGeometry: ride.routeGeometry ?? null,
    fare: ride.fare,
    suggestedFare: ride.suggestedFare ?? ride.fare,
    fareBounds: fareBounds(ride.suggestedFare ?? ride.fare, isNegotiated(ride.category)),
    /** Taxa por procura aplicada ao preço da tarifa (null sem taxa). */
    surge: (ride.surgeMultiplier ?? 1) > 1 ? { multiplier: ride.surgeMultiplier, label: ride.surgeLabel ?? null } : null,
    /** Preço combinado entre cliente e motorista (sem tarifa calculada). */
    negotiated: isNegotiated(ride.category),
    /** Ainda sem preço: os motoristas têm de propor um. */
    priceOpen: ride.fare === 0,
    noDestination: ride.noDestination,
    bids: viewer === 'passenger' && ride.status === 'searching' ? await serializeBids(ride) : [],
    myBid:
      viewer && viewer !== 'passenger'
        ? (ride.bids.find((b) => String(b.driver) === viewer.driverId)?.amount ?? null)
        : null,
    currency: config.currency,
    passenger: passenger ? passengerParty(passenger) : null,
    driver: driver ? driverParty(driver) : null,
    driverLocation: coords?.length === 2 ? { lat: coords[1], lng: coords[0] } : null,
    /** Motorista preferido que o passageiro chamou, se houve. */
    preferredDriver: preferred ? { id: preferred.id as string, name: preferred.name } : null,
    /** true enquanto o pedido está reservado ao motorista preferido. */
    exclusive: ride.status === 'searching' && !!ride.exclusiveFor,
    cancelledBy: ride.cancelledBy ?? null,
    passengerRating: ride.passengerRating ?? null,
    driverRating: ride.driverRating ?? null,
    createdAt: ride.get('createdAt') as Date,
    completedAt: ride.completedAt ?? null,
  };
}

/** As propostas de preço, com os dados de cada motorista, mais baratas primeiro. */
async function serializeBids(ride: RideDoc) {
  if (!ride.bids.length) return [];
  const drivers = await DriverModel.find({ _id: { $in: ride.bids.map((b) => b.driver) } });
  const byId = new Map(drivers.map((d) => [d.id as string, d]));
  return ride.bids
    .filter((b) => byId.has(String(b.driver)))
    .map((b) => ({ driver: driverParty(byId.get(String(b.driver))!), amount: b.amount }))
    .sort((a, b) => a.amount - b.amount);
}

/** Avisa passageiro e motorista de que a corrida mudou. */
export async function notifyRide(ride: RideDoc) {
  const payload = await serializeRide(ride, 'passenger');
  emitToUser(String(ride.passenger), 'ride:update', payload);
  if (ride.driver) {
    emitToUser(String(ride.driver), 'ride:update', await serializeRide(ride, { driverId: String(ride.driver) }));
  }
  return payload;
}

function revokeOffers(ride: RideDoc, except?: string) {
  for (const id of ride.offeredTo) {
    if (String(id) !== except) emitToUser(String(id), 'ride:offer_revoked', { rideId: ride.id });
  }
}

async function busyDriverIds() {
  return RideModel.distinct('driver', { status: { $in: ON_TRIP } });
}

/** Condições para um motorista poder receber pedidos neste momento. */
const availableFilter = () => ({
  isOnline: true,
  blocked: { $ne: true },
  vehicle: { $exists: true },
  license: { $exists: true },
  locationUpdatedAt: { $gte: new Date(Date.now() - DRIVER_STALE_MS) },
});

/** Dos motoristas indicados, quais estão online, com posição recente e sem corrida. */
export async function availableDriverIds(ids: Id[]): Promise<Set<string>> {
  if (!ids.length) return new Set();
  const [free, busy] = await Promise.all([
    DriverModel.find({ _id: { $in: ids }, ...availableFilter() }).select('_id'),
    busyDriverIds(),
  ]);
  const busySet = new Set(busy.map(String));
  return new Set(free.map((d) => d.id as string).filter((id) => !busySet.has(id)));
}

/**
 * Envia a oferta: só ao motorista preferido enquanto o pedido lhe estiver
 * reservado; caso contrário, aos motoristas livres perto do ponto de recolha.
 */
export async function offerRide(ride: RideDoc) {
  let drivers: DriverDoc[];
  if (ride.exclusiveFor) {
    const available = await availableDriverIds([ride.exclusiveFor]);
    const driver = available.size ? await DriverModel.findById(ride.exclusiveFor) : null;
    drivers = driver && coversFee(driver, ride.commission) ? [driver] : [];
  } else {
    drivers = await DriverModel.find({
      _id: { $nin: [...ride.declinedBy, ...ride.offeredTo, ...(await busyDriverIds())] },
      ...availableFilter(),
      // Só quem tem saldo para a taxa desta corrida (ou viagens grátis).
      ...coversFeeFilter(ride.commission),
      'vehicle.serves': ride.category,
      location: {
        $nearSphere: {
          $geometry: { type: 'Point', coordinates: [ride.pickup.lng, ride.pickup.lat] },
          $maxDistance: config.driverSearchRadiusM,
        },
      },
    }).limit(15);
  }
  if (!drivers.length) return;

  await RideModel.updateOne(
    { _id: ride._id },
    { $addToSet: { offeredTo: { $each: drivers.map((d) => d._id) } } },
  );
  const payload = await serializeRide(ride);
  for (const d of drivers) emitToUser(d.id, 'ride:offer', payload);
}

/** Corridas à procura de motorista que este motorista pode aceitar. */
export async function offersForDriver(driver: DriverDoc) {
  const coords = driver.location?.coordinates;
  if (!driver.isOnline || !driverIsComplete(driver) || coords?.length !== 2) return [];
  if (await RideModel.exists({ driver: driver._id, status: { $in: ON_TRIP } })) return [];
  const here = { lat: coords[1]!, lng: coords[0]! };
  const [direct, open] = await Promise.all([
    // Pedidos directos de passageiros que escolheram este motorista.
    RideModel.find({ status: 'searching', exclusiveFor: driver._id, declinedBy: { $ne: driver._id } }),
    RideModel.find({
      status: 'searching',
      exclusiveFor: null,
      category: { $in: servedCategories(driver.vehicle!) },
      declinedBy: { $ne: driver._id },
    })
      .sort({ createdAt: 1 })
      .limit(50),
  ]);
  const nearby = open.filter((r) => haversineM(here, r.pickup) <= config.driverSearchRadiusM);
  const rides = [...direct, ...nearby].filter((r) => coversFee(driver, r.commission));
  if (rides.length) {
    await RideModel.updateMany(
      { _id: { $in: rides.map((r) => r._id) } },
      { $addToSet: { offeredTo: driver._id } },
    );
  }
  return Promise.all(rides.slice(0, 5).map((r) => serializeRide(r, { driverId: driver.id })));
}

function later(delayMs: number, fn: () => Promise<void>) {
  setTimeout(() => fn().catch((err) => console.error(err)), delayMs).unref();
}

async function expireSearch(rideId: string) {
  const current = await RideModel.findOne({ _id: rideId, status: 'searching' }).select('searchUntil');
  if (!current) return;
  // A procura foi prolongada (novo preço ou proposta de um motorista): volta a verificar mais tarde.
  const remaining = (current.searchUntil?.getTime() ?? 0) - Date.now();
  if (remaining > 500) {
    later(remaining, () => expireSearch(rideId));
    return;
  }
  const ride = await RideModel.findOneAndUpdate(
    { _id: rideId, status: 'searching' },
    { status: 'no_drivers', bids: [] },
    { returnDocument: 'after' },
  );
  if (!ride) return;
  revokeOffers(ride);
  await notifyRide(ride);
}

/**
 * O motorista preferido não respondeu (ou recusou): o pedido deixa de lhe
 * estar reservado e passa para todos os motoristas próximos.
 */
async function releaseExclusive(rideId: string) {
  const before = await RideModel.findOneAndUpdate(
    { _id: rideId, status: 'searching', exclusiveFor: { $ne: null } },
    { $unset: { exclusiveFor: 1 } },
  );
  if (!before) return;
  emitToUser(String(before.exclusiveFor), 'ride:offer_revoked', { rideId });
  const ride = await RideModel.findById(rideId);
  if (!ride) return;
  await RideModel.updateOne({ _id: ride._id }, { $addToSet: { declinedBy: before.exclusiveFor } });
  await offerRide(ride);
  await notifyRide(ride);
}

/** No arranque: retoma os temporizadores das corridas que ficaram à procura. */
export async function resumeSearches() {
  const rides = await RideModel.find({ status: 'searching' });
  for (const ride of rides) {
    const age = Date.now() - (ride.get('createdAt') as Date).getTime();
    const until = ride.searchUntil?.getTime() ?? Date.now();
    later(Math.max(0, until - Date.now()), () => expireSearch(ride.id));
    if (ride.exclusiveFor) {
      later(Math.max(0, config.preferredTimeoutMs - age), () => releaseExclusive(ride.id));
    }
  }
}

export async function createRide(
  passenger: PassengerDoc,
  input: {
    pickup: Place;
    /** Opcional nos serviços de preço combinado. */
    dropoff?: Place;
    category: RideCategory;
    paymentMethod: 'cash' | 'wallet' | 'multicaixa' | 'corporate';
    /** Paragens intermédias, pela ordem em que se fazem. */
    stops?: Place[];
    preferredDriverId?: string;
    cargoNote?: string;
    helpers?: number;
    /** Preço proposto pelo passageiro, se não quiser o da tarifa. */
    offeredFare?: number;
  },
) {
  if (await RideModel.exists({ passenger: passenger._id, status: { $in: ACTIVE_STATUSES } })) {
    throw new HttpError(409, 'Já tem uma corrida em curso.');
  }
  const suspended = suspensionMessage(passenger);
  if (suspended) throw new HttpError(403, suspended);
  const negotiated = isNegotiated(input.category);
  if (!input.dropoff && !negotiated) throw new HttpError(400, 'Indique o destino.');
  const noDestination = !input.dropoff;
  const dropoff: Place = input.dropoff ?? { lat: input.pickup.lat, lng: input.pickup.lng, address: 'Destino a combinar' };
  if (!noDestination && haversineM(input.pickup, dropoff) < 100) {
    throw new HttpError(400, 'O destino é demasiado perto do ponto de recolha.');
  }

  const { preferredDriverId, cargoNote, helpers: wantedHelpers, offeredFare, dropoff: _given, ...rideInput } = input;
  const svc = service(input.category);
  const isCargo = svc.group === 'cargo';
  // Nos serviços de preço combinado o motorista precisa de saber o que é para fazer.
  if ((isCargo || negotiated) && (cargoNote?.trim().length ?? 0) < 3) {
    throw new HttpError(400, isCargo ? 'Descreva o que vai transportar.' : 'Descreva o serviço que precisa.');
  }
  const helpers = isCargo && svc.helpers ? Math.min(wantedHelpers ?? 0, MAX_HELPERS) : 0;
  let preferred: DriverDoc | null = null;
  if (preferredDriverId) {
    if (!passenger.favoriteDrivers.some((id) => String(id) === preferredDriverId)) {
      throw new HttpError(400, 'Esse motorista não está nos seus preferidos.');
    }
    const available = await availableDriverIds([preferredDriverId]);
    preferred = available.size ? await DriverModel.findById(preferredDriverId) : null;
    if (!preferred) throw new HttpError(409, 'O motorista não está disponível neste momento.');
    if (!servedCategories(preferred.vehicle!).includes(input.category)) {
      throw new HttpError(400, 'A categoria não corresponde à viatura desse motorista.');
    }
  }

  const stops = input.stops ?? [];
  const route = noDestination
    ? { distanceM: 0, durationS: 0, geometry: null }
    : await getRoute(input.pickup, dropoff, stops);
  // Preço combinado: sem tarifa. Vale o que o cliente propuser; sem proposta,
  // fica em aberto (0) e são os motoristas a propor.
  // Taxa por procura: a da estimativa que o passageiro acabou de ver.
  const surge = negotiated ? NO_SURGE : await surgeForPassenger(passenger.id as string, input.pickup);
  const suggestedFare = negotiated ? 0 : calcFare(input.category, route, helpers, stops.length, surge.multiplier);
  if (offeredFare !== undefined) checkAmount(suggestedFare, offeredFare, negotiated);
  const fare = offeredFare ?? suggestedFare;
  if (input.paymentMethod === 'wallet' && passenger.walletBalance < fare) {
    throw new HttpError(402, 'Saldo insuficiente na carteira. Carregue ou escolha outro pagamento.');
  }
  // Por conta da empresa: o colaborador tem de estar autorizado e a corrida caber no limite do mês.
  let company: Awaited<ReturnType<typeof authorizeCompanyRide>> | null = null;
  if (input.paymentMethod === 'corporate') {
    if (negotiated || fare <= 0) throw new HttpError(400, 'Os serviços de preço a combinar não podem ser pagos por conta da empresa.');
    if (passenger.phoneVerified === false) {
      throw new HttpError(403, 'Confirme o seu número de telefone para viajar por conta da empresa.');
    }
    company = await authorizeCompanyRide(passenger.phone, fare);
  }
  const ride = await RideModel.create({
    passenger: passenger._id,
    company: company?._id,
    companyName: company?.name,
    ...rideInput,
    dropoff,
    noDestination,
    cargoNote: isCargo || negotiated ? cargoNote!.trim() : undefined,
    helpers,
    preferredDriver: preferred?._id,
    exclusiveFor: preferred?._id,
    distanceM: route.distanceM,
    durationS: route.durationS,
    routeGeometry: route.geometry ?? undefined,
    fare,
    suggestedFare,
    ...(surge.multiplier > 1 ? { surgeMultiplier: surge.multiplier, surgeLabel: surge.label ?? undefined } : {}),
    searchUntil: new Date(Date.now() + config.searchTimeoutMs),
    commission: commissionFor(input.category, fare),
  });
  later(config.searchTimeoutMs, () => expireSearch(ride.id));
  if (preferred) later(config.preferredTimeoutMs, () => releaseExclusive(ride.id));
  await offerRide(ride);
  return serializeRide(ride, 'passenger');
}

export async function acceptRide(driver: DriverDoc, rideId: string) {
  if (!driver.isOnline) throw new HttpError(409, 'Fique online para aceitar corridas.');
  if (await RideModel.exists({ driver: driver._id, status: { $in: ON_TRIP } })) {
    throw new HttpError(409, 'Já tem uma corrida em curso.');
  }
  if (await RideModel.exists({ _id: rideId, status: 'searching', fare: 0 })) {
    throw new HttpError(409, 'Este pedido ainda não tem preço: proponha o seu.');
  }
  const wanted = await RideModel.findById(rideId).select('commission');
  if (wanted && !coversFee(driver, wanted.commission)) throw new HttpError(402, noBalanceMessage(wanted.commission));
  const ride = await RideModel.findOneAndUpdate(
    {
      _id: rideId,
      status: 'searching',
      category: { $in: servedCategories(driver.vehicle!) },
      // Um pedido reservado só pode ser aceite pelo motorista escolhido.
      exclusiveFor: { $in: [null, driver._id] },
    },
    { status: 'accepted', driver: driver._id, acceptedAt: new Date(), bids: [], $unset: { exclusiveFor: 1 } },
    { returnDocument: 'after' },
  );
  if (!ride) throw new HttpError(409, 'Esta corrida já não está disponível.');
  revokeOffers(ride, driver.id);
  return notifyRide(ride);
}

export async function declineRide(driver: DriverDoc, rideId: string) {
  const ride = await RideModel.findOneAndUpdate(
    { _id: rideId, status: 'searching' },
    { $addToSet: { declinedBy: driver._id } },
  );
  if (ride && String(ride.exclusiveFor ?? '') === driver.id) await releaseExclusive(rideId);
}

// ── Negociação de preço ─────────────────────────────────────────────────────
// O passageiro propõe um preço; cada motorista pode aceitá-lo ou responder com
// outro; o passageiro aceita uma proposta, recusa-a ou muda o seu preço — até
// haver acordo.

const searchingFor = (rideId: string, passengerId: Types.ObjectId) =>
  ({ _id: rideId, passenger: passengerId, status: 'searching' }) as const;

/** O passageiro muda o preço que oferece: os motoristas recebem o pedido de novo. */
export async function changePrice(passenger: PassengerDoc, rideId: string, amount: number) {
  const current = await RideModel.findOne(searchingFor(rideId, passenger._id));
  if (!current) throw new HttpError(409, 'Esta corrida já não está à procura de motorista.');
  checkAmount(current.suggestedFare ?? current.fare, amount, isNegotiated(current.category));
  if (current.paymentMethod === 'wallet' && passenger.walletBalance < amount) {
    throw new HttpError(402, 'Saldo insuficiente na carteira para esse preço.');
  }
  revokeOffers(current);
  const ride = await RideModel.findOneAndUpdate(
    searchingFor(rideId, passenger._id),
    {
      fare: amount,
      commission: commissionFor(current.category, amount),
      // Preço novo: as propostas e recusas anteriores deixam de contar.
      bids: [],
      declinedBy: [],
      offeredTo: [],
      searchUntil: new Date(Date.now() + config.searchTimeoutMs),
    },
    { returnDocument: 'after' },
  );
  if (!ride) throw new HttpError(409, 'Esta corrida já não está à procura de motorista.');
  later(config.searchTimeoutMs, () => expireSearch(ride.id));
  await offerRide(ride);
  return notifyRide(ride);
}

/** Um motorista responde com outro preço (ou altera a proposta que já fez). */
export async function placeBid(driver: DriverDoc, rideId: string, amount: number) {
  if (!driver.isOnline) throw new HttpError(409, 'Fique online para fazer propostas.');
  if (await RideModel.exists({ driver: driver._id, status: { $in: ON_TRIP } })) {
    throw new HttpError(409, 'Já tem uma corrida em curso.');
  }
  const filter = {
    _id: rideId,
    status: 'searching' as const,
    category: { $in: servedCategories(driver.vehicle!) },
    exclusiveFor: { $in: [null, driver._id] },
  };
  const current = await RideModel.findOne(filter);
  if (!current) throw new HttpError(409, 'Esta corrida já não está disponível.');
  checkAmount(current.suggestedFare ?? current.fare, amount, isNegotiated(current.category));
  if (amount === current.fare) throw new HttpError(400, 'Esse é o preço do passageiro: basta aceitar a corrida.');
  const bidFee = commissionFor(current.category, amount);
  if (!coversFee(driver, bidFee)) throw new HttpError(402, noBalanceMessage(bidFee));

  await RideModel.updateOne(filter, { $pull: { bids: { driver: driver._id } } });
  const extended = new Date(Date.now() + config.bidExtensionMs);
  const ride = await RideModel.findOneAndUpdate(
    filter,
    {
      $push: { bids: { driver: driver._id, amount } },
      $addToSet: { offeredTo: driver._id },
      // Dá tempo ao passageiro para decidir.
      $max: { searchUntil: extended },
    },
    { returnDocument: 'after' },
  );
  if (!ride) throw new HttpError(409, 'Esta corrida já não está disponível.');
  await notifyRide(ride);
  return serializeRide(ride, { driverId: driver.id });
}

export async function withdrawBid(driver: DriverDoc, rideId: string) {
  const ride = await RideModel.findOneAndUpdate(
    { _id: rideId, status: 'searching', 'bids.driver': driver._id },
    { $pull: { bids: { driver: driver._id } } },
    { returnDocument: 'after' },
  );
  if (ride) await notifyRide(ride);
}

/** O passageiro aceita a proposta de um motorista: fica combinado esse preço. */
export async function acceptBid(passenger: PassengerDoc, rideId: string, driverId: string) {
  const current = await RideModel.findOne(searchingFor(rideId, passenger._id));
  const bid = current?.bids.find((b) => String(b.driver) === driverId);
  if (!current || !bid) throw new HttpError(409, 'Essa proposta já não está disponível.');
  if (!(await availableDriverIds([driverId])).size) {
    await RideModel.updateOne({ _id: rideId }, { $pull: { bids: { driver: bid.driver } } });
    await notifyRide((await RideModel.findById(rideId))!);
    throw new HttpError(409, 'Esse motorista já não está disponível.');
  }
  if (current.paymentMethod === 'wallet' && passenger.walletBalance < bid.amount) {
    throw new HttpError(402, 'Saldo insuficiente na carteira para esse preço.');
  }
  // O saldo do motorista pode ter baixado desde a proposta.
  const bidder = await DriverModel.findById(driverId).select('commissionDue freeRidesLeft');
  if (!bidder || !coversFee(bidder, commissionFor(current.category, bid.amount))) {
    await RideModel.updateOne({ _id: rideId }, { $pull: { bids: { driver: bid.driver } } });
    await notifyRide((await RideModel.findById(rideId))!);
    throw new HttpError(409, 'Esse motorista já não está disponível.');
  }
  const ride = await RideModel.findOneAndUpdate(
    { ...searchingFor(rideId, passenger._id), bids: { $elemMatch: { driver: bid.driver, amount: bid.amount } } },
    {
      status: 'accepted',
      driver: bid.driver,
      acceptedAt: new Date(),
      fare: bid.amount,
      commission: commissionFor(current.category, bid.amount),
      bids: [],
      $unset: { exclusiveFor: 1 },
    },
    { returnDocument: 'after' },
  );
  if (!ride) throw new HttpError(409, 'Essa proposta já não está disponível.');
  revokeOffers(ride, driverId);
  return notifyRide(ride);
}

/** O passageiro recusa a proposta de um motorista, que pode fazer outra. */
export async function declineBid(passenger: PassengerDoc, rideId: string, driverId: string) {
  const ride = await RideModel.findOneAndUpdate(
    { ...searchingFor(rideId, passenger._id), 'bids.driver': driverId },
    { $pull: { bids: { driver: driverId } } },
    { returnDocument: 'after' },
  );
  if (!ride) throw new HttpError(409, 'Essa proposta já não está disponível.');
  emitToUser(driverId, 'ride:bid_declined', { rideId });
  return notifyRide(ride);
}

/** Avança o estado da corrida pelo motorista: arrived → in_progress → completed. */
export async function advanceRide(driver: DriverDoc, rideId: string, to: 'arrived' | 'in_progress' | 'completed') {
  const steps = {
    arrived: { from: 'accepted', update: { status: 'arrived', arrivedAt: new Date() } },
    in_progress: { from: 'arrived', update: { status: 'in_progress', startedAt: new Date() } },
    completed: { from: 'in_progress', update: { status: 'completed', completedAt: new Date() } },
  } as const;
  const ride: RideDoc | null = await RideModel.findOneAndUpdate(
    { _id: rideId, driver: driver._id, status: steps[to].from },
    steps[to].update,
    { returnDocument: 'after' },
  );
  if (!ride) throw new HttpError(409, 'A corrida não está no estado esperado.');
  if (to === 'completed') {
    await settleRide(ride);
    sendReceipt(ride).catch((err) => console.error('Recibo não enviado:', (err as Error).message));
  }
  return notifyRide(ride);
}

const PAYMENT_LABEL = { cash: 'Dinheiro', wallet: 'Carteira', multicaixa: 'Multicaixa', corporate: 'Conta da empresa' } as const;
const kz = (n: number) => `${String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ' ')} Kz`;

/** Recibo da corrida para o passageiro: por e-mail se o tiver; por SMS só se estiver ligado. */
async function sendReceipt(ride: RideDoc) {
  const [passenger, driver] = await Promise.all([PassengerModel.findById(ride.passenger), DriverModel.findById(ride.driver)]);
  if (!passenger) return;
  const when = (ride.completedAt ?? new Date()).toLocaleString('pt-PT', { dateStyle: 'short', timeStyle: 'short', timeZone: 'Africa/Luanda' });
  const lines: [string, string][] = [
    ['Data', when],
    ['De', ride.pickup.address],
    ...ride.stops.map((stop, i): [string, string] => [`Paragem ${i + 1}`, stop.address]),
    ['Para', ride.dropoff.address],
    ['Distância', `${(ride.distanceM / 1000).toFixed(1).replace('.', ',')} km`],
    ['Motorista', driver?.name ?? '—'],
    ['Viatura', driver?.vehicle ? `${driver.vehicle.make} ${driver.vehicle.carModel} · ${driver.vehicle.plate}` : '—'],
    ['Pagamento', PAYMENT_LABEL[ride.paymentMethod]],
    ['Total', kz(ride.fare)],
  ];
  if (passenger.email) {
    const row = ([k, v]: [string, string]) =>
      `<tr><td style="padding:6px 12px 6px 0;color:#5B6170;font-size:14px;vertical-align:top">${escapeHtml(k)}</td><td style="padding:6px 0;font-size:14px${k === 'Total' ? ';font-weight:700;font-size:16px' : ''}">${escapeHtml(v)}</td></tr>`;
    notifyByEmail(
      passenger.email,
      `Recibo da sua corrida · ${kz(ride.fare)}`,
      emailLayout('Recibo da corrida', `${p('Obrigado por viajar com o Bazá. Este é o resumo da sua corrida.')}<table style="border-collapse:collapse;margin:4px 0 12px">${lines.map(row).join('')}</table>${p(`Referência: ${String(ride._id).slice(-8).toUpperCase()}`)}`),
    );
  }
  if (config.receiptBySms && passenger.phone) {
    await sendSms(passenger.phone, `Bazá: corrida de ${when}, ${ride.pickup.address} → ${ride.dropoff.address}. Total ${kz(ride.fare)} (${PAYMENT_LABEL[ride.paymentMethod]}). Obrigado!`);
  }
}
const escapeHtml = (v: string) => v.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

/** Cobra o passageiro e paga o motorista no fim da corrida. */
async function settleRide(ride: RideDoc) {
  const driverId = ride.driver!;
  // Viagem grátis: a corrida não desconta taxa e gasta uma das viagens grátis.
  if (ride.commission > 0) {
    const d = await DriverModel.findById(driverId).select('freeRidesLeft commissionDue');
    const left = d ? freeRidesLeft(d) : 0;
    if (d && left > 0) {
      await DriverModel.updateOne({ _id: driverId }, { $set: { freeRidesLeft: left - 1 } });
      await CommissionEntryModel.create({
        driver: driverId,
        type: 'charge',
        amount: 0,
        ride: ride._id,
        note: `Viagem grátis, sem taxa (${left - 1 === 1 ? 'resta 1' : `restam ${left - 1}`})`,
        dueAfter: d.commissionDue,
      });
      ride.commission = 0;
      ride.freeRide = true;
    }
  }
  const net = ride.fare - ride.commission;

  if (ride.paymentMethod === 'wallet') {
    const paid = await adjustWallet(
      'passenger',
      ride.passenger,
      -ride.fare,
      'ride_payment',
      'Pagamento de corrida',
      { ride: ride._id, requireFunds: true },
    );
    // Sem saldo no momento da cobrança: o passageiro paga em dinheiro.
    if (!paid) ride.paymentMethod = 'cash';
  }

  if (ride.paymentMethod === 'multicaixa') {
    try {
      const passenger = await PassengerModel.findById(ride.passenger);
      const payment = await createPayment({
        role: 'passenger',
        userId: ride.passenger,
        amount: ride.fare,
        purpose: 'ride',
        ride: ride._id,
        phone: passenger?.phone,
      });
      if (payment.status !== 'paid') ride.paymentMethod = 'cash';
    } catch (err) {
      console.error('Cobrança electrónica falhou, corrida passa a dinheiro:', err);
      ride.paymentMethod = 'cash';
    }
  }

  if (ride.paymentMethod === 'corporate') {
    // O passageiro não pagou nada: a empresa paga ao Bazá e o Bazá fica a dever
    // ao motorista o valor da corrida menos a comissão. O crédito abate às
    // comissões que ele deva; se sobrar, o saldo fica negativo (a receber).
    const driver = await DriverModel.findByIdAndUpdate(driverId, { $inc: { commissionDue: -net } }, { returnDocument: 'after' }).select('commissionDue');
    await CommissionEntryModel.create({
      driver: driverId,
      type: 'credit',
      amount: net,
      ride: ride._id,
      note: `Corrida por conta de ${ride.companyName ?? 'uma empresa'}`,
      dueAfter: driver?.commissionDue ?? -net,
    });
  } else if (ride.paymentMethod === 'cash') {
    // O motorista recebeu o valor em mão; a comissão sai da carteira dele.
    await adjustWallet('driver', driverId, -ride.commission, 'commission', 'Comissão de corrida em dinheiro', {
      ride: ride._id,
    });
    // Sem carteira, a comissão fica em dívida na conta-corrente do motorista.
    if (!config.walletEnabled && ride.commission > 0) {
      const driver = await DriverModel.findByIdAndUpdate(
        driverId,
        { $inc: { commissionDue: ride.commission } },
        { returnDocument: 'after' },
      ).select('commissionDue');
      await CommissionEntryModel.create({
        driver: driverId,
        type: 'charge',
        amount: ride.commission,
        ride: ride._id,
        note: 'Taxa da corrida',
        dueAfter: driver?.commissionDue ?? ride.commission,
      });
    }
  } else {
    await adjustWallet('driver', driverId, net, 'ride_earning', 'Ganho de corrida', { ride: ride._id });
  }
  ride.paymentStatus = 'paid';
  await ride.save();
}

export async function cancelRide(role: Role, userId: string, rideId: string) {
  const mine = role === 'passenger' ? { passenger: userId } : { driver: userId };
  const allowed: RideStatus[] =
    role === 'passenger' ? ['searching', 'accepted', 'arrived'] : ['accepted', 'arrived'];
  if (!(await RideModel.exists({ _id: rideId, ...mine }))) {
    throw new HttpError(404, 'Corrida não encontrada.');
  }
  const before = await RideModel.findOne({ _id: rideId, ...mine }).select('status acceptedAt');
  // Tarde: o motorista que desiste depois de aceitar; o passageiro que cancela
  // com o motorista já no local, ou passado o período sem penalização.
  const late =
    role === 'driver'
      ? true
      : before?.status === 'arrived' ||
        (before?.status === 'accepted' && Date.now() - (before.acceptedAt?.getTime() ?? Date.now()) > config.cancellation.graceMs);
  const updated = await RideModel.findOneAndUpdate(
    { _id: rideId, ...mine, status: { $in: allowed } },
    { status: 'cancelled', cancelledBy: role, cancelledAt: new Date(), lateCancel: late, bids: [], $unset: { exclusiveFor: 1 } },
    { returnDocument: 'after' },
  );
  if (!updated) throw new HttpError(409, 'Esta corrida já não pode ser cancelada.');
  revokeOffers(updated);
  if (late) await penalizeLateCancel(role, userId);
  return notifyRide(updated);
}

/** Depois de vários cancelamentos tardios em 24 h, a conta fica suspensa por algum tempo. */
async function penalizeLateCancel(role: Role, userId: string) {
  const mine = role === 'passenger' ? { passenger: userId } : { driver: userId };
  const recent = await RideModel.countDocuments({
    ...mine,
    cancelledBy: role,
    lateCancel: true,
    cancelledAt: { $gte: new Date(Date.now() - 24 * 3600_000) },
  });
  if (recent < config.cancellation.maxLate) return;
  const until = new Date(Date.now() + config.cancellation.suspendMs);
  if (role === 'driver') await DriverModel.updateOne({ _id: userId }, { suspendedUntil: until, isOnline: false });
  else await PassengerModel.updateOne({ _id: userId }, { suspendedUntil: until });
  emitToUser(userId, 'account:update', {});
}

/** Mensagem a mostrar a quem está suspenso, ou null. */
export function suspensionMessage(account: { suspendedUntil?: Date | null }): string | null {
  const until = account.suspendedUntil?.getTime() ?? 0;
  if (until <= Date.now()) return null;
  const minutes = Math.ceil((until - Date.now()) / 60_000);
  return `Conta suspensa por cancelamentos repetidos. Volte a tentar dentro de ${minutes} min.`;
}

export async function rateRide(role: Role, userId: string, rideId: string, stars: number) {
  const mine = role === 'passenger' ? { passenger: userId } : { driver: userId };
  const ride = await RideModel.findOne({ _id: rideId, status: 'completed', ...mine });
  if (!ride || !ride.driver) throw new HttpError(404, 'Corrida não encontrada.');

  // O passageiro avalia o motorista e vice-versa, uma única vez.
  const field = role === 'passenger' ? 'driverRating' : 'passengerRating';
  const res = await RideModel.updateOne({ _id: ride._id, [field]: null }, { [field]: stars });
  if (!res.modifiedCount) throw new HttpError(409, 'Já avaliou esta corrida.');
  const inc = { $inc: { ratingSum: stars, ratingCount: 1 } };
  if (role === 'passenger') await DriverModel.updateOne({ _id: ride.driver }, inc);
  else await PassengerModel.updateOne({ _id: ride.passenger }, inc);
}

export async function updateDriverLocation(driverId: string, loc: LatLng & { heading?: number }) {
  await DriverModel.updateOne(
    { _id: driverId },
    {
      location: { type: 'Point', coordinates: [loc.lng, loc.lat] },
      locationUpdatedAt: new Date(),
    },
  );
  const ride = await RideModel.findOne({ driver: driverId, status: { $in: ON_TRIP } }).select('passenger');
  if (ride) {
    emitToUser(String(ride.passenger), 'driver:location', {
      rideId: ride.id,
      lat: loc.lat,
      lng: loc.lng,
      heading: loc.heading ?? null,
    });
  }
}

export async function setDriverOnline(driver: DriverDoc, online: boolean, loc?: LatLng) {
  if (!online && (await RideModel.exists({ driver: driver._id, status: { $in: ON_TRIP } }))) {
    throw new HttpError(409, 'Termine a corrida em curso antes de ficar offline.');
  }
  if (online && config.walletEnabled && driver.walletBalance < -config.driverDebtLimit) {
    throw new HttpError(
      402,
      'Tem comissões por pagar acima do limite. Carregue a carteira para voltar a ficar online.',
    );
  }
  // Saldo pré-pago: quem só faz corridas de tarifa precisa de saldo (ou de
  // viagens grátis) para ficar online. As viaturas de preço combinado pagam a
  // mensalidade e não descontam taxa por corrida.
  if (online && driver.vehicle && !driversFree()) {
    const onlyTariff = servedCategories(driver.vehicle).every((c) => !isNegotiated(c));
    if (onlyTariff && freeRidesLeft(driver) <= 0 && balanceOf(driver) <= 0) {
      throw new HttpError(402, 'Não tem saldo. Carregue o saldo em Menu › O meu saldo para receber pedidos.');
    }
  }
  if (online) {
    const suspended = suspensionMessage(driver);
    if (suspended) throw new HttpError(403, suspended);
  }
  if (online && driver.blocked) {
    throw new HttpError(403, `A sua conta está suspensa${driver.blockedReason ? `: ${driver.blockedReason}` : '.'} Contacte o suporte do Bazá.`);
  }
  if (online) {
    const state = verification(driver);
    if (state === 'pending') throw new HttpError(403, 'Os seus documentos estão em análise. Avisamos quando puder começar.');
    if (state === 'rejected') throw new HttpError(403, 'Um dos seus documentos foi rejeitado. Corrija-o no menu.');
  }
  if (online) {
    const active = driver.vehicles.id(driver.vehicle?.id ?? '');
    // Viaturas de preço combinado: mensalidade em dia para receber pedidos.
    const fee = active ? monthlyFee(active.category) : 0;
    if (active && fee > 0) {
      if (!active.paidUntil) {
        // Primeira vez com mensalidade em vigor: período grátis de experiência.
        active.paidUntil = new Date(Date.now() + config.subscriptionTrialDays * 86_400_000);
      } else if (active.paidUntil.getTime() < Date.now()) {
        throw new HttpError(
          402,
          `A mensalidade desta viatura (${kz(fee)}) terminou a ${active.paidUntil.toLocaleDateString('pt-PT')}. ${config.commission.payInfo}`,
        );
      }
    }
    if (active?.insuranceExpiresAt && active.insuranceExpiresAt.getTime() < Date.now()) {
      throw new HttpError(403, 'O seguro da viatura activa caducou. Actualize-o em "As minhas viaturas".');
    }
  }
  if (online && driver.license!.expiresAt.getTime() < Date.now()) {
    throw new HttpError(403, 'A sua carta de condução caducou. Actualize-a no menu.');
  }
  driver.isOnline = online;
  if (loc) {
    driver.location = { type: 'Point', coordinates: [loc.lng, loc.lat] };
    driver.locationUpdatedAt = new Date();
  }
  await driver.save();
}

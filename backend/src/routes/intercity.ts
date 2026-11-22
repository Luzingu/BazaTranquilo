import { Router } from 'express';
import type { Request } from 'express';
import { z } from 'zod';
import { HttpError, parse, requireAuth, requireDriver, requirePassenger } from '../http.js';
import { DriverModel, verification } from '../models/accounts.js';
import { IntercityRouteModel, IntercityTripModel } from '../models/intercity.js';
import { CommissionEntryModel } from '../models/misc.js';
import { emitToUser } from '../services/realtime.js';
import { settings } from '../services/settings.js';

// Táxi intermunicipal: ver models/intercity.ts.

export const intercityRouter = Router();
intercityRouter.use(requireAuth);

const objectId = z.string().regex(/^[0-9a-f]{24}$/i, 'identificador inválido');
const kz = (v: number) => `${Math.round(v).toLocaleString('pt-PT').replace(/ |\./g, ' ')} Kz`;
const when = (d: Date) =>
  d.toLocaleString('pt-PT', { timeZone: 'Africa/Luanda', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });

/** Viagens que ainda se podem publicar: até 30 dias à frente. */
const MAX_DAYS_AHEAD = 30;
const MAX_SEATS = 60;
/** Viagens em aberto por motorista, para não encher a lista. */
const MAX_OPEN_TRIPS = 6;

type Trip = InstanceType<typeof IntercityTripModel>;

/** Limites de preço que o motorista pode pedir numa rota. */
export const priceRange = (r: { price: number; maxPrice?: number | null }) => ({
  min: Math.max(100, Math.round(r.price / 2)),
  max: Math.max(r.price, r.maxPrice ?? r.price),
});

const routeOut = (r: InstanceType<typeof IntercityRouteModel>) => ({
  id: r.id as string,
  from: r.from,
  to: r.to,
  price: r.price,
  ...priceRange(r),
  distanceKm: r.distanceKm ?? null,
});

/**
 * A viagem como cada pessoa a vê: o motorista vê todas as reservas (com os
 * contactos); o passageiro vê só a sua, e o telefone do motorista só depois de
 * a reserva estar confirmada.
 */
function tripOut(t: Trip, req: Request) {
  const mine = req.role === 'driver' && String(t.driver) === req.account.id;
  const myBooking =
    req.role === 'passenger'
      ? [...t.bookings].reverse().find((b) => String(b.passenger) === req.account.id && b.status !== 'cancelled')
      : undefined;
  const booking = (b: Trip['bookings'][number]) => ({
    id: String(b._id),
    name: b.name ?? 'Passageiro',
    phone: b.phone ?? null,
    seats: b.seats,
    note: b.note,
    status: b.status,
    createdAt: (b as unknown as { createdAt?: Date }).createdAt ?? null,
  });
  return {
    id: t.id as string,
    from: t.from,
    to: t.to,
    departAt: t.departAt,
    seats: t.seats,
    seatsLeft: Math.max(0, t.seats - t.seatsTaken),
    price: t.price,
    meetingPoint: t.meetingPoint,
    note: t.note,
    status: t.status,
    driver: {
      name: t.driverName ?? 'Motorista',
      phone: mine || myBooking?.status === 'confirmed' ? (t.driverPhone ?? null) : null,
    },
    vehicle: t.vehicle ?? null,
    mine,
    ...(mine
      ? {
          bookings: t.bookings.filter((b) => b.status !== 'cancelled').map(booking),
          pending: t.bookings.filter((b) => b.status === 'pending').length,
          commission: t.commission,
        }
      : {}),
    ...(myBooking ? { myBooking: booking(myBooking) } : {}),
  };
}

const notify = (userId: string, title: string, body: string, tripId: string) =>
  emitToUser(userId, 'intercity:update', { title, body, tripId });

// ── Rotas (definidas no painel) ─────────────────────────────────────────────
intercityRouter.get('/routes', async (_req, res) => {
  const routes = await IntercityRouteModel.find({ active: true }).sort({ from: 1, to: 1 });
  res.json({
    routes: routes.map(routeOut),
    /** Municípios servidos, para os filtros do app. */
    places: [...new Set(routes.flatMap((r) => [r.from, r.to]))].sort((a, b) => a.localeCompare(b, 'pt')),
    commissionRate: settings.intercityCommissionRate,
  });
});

// ── Procurar viagens (passageiro e motorista) ───────────────────────────────
intercityRouter.get('/trips', async (req, res) => {
  const q = parse(
    z.object({ from: z.string().trim().max(60).optional(), to: z.string().trim().max(60).optional() }),
    req.query,
  );
  const trips = await IntercityTripModel.find({
    status: 'open',
    departAt: { $gt: new Date() },
    ...(q.from ? { from: q.from } : {}),
    ...(q.to ? { to: q.to } : {}),
  })
    .sort({ departAt: 1 })
    .limit(80);
  res.json({ trips: trips.map((t) => tripOut(t, req)) });
});

/** As minhas viagens: as que publiquei (motorista) ou onde tenho reserva (passageiro). */
intercityRouter.get('/trips/mine', async (req, res) => {
  const since = new Date(Date.now() - 14 * 24 * 3600_000);
  const filter =
    req.role === 'driver'
      ? { driver: req.account._id }
      : { bookings: { $elemMatch: { passenger: req.account._id, status: { $ne: 'cancelled' } } } };
  const trips = await IntercityTripModel.find({ ...filter, departAt: { $gt: since } })
    .sort({ departAt: 1 })
    .limit(60);
  res.json({ trips: trips.map((t) => tripOut(t, req)) });
});

// ── Motorista: publicar e gerir uma viagem ──────────────────────────────────
intercityRouter.post('/trips', requireDriver, async (req, res) => {
  const body = parse(
    z.object({
      routeId: objectId,
      /** Sentido contrário ao da rota (ex.: rota "Mbanza Kongo → Soyo", viagem "Soyo → Mbanza Kongo"). */
      reverse: z.boolean().default(false),
      departAt: z.coerce.date(),
      seats: z.coerce.number().int().min(1).max(MAX_SEATS),
      price: z.coerce.number().int().positive().optional(),
      meetingPoint: z.string().trim().max(120).default(''),
      note: z.string().trim().max(300).default(''),
    }),
    req.body,
  );
  const driver = req.driver;
  if (driver.blocked) throw new HttpError(403, 'A sua conta está suspensa.');
  if (verification(driver) !== 'approved' || !driver.vehicle) {
    throw new HttpError(403, 'Só motoristas com os documentos aprovados e uma viatura activa podem publicar viagens.');
  }
  const route = await IntercityRouteModel.findOne({ _id: body.routeId, active: true });
  if (!route) throw new HttpError(404, 'Essa rota já não está disponível.');
  const now = Date.now();
  if (body.departAt.getTime() < now + 15 * 60_000) throw new HttpError(400, 'A partida tem de ser daqui a pelo menos 15 minutos.');
  if (body.departAt.getTime() > now + MAX_DAYS_AHEAD * 24 * 3600_000) {
    throw new HttpError(400, `Só se publicam viagens até ${MAX_DAYS_AHEAD} dias à frente.`);
  }
  const range = priceRange(route);
  const price = body.price ?? route.price;
  if (price < range.min || price > range.max) {
    throw new HttpError(
      400,
      range.min === range.max
        ? `O preço desta rota é ${kz(route.price)} por passageiro.`
        : `Nesta rota o preço por passageiro vai de ${kz(range.min)} a ${kz(range.max)}.`,
    );
  }
  if ((await IntercityTripModel.countDocuments({ driver: driver._id, status: 'open', departAt: { $gt: new Date() } })) >= MAX_OPEN_TRIPS) {
    throw new HttpError(409, `Já tem ${MAX_OPEN_TRIPS} viagens publicadas. Conclua ou cancele uma antes de publicar outra.`);
  }
  const v = driver.vehicle;
  const trip = await IntercityTripModel.create({
    driver: driver._id,
    driverName: driver.name,
    driverPhone: driver.phone,
    vehicle: { label: `${v.make} ${v.carModel}`, plate: v.plate, color: v.color, category: v.category },
    route: route._id,
    from: body.reverse ? route.to : route.from,
    to: body.reverse ? route.from : route.to,
    departAt: body.departAt,
    seats: body.seats,
    price,
    meetingPoint: body.meetingPoint,
    note: body.note,
  });
  res.status(201).json({ trip: tripOut(trip, req) });
});

async function myTrip(req: Request) {
  const trip = await IntercityTripModel.findOne({ _id: parse(objectId, req.params.id), driver: req.account._id });
  if (!trip) throw new HttpError(404, 'Viagem não encontrada.');
  return trip;
}

/** Acertar lugares (ex.: vendeu um lugar fora do app), ponto de encontro e nota. */
intercityRouter.patch('/trips/:id', requireDriver, async (req, res) => {
  const body = parse(
    z.object({
      seats: z.coerce.number().int().min(1).max(MAX_SEATS).optional(),
      meetingPoint: z.string().trim().max(120).optional(),
      note: z.string().trim().max(300).optional(),
    }),
    req.body,
  );
  const trip = await myTrip(req);
  if (trip.status !== 'open') throw new HttpError(409, 'Esta viagem já não pode ser alterada.');
  if (body.seats !== undefined) {
    if (body.seats < trip.seatsTaken) {
      throw new HttpError(409, `Já confirmou ${trip.seatsTaken} lugares. Não pode ficar com menos do que isso.`);
    }
    trip.seats = body.seats;
  }
  if (body.meetingPoint !== undefined) trip.meetingPoint = body.meetingPoint;
  if (body.note !== undefined) trip.note = body.note;
  await trip.save();
  res.json({ trip: tripOut(trip, req) });
});

/** Partir, concluir ou cancelar a viagem. */
intercityRouter.post('/trips/:id/status', requireDriver, async (req, res) => {
  const { status } = parse(z.object({ status: z.enum(['departed', 'completed', 'cancelled']) }), req.body);
  const trip = await myTrip(req);
  const allowed: Record<string, string[]> = { open: ['departed', 'cancelled'], departed: ['completed'] };
  if (!allowed[trip.status]?.includes(status)) throw new HttpError(409, 'Esse passo não é possível no estado actual da viagem.');
  const label = `${trip.from} → ${trip.to}`;
  const confirmed = trip.bookings.filter((b) => b.status === 'confirmed');
  if (status === 'cancelled') {
    for (const b of trip.bookings) {
      if (b.status === 'pending' || b.status === 'confirmed') {
        notify(String(b.passenger), 'Viagem cancelada', `O motorista cancelou a viagem ${label} de ${when(trip.departAt)}.`, trip.id);
      }
    }
  }
  if (status === 'departed') {
    // Quem ficou por confirmar já não viaja.
    for (const b of trip.bookings) {
      if (b.status === 'pending') {
        b.status = 'rejected';
        notify(String(b.passenger), 'Reserva não confirmada', `A viagem ${label} partiu sem confirmar a sua reserva.`, trip.id);
      }
    }
    for (const b of confirmed) notify(String(b.passenger), 'Boa viagem!', `A viagem ${label} começou.`, trip.id);
  }
  if (status === 'completed') {
    // Comissão do Bazá sobre os lugares confirmados no app.
    const seats = confirmed.reduce((n, b) => n + b.seats, 0);
    trip.commissionRate = settings.intercityCommissionRate;
    trip.commission = Math.round(seats * trip.price * trip.commissionRate);
    if (trip.commission > 0) {
      const driver = await DriverModel.findByIdAndUpdate(
        trip.driver,
        { $inc: { commissionDue: trip.commission } },
        { returnDocument: 'after' },
      ).select('commissionDue');
      await CommissionEntryModel.create({
        driver: trip.driver,
        type: 'charge',
        amount: trip.commission,
        note: `Viagem ${label} · ${seats} ${seats === 1 ? 'passageiro' : 'passageiros'}`,
        dueAfter: driver?.commissionDue ?? trip.commission,
      });
    }
    for (const b of confirmed) {
      notify(String(b.passenger), 'Chegou ao destino', `Obrigado por viajar com o Bazá até ${trip.to}.`, trip.id);
    }
  }
  trip.status = status;
  await trip.save();
  res.json({ trip: tripOut(trip, req) });
});

/** Confirmar ou recusar uma reserva. Só a confirmação ocupa lugares. */
intercityRouter.post('/trips/:id/bookings/:booking', requireDriver, async (req, res) => {
  const { action } = parse(z.object({ action: z.enum(['confirm', 'reject']) }), req.body);
  const bookingId = parse(objectId, req.params.booking);
  const trip = await myTrip(req);
  if (trip.status !== 'open') throw new HttpError(409, 'Esta viagem já não aceita alterações às reservas.');
  const booking = trip.bookings.id(bookingId);
  if (!booking || booking.status === 'cancelled') throw new HttpError(404, 'Reserva não encontrada.');
  const label = `${trip.from} → ${trip.to}`;
  if (action === 'confirm') {
    if (booking.status === 'confirmed') throw new HttpError(409, 'Esta reserva já está confirmada.');
    // Actualização atómica: duas confirmações ao mesmo tempo não passam dos lugares.
    const updated = await IntercityTripModel.findOneAndUpdate(
      {
        _id: trip._id,
        status: 'open',
        bookings: { $elemMatch: { _id: booking._id, status: { $in: ['pending', 'rejected'] } } },
        $expr: { $lte: [{ $add: ['$seatsTaken', booking.seats] }, '$seats'] },
      },
      { $inc: { seatsTaken: booking.seats }, $set: { 'bookings.$.status': 'confirmed' } },
      { returnDocument: 'after' },
    );
    if (!updated) {
      const left = trip.seats - trip.seatsTaken;
      throw new HttpError(409, left > 0 ? `Só restam ${left} lugares e esta reserva pede ${booking.seats}.` : 'Já não há lugares livres.');
    }
    notify(
      String(booking.passenger),
      'Reserva confirmada',
      `${label}, ${when(trip.departAt)}. ${booking.seats} ${booking.seats === 1 ? 'lugar' : 'lugares'} · ${kz(booking.seats * trip.price)} a pagar ao motorista.`,
      trip.id,
    );
    res.json({ trip: tripOut(updated, req) });
    return;
  }
  // Recusar: se já estava confirmada, os lugares voltam a ficar livres.
  const was = booking.status;
  const updated = await IntercityTripModel.findOneAndUpdate(
    { _id: trip._id, bookings: { $elemMatch: { _id: booking._id, status: was } } },
    { $set: { 'bookings.$.status': 'rejected' }, ...(was === 'confirmed' ? { $inc: { seatsTaken: -booking.seats } } : {}) },
    { returnDocument: 'after' },
  );
  if (!updated) throw new HttpError(409, 'A reserva mudou entretanto. Actualize e tente de novo.');
  notify(String(booking.passenger), 'Reserva não aceite', `O motorista não pôde aceitar a sua reserva para ${label}.`, trip.id);
  res.json({ trip: tripOut(updated, req) });
});

// ── Passageiro: reservar e desistir ─────────────────────────────────────────
intercityRouter.post('/trips/:id/bookings', requirePassenger, async (req, res) => {
  const body = parse(
    z.object({ seats: z.coerce.number().int().min(1).max(MAX_SEATS), note: z.string().trim().max(200).default('') }),
    req.body,
  );
  const trip = await IntercityTripModel.findById(parse(objectId, req.params.id));
  if (!trip || trip.status !== 'open' || trip.departAt.getTime() < Date.now()) {
    throw new HttpError(409, 'Esta viagem já não aceita reservas.');
  }
  if (trip.bookings.some((b) => String(b.passenger) === req.account.id && (b.status === 'pending' || b.status === 'confirmed'))) {
    throw new HttpError(409, 'Já tem uma reserva nesta viagem.');
  }
  const left = trip.seats - trip.seatsTaken;
  if (body.seats > left) {
    throw new HttpError(409, left > 0 ? `Só ${left === 1 ? 'resta 1 lugar' : `restam ${left} lugares`} nesta viagem.` : 'Esta viagem já está cheia.');
  }
  trip.bookings.push({
    passenger: req.account._id,
    name: req.account.name || 'Passageiro',
    phone: req.account.phone,
    seats: body.seats,
    note: body.note,
  });
  await trip.save();
  notify(
    String(trip.driver),
    'Nova reserva',
    `${req.account.name || 'Um passageiro'} pede ${body.seats} ${body.seats === 1 ? 'lugar' : 'lugares'} na viagem ${trip.from} → ${trip.to} de ${when(trip.departAt)}.`,
    trip.id,
  );
  res.status(201).json({ trip: tripOut(trip, req) });
});

/** O passageiro desiste da sua reserva; se estava confirmada, o lugar fica livre. */
intercityRouter.post('/trips/:id/bookings/mine/cancel', requirePassenger, async (req, res) => {
  const trip = await IntercityTripModel.findById(parse(objectId, req.params.id));
  const booking = trip?.bookings.find((b) => String(b.passenger) === req.account.id && (b.status === 'pending' || b.status === 'confirmed'));
  if (!trip || !booking) throw new HttpError(404, 'Não tem reserva nesta viagem.');
  if (trip.status !== 'open') throw new HttpError(409, 'A viagem já partiu.');
  const was = booking.status;
  const updated = await IntercityTripModel.findOneAndUpdate(
    { _id: trip._id, bookings: { $elemMatch: { _id: booking._id, status: was } } },
    { $set: { 'bookings.$.status': 'cancelled' }, ...(was === 'confirmed' ? { $inc: { seatsTaken: -booking.seats } } : {}) },
    { returnDocument: 'after' },
  );
  if (!updated) throw new HttpError(409, 'A reserva mudou entretanto. Actualize e tente de novo.');
  notify(
    String(trip.driver),
    'Reserva cancelada',
    `${booking.name ?? 'Um passageiro'} desistiu de ${booking.seats} ${booking.seats === 1 ? 'lugar' : 'lugares'} na viagem ${trip.from} → ${trip.to}.`,
    trip.id,
  );
  res.json({ trip: tripOut(updated, req) });
});

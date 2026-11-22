import { Schema, model } from 'mongoose';

// ── Táxi intermunicipal ─────────────────────────────────────────────────────
// A equipa define no painel as rotas entre municípios e o preço por passageiro.
// O motorista publica uma viagem numa rota (dia, hora, lugares, preço) e os
// passageiros reservam lugares; cada reserva que o motorista confirma reduz os
// lugares livres.

/** Rota entre dois municípios; serve nos dois sentidos. */
const routeSchema = new Schema(
  {
    from: { type: String, required: true, trim: true },
    to: { type: String, required: true, trim: true },
    /** Preço de referência por passageiro (Kz). */
    price: { type: Number, required: true },
    /** Máximo que o motorista pode pedir; sem valor, o preço é fixo. */
    maxPrice: Number,
    /** Distância aproximada, só informativa. */
    distanceKm: Number,
    active: { type: Boolean, default: true, index: true },
  },
  { timestamps: true },
);
export const IntercityRouteModel = model('IntercityRoute', routeSchema, 'rotas_intermunicipais');

export const BOOKING_STATUSES = ['pending', 'confirmed', 'rejected', 'cancelled'] as const;
const bookingSchema = new Schema(
  {
    passenger: { type: Schema.Types.ObjectId, ref: 'Passenger', required: true },
    name: String,
    phone: String,
    seats: { type: Number, required: true, min: 1 },
    /** Ex.: "levo duas malas grandes". */
    note: { type: String, default: '' },
    status: { type: String, enum: BOOKING_STATUSES, default: 'pending' },
  },
  { timestamps: true },
);

export const TRIP_STATUSES = ['open', 'departed', 'completed', 'cancelled'] as const;
const tripSchema = new Schema(
  {
    driver: { type: Schema.Types.ObjectId, ref: 'Driver', required: true, index: true },
    driverName: String,
    driverPhone: String,
    /** Viatura no momento da publicação. */
    vehicle: { label: String, plate: String, color: String, category: String },
    route: { type: Schema.Types.ObjectId, ref: 'IntercityRoute', required: true },
    /** Sentido escolhido pelo motorista. */
    from: { type: String, required: true, index: true },
    to: { type: String, required: true, index: true },
    departAt: { type: Date, required: true, index: true },
    /** Lugares que o motorista quer preencher pelo app. */
    seats: { type: Number, required: true, min: 1 },
    /** Lugares já confirmados (soma das reservas confirmadas). */
    seatsTaken: { type: Number, default: 0 },
    /** Preço por passageiro (Kz). */
    price: { type: Number, required: true },
    /** Onde os passageiros se encontram com o motorista. */
    meetingPoint: { type: String, default: '' },
    /** Ex.: "Mala grande: 1 000 Kz. Carga acima de 20 kg combina-se." */
    note: { type: String, default: '' },
    status: { type: String, enum: TRIP_STATUSES, default: 'open', index: true },
    bookings: [bookingSchema],
    /** Comissão do Bazá, calculada ao concluir a viagem. */
    commission: { type: Number, default: 0 },
    commissionRate: { type: Number, default: 0 },
  },
  { timestamps: true },
);
export const IntercityTripModel = model('IntercityTrip', tripSchema, 'viagens_intermunicipais');

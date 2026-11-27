import { SERVICE_KEYS } from '../config.js';
import { Schema, model, type InferSchemaType, type HydratedDocument } from 'mongoose';

const placeSchema = new Schema(
  {
    address: { type: String, required: true },
    lat: { type: Number, required: true },
    lng: { type: Number, required: true },
  },
  { _id: false },
);

export const RIDE_STATUSES = [
  'searching', // à procura de motorista
  'accepted', // motorista a caminho
  'arrived', // motorista no ponto de recolha
  'in_progress', // viagem a decorrer
  'completed',
  'cancelled',
  'no_drivers',
] as const;
export type RideStatus = (typeof RIDE_STATUSES)[number];
export const ACTIVE_STATUSES: RideStatus[] = ['searching', 'accepted', 'arrived', 'in_progress'];

const rideSchema = new Schema(
  {
    passenger: { type: Schema.Types.ObjectId, ref: 'Passenger', required: true, index: true },
    driver: { type: Schema.Types.ObjectId, ref: 'Driver', index: true },
    /** Motorista preferido que o passageiro escolheu chamar. */
    preferredDriver: { type: Schema.Types.ObjectId, ref: 'Driver' },
    /** Enquanto definido, só este motorista recebe e pode aceitar o pedido. */
    exclusiveFor: { type: Schema.Types.ObjectId, ref: 'Driver' },
    pickup: { type: placeSchema, required: true },
    dropoff: { type: placeSchema, required: true },
    /** Paragens intermédias, pela ordem em que se fazem. */
    stops: [placeSchema],
    category: { type: String, enum: SERVICE_KEYS, required: true },
    /** Sem destino definido (serviços de preço combinado): `dropoff` repete o ponto de recolha. */
    noDestination: { type: Boolean, default: false },
    /** Serviços de carga: o que se transporta e quantos ajudantes foram pedidos. */
    cargoNote: String,
    helpers: { type: Number, default: 0 },
    paymentMethod: { type: String, enum: ['cash', 'wallet', 'multicaixa', 'corporate'], required: true },
    /** Empresa cliente que paga a corrida (pagamento "corporate"). */
    company: { type: Schema.Types.ObjectId, ref: 'Company', index: true },
    companyName: String,
    status: { type: String, enum: RIDE_STATUSES, default: 'searching', index: true },
    distanceM: { type: Number, required: true },
    durationS: { type: Number, required: true },
    /** Polyline codificada (precisão 5) da rota recolha → destino. */
    routeGeometry: String,
    /** Preço em vigor: o proposto pelo passageiro ou, depois do acordo, o combinado. */
    fare: { type: Number, required: true },
    /** Preço calculado pela tarifa, que serve de referência à negociação. */
    suggestedFare: Number,
    /** Taxa por procura aplicada ao preço da tarifa (×1,2 …) e o motivo mostrado ao passageiro. */
    surgeMultiplier: Number,
    surgeLabel: String,
    /** Contrapropostas de preço dos motoristas, enquanto a corrida procura motorista. */
    bids: [
      new Schema(
        {
          driver: { type: Schema.Types.ObjectId, ref: 'Driver', required: true },
          amount: { type: Number, required: true },
          createdAt: { type: Date, default: Date.now },
        },
        { _id: false },
      ),
    ],
    /** Até quando se procura motorista (prolonga-se enquanto houver negociação). */
    searchUntil: Date,
    commission: { type: Number, default: 0 },
    /** Corrida de tarifa sem taxa por ser uma das viagens grátis do motorista. */
    freeRide: { type: Boolean, default: false },
    paymentStatus: { type: String, enum: ['pending', 'paid', 'failed'], default: 'pending' },
    /** Motoristas que recusaram a oferta. */
    declinedBy: [{ type: Schema.Types.ObjectId, ref: 'Driver' }],
    /** Motoristas a quem a oferta foi enviada. */
    offeredTo: [{ type: Schema.Types.ObjectId, ref: 'Driver' }],
    /** Segredo do link público de acompanhamento, criado quando a viagem é partilhada. */
    shareToken: { type: String, index: { unique: true, sparse: true } },
    cancelledBy: { type: String, enum: ['passenger', 'driver'] },
    /** Cancelada tarde (depois do período sem penalização): conta para a suspensão. */
    lateCancel: { type: Boolean, default: false },
    /** Motivo escolhido por quem cancelou (lista do app) e comentário opcional. */
    cancelReason: { type: String, maxlength: 40 },
    cancelComment: { type: String, maxlength: 300 },
    passengerRating: Number, // nota dada ao passageiro
    driverRating: Number, // nota dada ao motorista
    acceptedAt: Date,
    arrivedAt: Date,
    startedAt: Date,
    completedAt: Date,
    cancelledAt: Date,
  },
  { timestamps: true },
);

export type Ride = InferSchemaType<typeof rideSchema>;
export type RideDoc = HydratedDocument<Ride>;
export const RideModel = model('Ride', rideSchema, 'corridas');

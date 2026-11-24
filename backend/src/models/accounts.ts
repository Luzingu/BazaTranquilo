import { monthlyFee, subscriptionState } from '../services/settings.js';
import { MAX_VEHICLES, SERVICE_KEYS, config, type RideCategory } from '../config.js';
import { HttpError } from '../http.js';
import { Schema, model, type InferSchemaType, type HydratedDocument, type Types } from 'mongoose';

/**
 * Entra-se só com o telefone (código SMS); o email é apenas um contacto opcional.
 * Passageiros e motoristas vivem em colecções separadas (`passageiros` e
 * `motoristas`; os nomes das colecções na base de dados são em português), cada uma com
 * carteira e avaliação próprias. Um telefone só pode ter um tipo de conta (ver otherRoleWith).
 */
export type Role = 'passenger' | 'driver';

const commonFields = () => ({
  name: { type: String, default: '' },
  phone: { type: String, unique: true, sparse: true },
  email: { type: String, unique: true, sparse: true, lowercase: true, trim: true },
  passwordHash: { type: String, select: false },
  /**
   * O número foi confirmado por SMS. Só fica false em contas criadas quando o
   * envio do SMS falhou; as restantes (e as antigas, sem o campo) contam como
   * confirmadas. O app pede a confirmação mais tarde (rotas /me/phone-confirmation).
   */
  phoneVerified: { type: Boolean, default: true },
  /** Sobe quando o dono do número recupera a conta: as sessões com o valor antigo deixam de valer. */
  sessionVersion: { type: Number, default: 0 },
  /**
   * Conta desactivada (não entra). Hoje só acontece a passageiros cujo número
   * também era de um motorista, quando a regra "um número, um só tipo de conta"
   * entrou (2026-11-24). O telefone passa para `formerPhone`, para o número
   * ficar livre; as corridas e o resto dos dados ficam.
   */
  deactivatedAt: Date,
  deactivatedReason: String,
  formerPhone: String,
  /** Id (GridFS) da foto de perfil. */
  photo: String,
  /** Pessoa de confiança a quem enviar a localização numa emergência. */
  /** Suspensão temporária por cancelamentos tardios repetidos. */
  suspendedUntil: Date,
  /** Utilizador estrela: escolhido pela equipa para registar locais no mapa a partir do app. */
  star: { type: Boolean, default: false },
  /** Dispositivos a avisar por notificação push (tokens do Firebase). */
  pushTokens: { type: [String], default: [] },
  emergencyContact: { type: new Schema({ name: String, phone: String }, { _id: false }), default: undefined },
  walletBalance: { type: Number, default: 0 },
  ratingSum: { type: Number, default: 0 },
  ratingCount: { type: Number, default: 0 },
});

const passengerSchema = new Schema(
  {
    ...commonFields(),
    favoriteDrivers: [{ type: Schema.Types.ObjectId, ref: 'Driver' }],
    /** Locais guardados (Casa, Trabalho, …) para escolher como recolha ou destino. */
    savedPlaces: [
      new Schema({
        kind: { type: String, enum: ['home', 'work', 'other'], default: 'other' },
        label: { type: String, required: true },
        address: { type: String, required: true },
        lat: { type: Number, required: true },
        lng: { type: Number, required: true },
      }),
    ],
  },
  { timestamps: true },
);

const vehicleFields = () => ({
  make: { type: String, required: true },
  carModel: { type: String, required: true },
  color: { type: String, required: true },
  plate: { type: String, required: true },
  category: { type: String, enum: SERVICE_KEYS, default: 'economy' },
  /** Tem ar condicionado a funcionar. */
  hasAC: { type: Boolean, default: false },
});

/** Estado da revisão de um documento enviado pelo motorista. */
const reviewFields = () => ({
  status: { type: String, enum: ['pending', 'approved', 'rejected'], default: 'pending' },
  /** Motivo indicado por quem rejeitou. */
  reviewNote: String,
});
export type ReviewStatus = 'pending' | 'approved' | 'rejected';

/** Uma viatura da garagem do motorista, com a foto do livrete. */
const garageVehicleSchema = new Schema({
  ...vehicleFields(),
  /** Ids (GridFS) das fotos dos documentos da viatura: livrete, título de propriedade e seguro. */
  registrationPhoto: String,
  ownershipPhoto: String,
  insurancePhoto: String,
  /** Validade do seguro: com ele caducado a viatura não pode circular na plataforma. */
  insuranceExpiresAt: Date,
  /** Mensalidade paga até esta data (viaturas de preço combinado). */
  paidUntil: Date,
  ...reviewFields(),
});

/** Cópia da viatura activa, para as pesquisas de motoristas por categoria. */
const activeVehicleSchema = new Schema(
  {
    ...vehicleFields(),
    id: String,
    /** Categorias de pedidos que esta viatura recebe (ver `servedCategories`). */
    serves: [String],
  },
  { _id: false },
);

/** Carta de condução. */
const licenseSchema = new Schema(
  {
    number: { type: String, required: true },
    category: { type: String, required: true },
    expiresAt: { type: Date, required: true },
    /** Ids (GridFS) das fotos da frente e do verso. */
    frontPhoto: String,
    backPhoto: String,
    ...reviewFields(),
  },
  { _id: false },
);

const driverSchema = new Schema(
  {
    ...commonFields(),
    license: { type: licenseSchema, default: undefined },
    /** Todas as viaturas registadas; o motorista conduz uma de cada vez. */
    vehicles: [garageVehicleSchema],
    /** A viatura activa (cópia de uma das `vehicles`). */
    vehicle: { type: activeVehicleSchema, default: undefined },
    isOnline: { type: Boolean, default: false },
    /** Frota a que o motorista pertence (e o nome dela, para mostrar no app). */
    fleet: { type: Schema.Types.ObjectId, ref: 'Fleet', index: true },
    fleetName: String,
    /** Conta suspensa por um administrador: não pode ficar online. */
    blocked: { type: Boolean, default: false },
    /** Porque foi suspensa (o motorista vê este motivo), quando e por quem. */
    blockedReason: String,
    blockedAt: Date,
    blockedBy: String,
    /** Comissões de corridas em dinheiro ainda por pagar ao Bazá (Kz). */
    commissionDue: { type: Number, default: 0 },
    location: {
      type: { type: String, enum: ['Point'] },
      coordinates: { type: [Number] }, // [lng, lat]
    },
    locationUpdatedAt: Date,
  },
  { timestamps: true },
);
driverSchema.index({ location: '2dsphere' });

export type PassengerDoc = HydratedDocument<InferSchemaType<typeof passengerSchema>>;
export type DriverDoc = HydratedDocument<InferSchemaType<typeof driverSchema>>;
export type AccountDoc = PassengerDoc | DriverDoc;

export const PassengerModel = model('Passenger', passengerSchema, 'passageiros');
export const DriverModel = model('Driver', driverSchema, 'motoristas');

type Id = Types.ObjectId | string;

// As contas são sempre carregadas com `passwordHash` para se saber se o
// utilizador já definiu palavra-passe; o valor nunca sai em `publicAccount`.

export async function findAccountById(role: Role, id: Id): Promise<AccountDoc | null> {
  const account =
    role === 'driver'
      ? await DriverModel.findById(id).select('+passwordHash')
      : await PassengerModel.findById(id).select('+passwordHash');
  return account as AccountDoc | null;
}

export async function findAccount(
  role: Role,
  filter: { phone: string } | { email: string },
): Promise<AccountDoc | null> {
  const account =
    role === 'driver'
      ? await DriverModel.findOne(filter).select('+passwordHash')
      : await PassengerModel.findOne(filter).select('+passwordHash');
  return account as AccountDoc | null;
}

const ROLE_LABEL: Record<Role, string> = { passenger: 'passageiro', driver: 'motorista' };

/**
 * Um número, um só tipo de conta: o mesmo telefone não pode ser de um
 * passageiro e de um motorista ao mesmo tempo. Devolve o outro tipo se o
 * número já lá estiver.
 */
export async function otherRoleWith(role: Role, phone: string): Promise<Role | null> {
  const other: Role = role === 'driver' ? 'passenger' : 'driver';
  const exists = other === 'driver' ? await DriverModel.exists({ phone }) : await PassengerModel.exists({ phone });
  return exists ? other : null;
}

/** Recusa o número se já tiver conta do outro tipo (`otherRole` vai na resposta, para o app oferecer a troca). */
export async function assertPhoneFreeForRole(role: Role, phone: string, message?: string) {
  const other = await otherRoleWith(role, phone);
  if (other) {
    throw new HttpError(
      409,
      message ?? `Este número já está registado como ${ROLE_LABEL[other]}. Cada número só pode ter um tipo de conta.`,
      { otherRole: other },
    );
  }
}

export function createAccount(
  role: Role,
  data: { name?: string; phone?: string; email?: string; passwordHash?: string; phoneVerified?: boolean },
): Promise<AccountDoc> {
  return role === 'driver' ? DriverModel.create(data) : PassengerModel.create(data);
}

/** Soma `amount` ao saldo; com `minBalance`, só se o saldo actual o permitir. */
export function incWallet(role: Role, id: Id, amount: number, minBalance?: number): Promise<AccountDoc | null> {
  const filter = { _id: id, ...(minBalance === undefined ? {} : { walletBalance: { $gte: minBalance } }) };
  const update = { $inc: { walletBalance: amount } };
  const opts = { returnDocument: 'after' } as const;
  return role === 'driver'
    ? DriverModel.findOneAndUpdate(filter, update, opts)
    : PassengerModel.findOneAndUpdate(filter, update, opts);
}

const photoUrl = (a: { photo?: string | null }) => (a.photo ? `/uploads/${a.photo}` : null);

const rating = (a: { ratingSum: number; ratingCount: number }) =>
  a.ratingCount ? Math.round((a.ratingSum / a.ratingCount) * 10) / 10 : null;

/** Os documentos de viatura que o motorista tem de enviar, e o campo onde ficam. */
export const VEHICLE_DOCS = {
  registration: 'registrationPhoto',
  ownership: 'ownershipPhoto',
  insurance: 'insurancePhoto',
} as const;
export type VehicleDoc = keyof typeof VEHICLE_DOCS;

type GarageVehicle = NonNullable<ReturnType<DriverDoc['vehicles']['id']>>;

/** A viatura tem as três fotos (livrete, título, seguro) e a validade do seguro. */
export const vehicleDocsComplete = (v: GarageVehicle | null | undefined) =>
  !!v && !!v.registrationPhoto && !!v.ownershipPhoto && !!v.insurancePhoto && !!v.insuranceExpiresAt;

const activeGarageVehicle = (d: DriverDoc) => (d.vehicle?.id ? d.vehicles.id(d.vehicle.id) : null);

/**
 * O registo está completo quando o motorista tem foto de perfil, enviou os
 * dados e as fotos da carta (frente e verso) e a viatura activa tem os seus
 * documentos (livrete, título de propriedade e seguro com validade).
 */
export const driverIsComplete = (d: DriverDoc) =>
  !!d.photo && !!d.license?.frontPhoto && !!d.license.backPhoto && vehicleDocsComplete(activeGarageVehicle(d));

/**
 * Situação dos documentos: "incomplete" (falta enviar algo), "pending" (em
 * análise), "rejected" ou "approved" (pode conduzir).
 */
export function verification(d: DriverDoc): 'incomplete' | ReviewStatus {
  if (!driverIsComplete(d)) return 'incomplete';
  const statuses = [d.license!.status, activeGarageVehicle(d)!.status];
  if (statuses.includes('rejected')) return 'rejected';
  return statuses.includes('pending') ? 'pending' : 'approved';
}

/**
 * Um motorista sem os documentos aprovados não pode estar online. Se ficou
 * marcado como online (por exemplo, registou-se antes de os documentos serem
 * exigidos), passa a offline — e assim pode completar o registo, que só se
 * edita offline. Devolve true se o estado mudou.
 */
export function dropOfflineIfUnverified(d: DriverDoc) {
  if (!d.isOnline || (verification(d) === 'approved' && !d.blocked)) return false;
  d.isOnline = false;
  return true;
}

/** Estado a dar a um documento acabado de enviar ou alterado. */
const freshStatus = (): ReviewStatus => (config.autoApproveDocuments ? 'approved' : 'pending');

/** O que o próprio utilizador vê da sua conta. */
export function publicAccount(role: Role, a: AccountDoc) {
  const base = {
    id: a.id as string,
    role,
    name: a.name,
    phone: a.phone ?? null,
    email: a.email ?? null,
    /** Se já definiu a senha (entrada sem código SMS). */
    hasPassword: Boolean(a.passwordHash),
    /** false: a conta foi criada sem o SMS chegar e o número está por confirmar. */
    phoneVerified: a.phoneVerified !== false,
    photoUrl: photoUrl(a),
    emergencyContact: a.emergencyContact?.phone
      ? { name: a.emergencyContact.name ?? '', phone: a.emergencyContact.phone }
      : null,
    walletBalance: a.walletBalance,
    /** Se a carteira está disponível no app. */
    walletEnabled: config.walletEnabled,
    rating: rating(a),
    /** Suspensão temporária por cancelamentos repetidos (data ISO) ou null. */
    suspendedUntil: a.suspendedUntil && a.suspendedUntil.getTime() > Date.now() ? a.suspendedUntil : null,
    /** Pode registar locais no mapa (utilizador estrela). */
    star: !!a.star,
  };
  if (role !== 'driver') return base;
  const d = a as DriverDoc;
  return {
    ...base,
    vehicle: d.vehicle ?? null,
    vehicles: d.vehicles.map((v) => ({
      id: String(v._id),
      make: v.make,
      carModel: v.carModel,
      color: v.color,
      plate: v.plate,
      category: v.category,
      hasAC: v.hasAC,
      serves: servedCategories(v),
      active: String(v._id) === d.vehicle?.id,
      hasRegistration: !!v.registrationPhoto,
      hasOwnership: !!v.ownershipPhoto,
      hasInsurance: !!v.insurancePhoto,
      insuranceExpiresAt: v.insuranceExpiresAt ?? null,
      paidUntil: v.paidUntil ?? null,
      /** Mensalidade deste tipo de viatura (0 = sem mensalidade) e o seu estado. */
      monthlyFee: monthlyFee(v.category),
      subscription: subscriptionState(v.category, v.paidUntil),
      docsComplete: vehicleDocsComplete(v),
      status: v.status,
      reviewNote: v.reviewNote ?? null,
    })),
    // Os nomes dos ficheiros não saem do servidor; as fotos pedem-se em /documents.
    license: d.license
      ? {
          number: d.license.number,
          category: d.license.category,
          expiresAt: d.license.expiresAt,
          hasFront: !!d.license.frontPhoto,
          hasBack: !!d.license.backPhoto,
          status: d.license.status,
          reviewNote: d.license.reviewNote ?? null,
        }
      : null,
    verification: verification(d),
    blocked: d.blocked,
    fleet: d.fleet ? { id: String(d.fleet), name: d.fleetName ?? '' } : null,
    isOnline: d.isOnline,
  };
}

/** O que a outra parte da corrida pode ver. */
export function passengerParty(p: PassengerDoc) {
  return {
    id: p.id as string,
    name: p.name,
    phone: p.phone ?? null,
    photoUrl: photoUrl(p),
    vehicle: null,
    rating: rating(p),
  };
}
export function driverParty(d: DriverDoc) {
  return {
    id: d.id as string,
    name: d.name,
    phone: d.phone ?? null,
    photoUrl: photoUrl(d),
    vehicle: d.vehicle ?? null,
    rating: rating(d),
  };
}

// ── Garagem do motorista ────────────────────────────────────────────────────
export interface VehicleInput {
  make: string;
  carModel: string;
  color: string;
  plate: string;
  category: RideCategory;
  hasAC?: boolean;
  /** Validade do seguro (obrigatória para a viatura poder ser usada). */
  insuranceExpiresAt?: Date;
}

/** Só os carros fechados têm ar condicionado; nas motos e triciclos não se aplica. */
const AC_CATEGORIES: RideCategory[] = ['economy', 'comfort', 'xl', 'pickup', 'truck'];

/**
 * Pedidos que uma viatura recebe: os da sua categoria. Uma viatura Conforto
 * (com ar condicionado) recebe também pedidos Económico; o contrário não
 * acontece — quem pede Conforto nunca recebe um Económico.
 */
export function servedCategories(v: { category: RideCategory }): RideCategory[] {
  return v.category === 'comfort' ? ['comfort', 'economy'] : [v.category];
}

/** Aplica as regras do ar condicionado aos dados de uma viatura. */
function normalize(input: VehicleInput) {
  if (input.insuranceExpiresAt && input.insuranceExpiresAt.getTime() < Date.now()) {
    throw new GarageError('O seguro da viatura está caducado.');
  }
  if (input.category === 'comfort' && !input.hasAC) {
    throw new GarageError('O serviço Conforto exige ar condicionado. Sem ele, registe a viatura como Económico.');
  }
  return { ...input, hasAC: AC_CATEGORIES.includes(input.category) && !!input.hasAC };
}

/** Contas antigas tinham só `vehicle`: passa-a para a garagem. */
function ensureGarage(d: DriverDoc) {
  if (d.vehicle && !d.vehicles.length) {
    const { make, carModel, color, plate, category } = d.vehicle;
    d.vehicles.push({ make, carModel, color, plate, category, hasAC: false });
    d.vehicle.id = String(d.vehicles[0]!._id);
  }
}

function activate(d: DriverDoc, vehicleId: string) {
  const v = d.vehicles.id(vehicleId);
  if (!v) return false;
  d.vehicle = {
    id: String(v._id),
    make: v.make,
    carModel: v.carModel,
    color: v.color,
    plate: v.plate,
    category: v.category,
    hasAC: v.hasAC,
    serves: servedCategories(v),
  };
  return true;
}

/** Erros da garagem com a mensagem a mostrar ao motorista. */
export class GarageError extends Error {}

export function addVehicle(d: DriverDoc, input: VehicleInput) {
  ensureGarage(d);
  if (d.vehicles.length >= MAX_VEHICLES) throw new GarageError(`Pode registar até ${MAX_VEHICLES} viaturas.`);
  if (d.vehicles.some((v) => v.plate === input.plate)) throw new GarageError('Já registou uma viatura com essa matrícula.');
  d.vehicles.push(normalize(input));
  const added = d.vehicles[d.vehicles.length - 1]!;
  if (!d.vehicle) activate(d, String(added._id)); // a primeira fica logo activa
  return String(added._id);
}

export function updateVehicle(d: DriverDoc, vehicleId: string, input: VehicleInput) {
  ensureGarage(d);
  const v = d.vehicles.id(vehicleId);
  if (!v) throw new GarageError('Viatura não encontrada.');
  if (d.vehicles.some((o) => String(o._id) !== vehicleId && o.plate === input.plate)) {
    throw new GarageError('Já registou uma viatura com essa matrícula.');
  }
  // Outra matrícula é outra viatura: os documentos têm de ser revistos de novo.
  if (v.plate !== input.plate && v.registrationPhoto) {
    v.status = freshStatus();
    v.reviewNote = undefined;
  }
  const next = normalize(input);
  // Editar sem indicar a validade do seguro mantém a que já lá estava.
  if (!next.insuranceExpiresAt) delete next.insuranceExpiresAt;
  v.set(next);
  if (d.vehicle?.id === vehicleId) activate(d, vehicleId);
}

export function activateVehicle(d: DriverDoc, vehicleId: string) {
  ensureGarage(d);
  const v = d.vehicles.id(vehicleId);
  if (!v) throw new GarageError('Viatura não encontrada.');
  if (!vehicleDocsComplete(v)) {
    throw new GarageError('Envie primeiro os documentos desta viatura: livrete, título de propriedade e seguro.');
  }
  if (v.insuranceExpiresAt!.getTime() < Date.now()) throw new GarageError('O seguro desta viatura está caducado.');
  if (v.status !== 'approved') {
    throw new GarageError(
      v.status === 'rejected'
        ? 'Os documentos desta viatura foram rejeitados.'
        : 'Os documentos desta viatura ainda estão em análise.',
    );
  }
  activate(d, vehicleId);
}

export function removeVehicle(d: DriverDoc, vehicleId: string) {
  ensureGarage(d);
  if (d.vehicle?.id === vehicleId) throw new GarageError('Active outra viatura antes de remover esta.');
  const v = d.vehicles.id(vehicleId);
  if (!v) throw new GarageError('Viatura não encontrada.');
  v.deleteOne();
}

/** Guarda a viatura do registo inicial, ou actualiza a activa. */
export function setMainVehicle(d: DriverDoc, input: VehicleInput) {
  ensureGarage(d);
  if (d.vehicle?.id) updateVehicle(d, d.vehicle.id, input);
  else addVehicle(d, input);
}

// ── Documentos do motorista ─────────────────────────────────────────────────

/** Dados da carta. Mudar o número obriga a nova revisão; as fotos mantêm-se. */
export function setLicenseData(d: DriverDoc, input: { number: string; category: string; expiresAt: Date }) {
  if (!d.license) {
    d.license = { ...input, status: freshStatus() };
    return;
  }
  if (d.license.number !== input.number) {
    d.license.status = freshStatus();
    d.license.reviewNote = undefined;
  }
  d.license.number = input.number;
  d.license.category = input.category;
  d.license.expiresAt = input.expiresAt;
}

/** Regista a foto da frente ou do verso da carta; devolve o ficheiro anterior. */
export function setLicensePhoto(d: DriverDoc, side: 'front' | 'back', file: string) {
  if (!d.license) throw new GarageError('Preencha primeiro os dados da carta de condução.');
  const field = side === 'front' ? 'frontPhoto' : 'backPhoto';
  const previous = d.license[field];
  d.license[field] = file;
  d.license.status = freshStatus();
  d.license.reviewNote = undefined;
  return previous ?? null;
}

/** Regista a foto de um documento de uma viatura; devolve o ficheiro anterior. */
export function setVehicleDocument(d: DriverDoc, vehicleId: string, doc: VehicleDoc, file: string) {
  ensureGarage(d);
  const v = d.vehicles.id(vehicleId);
  if (!v) throw new GarageError('Viatura não encontrada.');
  const field = VEHICLE_DOCS[doc];
  const previous = v[field];
  v[field] = file;
  v.status = freshStatus();
  v.reviewNote = undefined;
  return previous ?? null;
}

/** Ficheiro de um documento do motorista, ou null se ainda não foi enviado. */
export function documentFile(
  d: DriverDoc,
  doc: { license: 'front' | 'back' } | { vehicleId: string; doc: VehicleDoc },
) {
  if ('license' in doc) return (doc.license === 'front' ? d.license?.frontPhoto : d.license?.backPhoto) ?? null;
  return d.vehicles.id(doc.vehicleId)?.[VEHICLE_DOCS[doc.doc]] ?? null;
}

/** Decisão de quem revê os documentos (no painel web do administrador). */
export function reviewDocument(
  d: DriverDoc,
  target: 'license' | { vehicleId: string },
  approve: boolean,
  note?: string,
) {
  const item = target === 'license' ? d.license : d.vehicles.id(target.vehicleId);
  if (!item) throw new GarageError('Documento não encontrado.');
  item.status = approve ? 'approved' : 'rejected';
  item.reviewNote = approve ? undefined : note;
}

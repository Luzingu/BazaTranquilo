import { Schema, model, type HydratedDocument, type InferSchemaType } from 'mongoose';

/** Quem gere a plataforma no painel web. */
const adminSchema = new Schema(
  {
    name: { type: String, required: true },
    email: { type: String, required: true, unique: true, lowercase: true, trim: true },
    passwordHash: { type: String, required: true },
    /** Ainda usa a palavra-passe por defeito: o painel pede para a trocar. */
    defaultPassword: { type: Boolean, default: false },
  },
  { timestamps: true },
);
export const AdminModel = model('Admin', adminSchema, 'administradores');

/**
 * Frota: empresa com vários motoristas. Regista-se no painel, fica pendente
 * até um administrador a aprovar e depois gere e acompanha os seus motoristas.
 */
const fleetSchema = new Schema(
  {
    name: { type: String, required: true },
    nif: { type: String, required: true },
    email: { type: String, required: true, unique: true, lowercase: true, trim: true },
    phone: { type: String, required: true },
    /** Só nas frotas antigas: hoje a palavra-passe é de cada utilizador (PanelUserModel). */
    passwordHash: String,
    status: { type: String, enum: ['pending', 'active', 'suspended'], default: 'pending' },
    /** Código que um motorista já registado introduz no app para se juntar à frota. */
    joinCode: { type: String, required: true, unique: true },
  },
  { timestamps: true },
);
export type FleetDoc = HydratedDocument<InferSchemaType<typeof fleetSchema>>;
export const FleetModel = model('Fleet', fleetSchema, 'frotas');

/**
 * Utilizador de uma frota no painel. Cada frota tem os seus utilizadores: os
 * gestores registam e removem os restantes; os operadores só usam o painel. Os
 * utilizadores do próprio Bazá são os administradores (AdminModel); os agentes
 * dos postos policiais usam a aplicação (models/police.ts).
 */
const panelUserSchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    email: { type: String, required: true, unique: true, lowercase: true, trim: true },
    passwordHash: { type: String, required: true },
    kind: { type: String, enum: ['fleet'], default: 'fleet' },
    /** Frota a que pertence. */
    institution: { type: Schema.Types.ObjectId, required: true, index: true },
    role: { type: String, enum: ['manager', 'operator'], default: 'operator' },
    active: { type: Boolean, default: true },
    /** Palavra-passe definida por outra pessoa: o painel pede para a trocar. */
    mustChangePassword: { type: Boolean, default: false },
    lastLoginAt: Date,
  },
  { timestamps: true },
);
export type PanelUserDoc = HydratedDocument<InferSchemaType<typeof panelUserSchema>>;
export const PanelUserModel = model('PanelUser', panelUserSchema, 'utilizadores_painel');

/** Registo de cada acesso de um agente a um alerta: quem, de que posto, o quê e porquê. */
const authorityQuerySchema = new Schema(
  {
    /** O posto policial do agente. */
    authority: { type: Schema.Types.ObjectId, ref: 'Station', required: true, index: true },
    authorityName: String,
    user: { type: Schema.Types.ObjectId, required: true },
    userName: String,
    /** "search" (pesquisa de motorista ou viatura), "rides" (corridas de um motorista) ou "sos". */
    kind: { type: String, required: true },
    /** O que foi procurado ou consultado. */
    target: { type: String, default: '' },
    /** Motivo ou número do processo, indicado por quem consulta. */
    reason: { type: String, default: '' },
    results: { type: Number, default: 0 },
  },
  { timestamps: true },
);
export const AuthorityQueryModel = model('AuthorityQuery', authorityQuerySchema, 'consultas_entidades');

// ── Gestão interna da frota ─────────────────────────────────────────────────
// Dados que só a frota vê: o acerto de contas com cada motorista, as viaturas
// da empresa (com manutenção e despesas) e os turnos.

/**
 * Regra do acerto de contas entre a frota e um motorista:
 * - `percent`: o motorista entrega à frota uma percentagem do que facturou;
 * - `daily`: entrega um valor fixo por cada dia em que trabalhou (a "conta").
 * Conta a partir de `startAt`.
 */
const fleetTermSchema = new Schema(
  {
    fleet: { type: Schema.Types.ObjectId, ref: 'Fleet', required: true, index: true },
    driver: { type: Schema.Types.ObjectId, ref: 'Driver', required: true },
    mode: { type: String, enum: ['percent', 'daily'], required: true },
    /** Percentagem (0–100) ou valor em Kz por dia. */
    value: { type: Number, required: true },
    startAt: { type: Date, required: true },
  },
  { timestamps: true },
);
fleetTermSchema.index({ fleet: 1, driver: 1 }, { unique: true });
export const FleetTermModel = model('FleetTerm', fleetTermSchema, 'frota_acertos');

/** Dinheiro que o motorista entregou à frota. */
const fleetHandoverSchema = new Schema(
  {
    fleet: { type: Schema.Types.ObjectId, ref: 'Fleet', required: true, index: true },
    driver: { type: Schema.Types.ObjectId, ref: 'Driver', required: true, index: true },
    amount: { type: Number, required: true },
    note: { type: String, default: '' },
    by: String,
  },
  { timestamps: true },
);
export const FleetHandoverModel = model('FleetHandover', fleetHandoverSchema, 'frota_entregas');

/** Viatura da empresa, com o motorista que a tem e as datas a não deixar passar. */
const fleetVehicleSchema = new Schema(
  {
    fleet: { type: Schema.Types.ObjectId, ref: 'Fleet', required: true, index: true },
    plate: { type: String, required: true, uppercase: true, trim: true },
    label: { type: String, required: true, trim: true },
    /** Motorista a quem está entregue. */
    driver: { type: Schema.Types.ObjectId, ref: 'Driver' },
    insuranceDue: Date,
    inspectionDue: Date,
    /** Próxima revisão ou mudança de óleo. */
    serviceDue: Date,
    notes: { type: String, default: '' },
  },
  { timestamps: true },
);
fleetVehicleSchema.index({ fleet: 1, plate: 1 }, { unique: true });
export const FleetVehicleModel = model('FleetVehicle', fleetVehicleSchema, 'frota_viaturas');

export const EXPENSE_KINDS = ['fuel', 'workshop', 'fine', 'insurance', 'other'] as const;
const fleetExpenseSchema = new Schema(
  {
    fleet: { type: Schema.Types.ObjectId, ref: 'Fleet', required: true, index: true },
    vehicle: { type: Schema.Types.ObjectId, ref: 'FleetVehicle', required: true, index: true },
    kind: { type: String, enum: EXPENSE_KINDS, required: true },
    amount: { type: Number, required: true },
    date: { type: Date, required: true },
    note: { type: String, default: '' },
    by: String,
  },
  { timestamps: true },
);
export const FleetExpenseModel = model('FleetExpense', fleetExpenseSchema, 'frota_despesas');

/** Turno semanal de um motorista: dias (0 = domingo) e horas "HH:MM". */
const fleetShiftSchema = new Schema(
  {
    fleet: { type: Schema.Types.ObjectId, ref: 'Fleet', required: true, index: true },
    driver: { type: Schema.Types.ObjectId, ref: 'Driver', required: true },
    days: { type: [Number], default: [] },
    start: { type: String, required: true },
    end: { type: String, required: true },
  },
  { timestamps: true },
);
fleetShiftSchema.index({ fleet: 1, driver: 1 }, { unique: true });
export const FleetShiftModel = model('FleetShift', fleetShiftSchema, 'frota_turnos');

// ── Empresas clientes ───────────────────────────────────────────────────────
/**
 * Empresa cujos colaboradores viajam "por conta da empresa": o passageiro não
 * paga ao motorista e a empresa recebe uma conta no fim do mês.
 */
const companySchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    nif: { type: String, default: '', trim: true },
    contactName: { type: String, default: '', trim: true },
    phone: { type: String, default: '' },
    email: { type: String, default: '', lowercase: true, trim: true },
    /** Máximo por mês, em Kz. 0 = sem limite. */
    monthlyLimit: { type: Number, default: 0 },
    active: { type: Boolean, default: true },
    /** Colaboradores autorizados, pelo telefone da conta de passageiro. */
    members: [{ phone: { type: String, required: true }, name: { type: String, default: '' }, active: { type: Boolean, default: true } }],
  },
  { timestamps: true },
);
export const CompanyModel = model('Company', companySchema, 'empresas_clientes');

/** Pagamento da empresa ao Bazá, por mês ("2026-11"). */
const companyPaymentSchema = new Schema(
  {
    company: { type: Schema.Types.ObjectId, ref: 'Company', required: true, index: true },
    month: { type: String, required: true },
    amount: { type: Number, required: true },
    note: { type: String, default: '' },
    by: String,
  },
  { timestamps: true },
);
export const CompanyPaymentModel = model('CompanyPayment', companyPaymentSchema, 'pagamentos_empresas');

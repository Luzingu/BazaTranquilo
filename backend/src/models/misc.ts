import { Schema, model } from 'mongoose';

const role = { type: String, enum: ['passenger', 'driver'], required: true } as const;

const otpSchema = new Schema({
  /** "<perfil>:<telefone>" — um código por telefone e por tipo de conta. */
  key: { type: String, required: true, unique: true },
  codeHash: { type: String, required: true },
  attempts: { type: Number, default: 0 },
  expiresAt: { type: Date, required: true, expires: 0 }, // índice TTL
});
export const OtpModel = model('Otp', otpSchema, 'codigos_otp');

const walletTxSchema = new Schema(
  {
    /** Id do passageiro ou do motorista, conforme `role`. */
    user: { type: Schema.Types.ObjectId, required: true, index: true },
    role,
    /** Positivo = crédito, negativo = débito. */
    amount: { type: Number, required: true },
    type: {
      type: String,
      enum: ['topup', 'ride_payment', 'ride_earning', 'commission', 'withdrawal'],
      required: true,
    },
    description: { type: String, default: '' },
    ride: { type: Schema.Types.ObjectId, ref: 'Ride' },
    balanceAfter: Number,
  },
  { timestamps: true },
);
export const WalletTxModel = model('WalletTransaction', walletTxSchema, 'movimentos_carteira');

const paymentSchema = new Schema(
  {
    user: { type: Schema.Types.ObjectId, required: true, index: true },
    role,
    amount: { type: Number, required: true },
    purpose: { type: String, enum: ['topup', 'ride'], required: true },
    ride: { type: Schema.Types.ObjectId, ref: 'Ride' },
    provider: { type: String, required: true },
    providerRef: String,
    status: { type: String, enum: ['pending', 'paid', 'failed'], default: 'pending' },
  },
  { timestamps: true },
);
export const PaymentModel = model('Payment', paymentSchema, 'pagamentos');

/** Pedido de levantamento do saldo de um motorista para a sua conta bancária. */
const withdrawalSchema = new Schema(
  {
    driver: { type: Schema.Types.ObjectId, ref: 'Driver', required: true, index: true },
    amount: { type: Number, required: true },
    iban: { type: String, required: true },
    status: { type: String, enum: ['pending', 'paid', 'rejected'], default: 'pending' },
  },
  { timestamps: true },
);
export const WithdrawalModel = model('Withdrawal', withdrawalSchema, 'levantamentos');

/** Alerta de emergência accionado durante uma corrida. */
const sosAlertSchema = new Schema(
  {
    ride: { type: Schema.Types.ObjectId, ref: 'Ride', required: true, index: true },
    role,
    user: { type: Schema.Types.ObjectId, required: true },
    lat: Number,
    lng: Number,
    /** Aberto: as autoridades acompanham a corrida. Fechado: deixam de ter acesso a ela. */
    status: { type: String, enum: ['open', 'closed'], default: 'open', index: true },
    closedAt: Date,
    closedBy: String,
    closeNote: String,
    /** Postos avisados (os mais próximos e, se ninguém abrir a tempo, o comando provincial). */
    stations: [{ type: Schema.Types.ObjectId, ref: 'Station' }],
    escalatedAt: Date,
    /** Agente que assumiu o alerta. */
    assignedTo: { type: Schema.Types.ObjectId, ref: 'Agent' },
    assignedName: String,
    assignedAt: Date,
    /** Cancelado por quem o accionou (com a senha). */
    cancelledByUser: { type: Boolean, default: false },
    /**
     * Pessoa de confiança: a conta Bazá (de passageiro) do contacto de
     * emergência de quem accionou o alerta. Acompanha a viagem no app e ouve o
     * som, enquanto o alerta estiver aberto.
     */
    guardian: { type: Schema.Types.ObjectId, index: true },
    /**
     * Som da viagem, partilhado por quem accionou o alerta: blocos de poucos
     * segundos, pela ordem em que foram gravados.
     */
    audio: [{ _id: false, seq: Number, file: String, at: Date }],
  },
  { timestamps: true },
);
export const SosAlertModel = model('SosAlert', sosAlertSchema, 'alertas_sos');

/** Mensagem do chat entre o passageiro e o motorista de uma corrida. */
const messageSchema = new Schema(
  {
    ride: { type: Schema.Types.ObjectId, ref: 'Ride', required: true, index: true },
    /** Quem escreveu. */
    role,
    text: { type: String, required: true },
  },
  { timestamps: true },
);
export const MessageModel = model('Message', messageSchema, 'mensagens');

/**
 * Local registado pela equipa do Bazá (painel): pontos conhecidos de cada
 * província que o mapa aberto não tem — bairros, mercados, paragens, hospitais.
 * Aparecem primeiro na pesquisa do app.
 */
const localSchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    /** Bairro ou município, ex.: "Soyo". */
    zone: { type: String, default: '', trim: true },
    /** Província, ex.: "Zaire". */
    province: { type: String, required: true, trim: true, index: true },
    lat: { type: Number, required: true },
    lng: { type: Number, required: true },
    /** Quem registou: um utilizador estrela (no app) ou a equipa (no painel, sem `addedBy`). */
    addedBy: { type: Schema.Types.ObjectId, index: true },
    addedByRole: { type: String, enum: ['passenger', 'driver'] },
    addedByName: String,
    /** Falso enquanto um local de um utilizador estrela não for visto pela equipa. */
    reviewed: { type: Boolean, default: true, index: true },
    /** Nome e zona em minúsculas e sem acentos, para a pesquisa. */
    searchKey: { type: String, required: true, index: true },
  },
  { timestamps: true },
);
export const LocalModel = model('Local', localSchema, 'locais');

/** Texto em minúsculas, sem acentos nem pontuação ("M'banza Kongo" → "mbanza kongo"). */
export const searchKeyOf = (text: string) =>
  text
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/['’`´]/g, '')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();

/**
 * Conta-corrente das comissões de um motorista: cada corrida em dinheiro soma
 * uma dívida ("charge"); cada pagamento registado pela equipa abate-a ("payment").
 */
const commissionSchema = new Schema(
  {
    driver: { type: Schema.Types.ObjectId, ref: 'Driver', required: true, index: true },
    /**
     * charge: comissão em dívida · payment: o motorista pagou ao Bazá ·
     * credit: o Bazá ficou a dever ao motorista (corrida por conta de uma empresa) ·
     * payout: o Bazá pagou ao motorista.
     */
    type: { type: String, enum: ['charge', 'payment', 'credit', 'payout'], required: true },
    /** Sempre positivo. */
    amount: { type: Number, required: true },
    ride: { type: Schema.Types.ObjectId, ref: 'Ride' },
    note: String,
    /** Administrador que registou o pagamento. */
    by: String,
    /** Dívida do motorista depois deste movimento. */
    dueAfter: { type: Number, required: true },
  },
  { timestamps: true },
);
export const CommissionEntryModel = model('CommissionEntry', commissionSchema, 'comissoes');

/** Pedido de ajuda ou reclamação enviado pelo app. */
export const TICKET_CATEGORIES = ['lost_item', 'ride', 'payment', 'safety', 'account', 'other'] as const;
const ticketSchema = new Schema(
  {
    account: { type: Schema.Types.ObjectId, required: true, index: true },
    role,
    name: String,
    phone: String,
    category: { type: String, enum: TICKET_CATEGORIES, required: true },
    message: { type: String, required: true },
    ride: { type: Schema.Types.ObjectId, ref: 'Ride' },
    status: { type: String, enum: ['open', 'resolved'], default: 'open', index: true },
    /** Resposta da equipa, mostrada ao utilizador no app. */
    reply: String,
    repliedBy: String,
    repliedAt: Date,
  },
  { timestamps: true },
);
export const TicketModel = model('Ticket', ticketSchema, 'pedidos_suporte');

/** Definições alteráveis no painel (ex.: percentagem de comissão). */
const settingSchema = new Schema(
  { key: { type: String, required: true, unique: true }, value: Schema.Types.Mixed, by: String },
  { timestamps: true },
);
export const SettingModel = model('Setting', settingSchema, 'definicoes');

/** Pagamento de mensalidade de uma viatura de preço combinado, registado no painel. */
const subscriptionPaymentSchema = new Schema(
  {
    driver: { type: Schema.Types.ObjectId, ref: 'Driver', required: true, index: true },
    vehicleId: { type: String, required: true },
    plate: String,
    category: String,
    months: { type: Number, required: true },
    amount: { type: Number, required: true },
    paidUntil: { type: Date, required: true },
    note: String,
    by: String,
  },
  { timestamps: true },
);
export const SubscriptionPaymentModel = model('SubscriptionPayment', subscriptionPaymentSchema, 'mensalidades');

/**
 * Pedido de pagamento feito pelo motorista no app (mensalidade de uma viatura
 * ou comissões): fica pendente até a equipa confirmar no painel.
 */
const paymentRequestSchema = new Schema(
  {
    driver: { type: Schema.Types.ObjectId, ref: 'Driver', required: true, index: true },
    driverName: String,
    phone: String,
    kind: { type: String, enum: ['subscription', 'commission'], required: true },
    /** Mensalidade: a viatura a que se refere e quantos meses. */
    vehicleId: String,
    plate: String,
    category: String,
    months: Number,
    amount: { type: Number, required: true },
    method: { type: String, enum: ['transfer', 'cash', 'multicaixa'], required: true },
    /** N.º do comprovativo, ou outra indicação que ajude a encontrar o pagamento. */
    reference: String,
    status: { type: String, enum: ['pending', 'confirmed', 'rejected'], default: 'pending', index: true },
    note: String,
    reviewedBy: String,
  },
  { timestamps: true },
);
export const PaymentRequestModel = model('PaymentRequest', paymentRequestSchema, 'pedidos_pagamento');

/**
 * Aviso enviado pela equipa, no painel, a um passageiro ou a um motorista (ou a
 * todos). Aparece numa janela no app e chega por notificação.
 */
const noticeSchema = new Schema(
  {
    account: { type: Schema.Types.ObjectId, required: true, index: true },
    role,
    title: { type: String, required: true },
    message: { type: String, required: true },
    /** Nome do administrador que enviou. */
    sentBy: String,
    /** Enviado a todos os passageiros ou motoristas de uma vez. */
    broadcast: { type: Boolean, default: false },
    readAt: Date,
  },
  { timestamps: true },
);
noticeSchema.index({ account: 1, readAt: 1 });
export const NoticeModel = model('Notice', noticeSchema, 'avisos');

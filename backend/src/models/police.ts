import { Schema, model, type HydratedDocument, type InferSchemaType } from 'mongoose';

// ── Postos policiais e agentes ──────────────────────────────────────────────
// O administrador regista os postos (por província e município, com a posição
// no mapa) e os agentes de cada posto. O agente usa a mesma aplicação dos
// passageiros e motoristas: ao entrar com o seu número, o servidor reconhece-o
// e abre a área do agente. Não existe opção "autoridade" visível no app.

const stationSchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    province: { type: String, required: true, trim: true, index: true },
    municipality: { type: String, default: '', trim: true },
    /** Telefone do posto: recebe um SMS quando não há agentes de serviço. */
    phone: { type: String, default: '' },
    lat: { type: Number, required: true },
    lng: { type: Number, required: true },
    /** Comando provincial: recebe os alertas que ninguém abriu a tempo. */
    command: { type: Boolean, default: false },
    active: { type: Boolean, default: true },
  },
  { timestamps: true },
);
export type StationDoc = HydratedDocument<InferSchemaType<typeof stationSchema>>;
export const StationModel = model('Station', stationSchema, 'postos_policiais');

const agentSchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    /** Exclusivo: um número de agente não pode ter conta de passageiro nem de motorista. */
    phone: { type: String, required: true, unique: true },
    /** Patente ou função, em texto livre. */
    rank: { type: String, default: '', trim: true },
    station: { type: Schema.Types.ObjectId, ref: 'Station', required: true, index: true },
    active: { type: Boolean, default: true },
    passwordHash: { type: String, select: false },
    /** Só quem está de serviço recebe os alertas. */
    onDuty: { type: Boolean, default: false },
    /** O telemóvel em que a conta foi aberta; noutro aparelho só entra depois de o administrador autorizar. */
    deviceId: String,
    pushTokens: { type: [String], default: [] },
    lastLoginAt: Date,
  },
  { timestamps: true },
);
export type AgentDoc = HydratedDocument<InferSchemaType<typeof agentSchema>>;
export const AgentModel = model('Agent', agentSchema, 'agentes');

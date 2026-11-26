import type { Request } from 'express';
import { config } from '../config.js';
import { HttpError } from '../http.js';
import { DriverModel, type DriverDoc } from '../models/accounts.js';
import { PaymentModel } from '../models/misc.js';
import { payCommission } from './billing.js';
import { pushToUser } from './push.js';
import { emitToUser } from './realtime.js';

// Pagamentos por referência (carregar o saldo do motorista) e a "sessão de
// pagamento" que o app mostra.
//
// O app NÃO sabe como cada fornecedor funciona: pede um carregamento, recebe uma
// sessão (`sessionView`) com o título, a mensagem, os dados a mostrar/copiar
// (entidade, referência…), um link opcional e o estado, e vai perguntando o
// estado até ficar pago, expirar ou falhar. Trocar de fornecedor ou de forma de
// pagamento faz-se só aqui, sem nova versão do app.
//
// Integrar um fornecedor real (EMIS, AppyPay, ProxyPay…):
//   1. escrever um `ReferenceProvider` (criar a referência na API dele e, em
//      `parseWebhook`, validar a autenticidade da notificação);
//   2. registá-lo em PROVIDERS e pôr REFERENCE_PROVIDER=<nome> no .env;
//   3. dar ao fornecedor o endereço  POST /payments/webhook/<nome>.

export interface ReferenceProvider {
  name: string;
  /** Nome da forma de pagamento como o motorista a lê. */
  label: string;
  create(p: { paymentId: string; amount: number; expiresAt: Date; phone?: string | null }): Promise<{ entity: string; reference: string; providerRef: string }>;
  /** Lê a notificação do fornecedor. null = notificação inválida ou não reconhecida. */
  parseWebhook?(req: Request): Promise<{ providerRef: string; status: 'paid' | 'failed'; amount?: number } | null>;
}

/**
 * Fornecedor de teste: gera uma referência fictícia e dá-a por paga ao fim de
 * PAYMENT_SIM_DELAY_S segundos (ou quando a equipa a marca como paga no painel).
 * Não há dinheiro real: só está disponível com PAYMENT_SIMULATION ligado.
 */
const simulated: ReferenceProvider = {
  name: 'simulado',
  label: 'Pagamento por referência (simulação)',
  async create({ paymentId }) {
    // 9 algarismos tirados do identificador do pagamento: estável e único o bastante para testes.
    const digits = BigInt(`0x${paymentId.slice(-12)}`).toString().slice(-9).padStart(9, '0');
    return { entity: '00000', reference: digits, providerRef: `SIM-${paymentId}` };
  },
};

const PROVIDERS: Record<string, ReferenceProvider> = { simulado: simulated };

const provider = () => PROVIDERS[config.payments.referenceProvider] ?? null;

const isSimulated = () => provider()?.name === 'simulado';

/** Este motorista pode gerar referências? (na simulação, só quem ela abrange) */
export function topupAvailable(driver: { phone?: string | null }) {
  const p = provider();
  if (!p) return false;
  if (p.name !== 'simulado') return true;
  const mode = config.payments.simulation;
  if (mode === 'all') return true;
  if (mode === 'testers') return config.payments.simPhones.includes((driver.phone ?? '').replace(/\D/g, '').slice(-9));
  return false;
}

const kz = (n: number) => `${String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ' ')} Kz`;
const groupDigits = (s: string) => s.replace(/(\d{3})(?=\d)/g, '$1 ');

type PaymentDoc = InstanceType<typeof PaymentModel>;

/** A sessão de pagamento como o app a mostra (genérica: serve qualquer fornecedor). */
export function sessionView(p: PaymentDoc) {
  const v = (p.view ?? {}) as { entity?: string; reference?: string; label?: string };
  const expired = p.status === 'pending' && p.expiresAt && p.expiresAt.getTime() < Date.now();
  const status = expired ? 'expired' : p.status;
  const STATUS_TEXT: Record<string, string> = {
    pending: 'À espera do pagamento',
    paid: 'Pago. O saldo foi carregado.',
    expired: 'Esta referência expirou. Gere uma nova.',
    failed: 'O pagamento não foi concluído.',
    cancelled: 'Cancelado.',
    awaiting_input: 'Complete os dados para continuar.',
  };
  const until = p.expiresAt?.toLocaleString('pt-PT', { timeZone: 'Africa/Luanda', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
  return {
    id: p.id as string,
    status,
    amount: p.amount,
    title: 'Carregar saldo',
    method: v.label ?? 'Pagamento por referência',
    statusText: STATUS_TEXT[status] ?? status,
    message:
      status === 'pending'
        ? 'Pague num Multicaixa, no Multicaixa Express ou no banco do seu telemóvel, em Pagamentos › Pagamento por referência. O saldo aumenta sozinho assim que o pagamento entrar.'
        : status === 'paid'
          ? `Foram carregados ${kz(p.amount)} no seu saldo.`
          : '',
    /** Dados a mostrar, com botão de copiar onde faz sentido. */
    details:
      status === 'pending'
        ? [
            { label: 'Entidade', value: v.entity ?? '', copy: true },
            { label: 'Referência', value: groupDigits(v.reference ?? ''), copy: true },
            { label: 'Montante', value: kz(p.amount), copy: false },
            ...(until ? [{ label: 'Válida até', value: until, copy: false }] : []),
          ]
        : [],
    /** Link a abrir (ex.: página do banco), quando o fornecedor o der. */
    openUrl: null as string | null,
    openLabel: null as string | null,
    expiresAt: p.expiresAt ?? null,
    /** De quantos em quantos segundos o app pergunta o estado. */
    pollSeconds: status === 'pending' ? 5 : 0,
    simulated: p.simulated,
    createdAt: p.get('createdAt') as Date,
  };
}

const simTimers = new Map<string, NodeJS.Timeout>();

/** O motorista pede uma referência para carregar `amount` no saldo. */
export async function createTopup(driver: DriverDoc, amount: number) {
  const b = config.driverBalance;
  if (!Number.isInteger(amount) || amount < b.topupMin || amount > b.topupMax) {
    throw new HttpError(400, `O valor tem de estar entre ${kz(b.topupMin)} e ${kz(b.topupMax)}.`);
  }
  const p = provider();
  if (!p || !topupAvailable(driver)) {
    throw new HttpError(503, 'O carregamento por referência ainda não está disponível. Pode transferir e comunicar o pagamento.');
  }
  // Uma referência por vez: a anterior por pagar é substituída.
  await PaymentModel.updateMany({ user: driver._id, role: 'driver', purpose: 'driver_fee', 'meta.kind': 'topup', status: 'pending' }, { status: 'cancelled', settledAt: new Date() });
  const expiresAt = new Date(Date.now() + b.referenceTtlHours * 3600_000);
  const payment = await PaymentModel.create({
    user: driver._id,
    role: 'driver',
    amount,
    purpose: 'driver_fee',
    provider: p.name,
    method: 'reference',
    status: 'pending',
    expiresAt,
    meta: { kind: 'topup' },
    simulated: p.name === 'simulado',
  });
  try {
    const ref = await p.create({ paymentId: payment.id as string, amount, expiresAt, phone: driver.phone });
    payment.providerRef = ref.providerRef;
    payment.view = { entity: ref.entity, reference: ref.reference, label: p.label };
    await payment.save();
  } catch (err) {
    payment.status = 'failed';
    payment.failureReason = (err as Error).message;
    await payment.save();
    throw new HttpError(502, 'Não foi possível gerar a referência agora. Tente daqui a pouco.');
  }
  if (payment.simulated && config.payments.simDelaySeconds > 0) {
    const t = setTimeout(() => {
      simTimers.delete(payment.id as string);
      void settlePayment(payment.id as string, 'paid', 'Simulação').catch((err) => console.error('[pagamentos] simulação:', err));
    }, config.payments.simDelaySeconds * 1000);
    t.unref();
    simTimers.set(payment.id as string, t);
  }
  return payment;
}

/**
 * Fecha um pagamento (uma só vez: só sai de "pending"). Pago → carrega o saldo
 * do motorista e avisa-o. Chamado pelo webhook do fornecedor, pela simulação ou
 * pela equipa (simulação) no painel.
 */
export async function settlePayment(paymentId: string, status: 'paid' | 'failed', by: string) {
  const payment = await PaymentModel.findOneAndUpdate(
    { _id: paymentId, status: 'pending' },
    { status, settledAt: new Date() },
    { returnDocument: 'after' },
  );
  if (!payment) return null;
  const timer = simTimers.get(paymentId);
  if (timer) clearTimeout(timer);
  if (status === 'paid' && payment.purpose === 'driver_fee' && (payment.meta as { kind?: string })?.kind === 'topup') {
    const driver = await DriverModel.findById(payment.user);
    if (driver) {
      const v = payment.view as { reference?: string };
      await payCommission(driver, payment.amount, {
        note: `Carregamento por referência ${groupDigits(v.reference ?? '')}${payment.simulated ? ' (simulação)' : ''}`,
        by,
      });
      emitToUser(driver.id, 'payment:update', sessionView(payment));
      void pushToUser(driver.id, { title: 'Saldo carregado', body: `Foram carregados ${kz(payment.amount)} no seu saldo do Bazá.` });
    }
  }
  return payment;
}

/** Notificação do fornecedor (POST /payments/webhook/:provider). */
export async function handleWebhook(name: string, req: Request) {
  const p = PROVIDERS[name];
  if (!p?.parseWebhook) throw new HttpError(404, 'Fornecedor desconhecido.');
  const event = await p.parseWebhook(req);
  if (!event) throw new HttpError(400, 'Notificação inválida.');
  const payment = await PaymentModel.findOne({ provider: name, providerRef: event.providerRef });
  if (!payment) throw new HttpError(404, 'Pagamento desconhecido.');
  if (event.amount !== undefined && event.status === 'paid' && event.amount < payment.amount) {
    console.warn(`[pagamentos] ${payment.id}: pago ${event.amount}, esperado ${payment.amount}`);
    return { ok: false };
  }
  await settlePayment(payment.id as string, event.status, name);
  return { ok: true };
}

/** Referências por pagar cujo prazo passou (corre de minuto a minuto). */
export async function expireReferences() {
  await PaymentModel.updateMany({ status: 'pending', expiresAt: { $lt: new Date() } }, { status: 'expired', settledAt: new Date() });
}

/** Estado das referências, para o painel: real, simulação (todos ou só testadores) ou indisponível. */
export function referenceMode(): 'real' | 'simulation' | 'testers' | 'off' {
  const p = provider();
  if (!p) return 'off';
  if (p.name !== 'simulado') return 'real';
  const mode = config.payments.simulation;
  return mode === 'all' ? 'simulation' : mode === 'testers' ? 'testers' : 'off';
}

export const simulationOn = () => isSimulated() && referenceMode() !== 'off';

import type { Types } from 'mongoose';
import { config } from '../config.js';
import { HttpError } from '../http.js';
import { PaymentModel, WalletTxModel } from '../models/misc.js';
import { incWallet, type Role } from '../models/accounts.js';

type Id = Types.ObjectId | string;
type TxType = 'topup' | 'ride_payment' | 'ride_earning' | 'commission' | 'withdrawal';

/**
 * Movimenta a carteira de um passageiro ou motorista de forma atómica. Com
 * `requireFunds`, um débito só acontece se houver saldo suficiente; devolve
 * false caso contrário.
 */
export async function adjustWallet(
  role: Role,
  userId: Id,
  amount: number,
  type: TxType,
  description: string,
  opts: { ride?: Id; requireFunds?: boolean } = {},
): Promise<boolean> {
  // Com a carteira desligada não se movimentam saldos.
  if (!config.walletEnabled) return opts.requireFunds ? false : true;
  if (amount === 0) return true;
  const account = await incWallet(role, userId, amount, opts.requireFunds && amount < 0 ? -amount : undefined);
  if (!account) return false;
  await WalletTxModel.create({
    user: userId,
    role,
    amount,
    type,
    description,
    ride: opts.ride,
    balanceAfter: account.walletBalance,
  });
  return true;
}

interface ChargeRequest {
  amount: number;
  reference: string;
  phone?: string | null;
}
interface ChargeResult {
  status: 'paid' | 'pending' | 'failed';
  providerRef: string;
}
interface PaymentProvider {
  name: string;
  charge(req: ChargeRequest): Promise<ChargeResult>;
}

/** Simula um pagamento aprovado de imediato. Apenas para desenvolvimento. */
const mockProvider: PaymentProvider = {
  name: 'mock',
  async charge(req) {
    return { status: 'paid', providerRef: `MOCK-${req.reference}` };
  },
};

/**
 * Multicaixa Express através do gateway da EMIS (GPO).
 * Falta implementar: exige contrato de comerciante com a EMIS e as respectivas
 * credenciais. O fluxo real é assíncrono — o cliente aprova na app Multicaixa
 * Express e a EMIS notifica o servidor; nessa notificação (depois de validar a
 * sua autenticidade) deve chamar-se `settlePayment`.
 */
const emisProvider: PaymentProvider = {
  name: 'emis',
  async charge() {
    throw new HttpError(503, 'Pagamento por Multicaixa Express ainda não está disponível.');
  },
};

function provider(): PaymentProvider {
  if (config.paymentProvider === 'emis') return emisProvider;
  if (config.paymentProvider === 'mock') {
    if (!config.isDev) throw new HttpError(503, 'Pagamentos electrónicos não configurados.');
    return mockProvider;
  }
  throw new Error(`PAYMENT_PROVIDER desconhecido: ${config.paymentProvider}`);
}

export function electronicPaymentsAvailable() {
  return config.paymentProvider === 'mock' && config.isDev;
}

/** Cria e tenta cobrar um pagamento electrónico. */
export async function createPayment(input: {
  role: Role;
  userId: Id;
  amount: number;
  purpose: 'topup' | 'ride';
  ride?: Id;
  phone?: string | null;
}) {
  const p = provider();
  const payment = await PaymentModel.create({
    user: input.userId,
    role: input.role,
    amount: input.amount,
    purpose: input.purpose,
    ride: input.ride,
    provider: p.name,
  });
  try {
    const result = await p.charge({
      amount: input.amount,
      reference: payment.id,
      phone: input.phone,
    });
    payment.providerRef = result.providerRef;
    payment.status = result.status;
  } catch (err) {
    payment.status = 'failed';
    await payment.save();
    throw err;
  }
  await payment.save();
  return payment;
}

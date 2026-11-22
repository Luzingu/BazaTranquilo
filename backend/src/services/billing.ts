import { config, service } from '../config.js';
import { HttpError } from '../http.js';
import { DriverModel, type DriverDoc } from '../models/accounts.js';
import { CommissionEntryModel, PaymentRequestModel, SubscriptionPaymentModel } from '../models/misc.js';
import { emitToUser } from './realtime.js';
import { pushToUser } from './push.js';
import { isNegotiated, monthlyFee, settings, subscriptionState } from './settings.js';

// O que os motoristas pagam ao Bazá: comissões das corridas em dinheiro e a
// mensalidade de cada viatura de preço combinado. O motorista avisa no app que
// pagou (pedido de pagamento); a equipa confirma no painel e só então a dívida
// é abatida ou a mensalidade prolongada. Preparado para ligar mais tarde um
// pagamento electrónico que confirme sozinho.

export const PAYMENT_METHODS = ['transfer', 'cash', 'multicaixa'] as const;
export type PaymentMethod = (typeof PAYMENT_METHODS)[number];

/** Prolonga a mensalidade de uma viatura e regista o pagamento. */
export async function extendSubscription(
  driver: DriverDoc,
  vehicleId: string,
  months: number,
  opts: { amount?: number; note?: string; by: string },
) {
  const vehicle = driver.vehicles.id(vehicleId);
  if (!vehicle) throw new HttpError(404, 'Viatura não encontrada.');
  if (!isNegotiated(vehicle.category)) throw new HttpError(400, 'Este tipo de viatura não paga mensalidade.');
  // A partir do fim do período actual, ou de hoje se já terminou.
  const until = vehicle.paidUntil && vehicle.paidUntil.getTime() > Date.now() ? new Date(vehicle.paidUntil) : new Date();
  until.setMonth(until.getMonth() + months);
  vehicle.paidUntil = until;
  await driver.save();
  await SubscriptionPaymentModel.create({
    driver: driver._id,
    vehicleId,
    plate: vehicle.plate,
    category: vehicle.category,
    months,
    amount: opts.amount ?? monthlyFee(vehicle.category) * months,
    paidUntil: until,
    note: opts.note,
    by: opts.by,
  });
  emitToUser(driver.id, 'account:update', {});
  return until;
}

/** Abate comissões em dívida e regista o pagamento. */
export async function payCommission(driver: DriverDoc, amount: number, opts: { note?: string; by: string }) {
  if (amount > driver.commissionDue) throw new HttpError(400, 'O valor é superior ao que o motorista deve.');
  driver.commissionDue -= amount;
  await driver.save();
  await CommissionEntryModel.create({
    driver: driver._id,
    type: 'payment',
    amount,
    note: opts.note,
    by: opts.by,
    dueAfter: driver.commissionDue,
  });
  emitToUser(driver.id, 'account:update', {});
  return driver.commissionDue;
}

/** As viaturas do motorista que pagam mensalidade, com o estado de cada uma. */
export function feeVehicles(driver: DriverDoc) {
  return driver.vehicles
    .filter((v) => isNegotiated(v.category))
    .map((v) => ({
      id: String(v._id),
      label: `${v.make} ${v.carModel}`,
      plate: v.plate,
      category: v.category,
      categoryLabel: service(v.category).label,
      fee: monthlyFee(v.category),
      state: subscriptionState(v.category, v.paidUntil),
      paidUntil: v.paidUntil ?? null,
      active: String(v._id) === driver.vehicle?.id,
    }));
}

export const requestOut = (r: InstanceType<typeof PaymentRequestModel>) => ({
  id: r.id as string,
  kind: r.kind,
  vehicleId: r.vehicleId ?? null,
  plate: r.plate ?? null,
  months: r.months ?? null,
  amount: r.amount,
  method: r.method,
  reference: r.reference ?? '',
  status: r.status,
  note: r.note ?? null,
  createdAt: r.get('createdAt') as Date,
});

/** Conta do motorista com o Bazá, como o app a mostra. */
export async function driverAccount(driver: DriverDoc) {
  const [entries, requests] = await Promise.all([
    CommissionEntryModel.find({ driver: driver._id }).sort({ createdAt: -1 }).limit(40),
    PaymentRequestModel.find({ driver: driver._id }).sort({ createdAt: -1 }).limit(20),
  ]);
  return {
    commission: {
      due: driver.commissionDue,
      rate: settings.commissionRate,
      limit: config.commission.debtLimit,
      enforced: config.commission.enforced,
    },
    payInfo: config.commission.payInfo,
    trialDays: config.subscriptionTrialDays,
    methods: PAYMENT_METHODS.filter((m) => m !== 'multicaixa'),
    vehicles: feeVehicles(driver),
    entries: entries.map((e) => ({
      id: e.id as string,
      type: e.type,
      amount: e.amount,
      note: e.note ?? null,
      dueAfter: e.dueAfter,
      createdAt: e.get('createdAt') as Date,
    })),
    requests: requests.map(requestOut),
  };
}

/** O motorista avisa que pagou (ou vai pagar): fica à espera de confirmação da equipa. */
export async function createPaymentRequest(
  driver: DriverDoc,
  input: { kind: 'subscription' | 'commission'; vehicleId?: string; months?: number; amount?: number; method: PaymentMethod; reference?: string },
) {
  if (input.method === 'multicaixa') throw new HttpError(503, 'O pagamento por Multicaixa Express ainda não está disponível.');
  let amount: number;
  let vehicle: ReturnType<DriverDoc['vehicles']['id']> = null;
  if (input.kind === 'subscription') {
    vehicle = driver.vehicles.id(input.vehicleId ?? '');
    if (!vehicle) throw new HttpError(404, 'Escolha a viatura a que a mensalidade se refere.');
    const fee = monthlyFee(vehicle.category);
    if (fee <= 0) throw new HttpError(400, 'Esta viatura não tem mensalidade a pagar.');
    if (!input.months) throw new HttpError(400, 'Indique quantos meses quer pagar.');
    amount = fee * input.months;
  } else {
    amount = input.amount ?? 0;
    if (amount <= 0) throw new HttpError(400, 'Indique o valor que pagou.');
    if (amount > driver.commissionDue) throw new HttpError(400, 'O valor é superior às comissões por pagar.');
  }
  const same = await PaymentRequestModel.countDocuments({
    driver: driver._id,
    kind: input.kind,
    status: 'pending',
    ...(vehicle ? { vehicleId: String(vehicle._id) } : {}),
  });
  if (same) {
    throw new HttpError(409, 'Já tem um pagamento destes à espera de confirmação.');
  }
  return PaymentRequestModel.create({
    driver: driver._id,
    driverName: driver.name,
    phone: driver.phone,
    kind: input.kind,
    vehicleId: vehicle ? String(vehicle._id) : undefined,
    plate: vehicle?.plate,
    category: vehicle?.category,
    months: input.kind === 'subscription' ? input.months : undefined,
    amount,
    method: input.method,
    reference: input.reference,
  });
}

/** A equipa confirma (aplica o pagamento) ou rejeita o pedido. */
export async function reviewPaymentRequest(id: string, approve: boolean, opts: { note?: string; by: string }) {
  const request = await PaymentRequestModel.findOne({ _id: id, status: 'pending' });
  if (!request) throw new HttpError(404, 'Pedido de pagamento não encontrado ou já tratado.');
  const driver = await DriverModel.findById(request.driver);
  if (approve) {
    if (!driver) throw new HttpError(404, 'O motorista já não existe.');
    const note = [request.method === 'cash' ? 'Dinheiro' : 'Transferência', request.reference].filter(Boolean).join(' · ');
    if (request.kind === 'subscription') {
      await extendSubscription(driver, request.vehicleId!, request.months!, { amount: request.amount, note, by: opts.by });
    } else {
      await payCommission(driver, Math.min(request.amount, driver.commissionDue), { note, by: opts.by });
    }
  } else if (!opts.note) {
    throw new HttpError(400, 'Indique o motivo da rejeição, para o motorista saber o que corrigir.');
  }
  request.status = approve ? 'confirmed' : 'rejected';
  request.note = opts.note;
  request.reviewedBy = opts.by;
  await request.save();
  if (driver) {
    emitToUser(driver.id, 'account:update', {});
    void pushToUser(driver.id, {
      title: approve ? 'Pagamento confirmado' : 'Pagamento não confirmado',
      body: approve
        ? request.kind === 'subscription'
          ? `A mensalidade da viatura ${request.plate ?? ''} foi prolongada.`
          : 'As suas comissões foram abatidas.'
        : (opts.note ?? ''),
    });
  }
  return request;
}

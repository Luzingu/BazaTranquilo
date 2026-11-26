import { config, service } from '../config.js';
import { HttpError } from '../http.js';
import { DriverModel, type DriverDoc } from '../models/accounts.js';
import { CommissionEntryModel, PaymentRequestModel, SubscriptionPaymentModel } from '../models/misc.js';
import { emitToUser } from './realtime.js';
import { pushToUser } from './push.js';
import { isNegotiated, monthlyFee, settings, subscriptionState } from './settings.js';
import { balanceOf, driversFree, freeRidesLeft } from './balance.js';
import { servedCategories } from '../models/accounts.js';
import { topupAvailable } from './gateway.js';

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

/**
 * Carrega o saldo do motorista (abate a conta-corrente; pode ficar negativa,
 * que é saldo a favor dele) e regista o movimento.
 */
export async function payCommission(driver: DriverDoc, amount: number, opts: { note?: string; by: string }) {
  if (!(amount > 0)) throw new HttpError(400, 'Indique um valor maior do que zero.');
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

const kz = (n: number) => `${String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ' ')} Kz`;

/** Paga meses de mensalidade com o saldo (desconta logo e prolonga a viatura). */
export async function paySubscriptionFromBalance(driver: DriverDoc, vehicleId: string, months: number) {
  const vehicle = driver.vehicles.id(vehicleId);
  if (!vehicle) throw new HttpError(404, 'Viatura não encontrada.');
  const fee = monthlyFee(vehicle.category);
  if (fee <= 0) throw new HttpError(400, 'Esta viatura não tem mensalidade a pagar.');
  const amount = fee * months;
  if (balanceOf(driver) < amount) {
    throw new HttpError(402, `Saldo insuficiente: a mensalidade custa ${kz(amount)} e tem ${kz(Math.max(0, balanceOf(driver)))}. Carregue o saldo primeiro.`);
  }
  driver.commissionDue += amount;
  await driver.save();
  await CommissionEntryModel.create({
    driver: driver._id,
    type: 'charge',
    amount,
    note: `Mensalidade ${vehicle.plate} · ${months === 1 ? '1 mês' : `${months} meses`}`,
    by: driver.name ?? 'Motorista',
    dueAfter: driver.commissionDue,
  });
  return extendSubscription(driver, vehicleId, months, { amount, note: 'Pago com o saldo', by: driver.name ?? 'Motorista' });
}

/**
 * A nota da conta no ecrã principal do motorista, já escrita (o app só a
 * mostra): mensalidade da viatura activa ou saldo e viagens grátis.
 */
export function accountNote(driver: DriverDoc): { text: string; detail: string; alert: boolean } | null {
  const active = driver.vehicles.id(driver.vehicle?.id ?? '');
  const rate = `${String(Math.round(settings.commissionRate * 1000) / 10).replace('.', ',')} %`;
  if (active && isNegotiated(active.category) && monthlyFee(active.category) > 0) {
    const fee = monthlyFee(active.category);
    const state = subscriptionState(active.category, active.paidUntil);
    const until = active.paidUntil?.toLocaleDateString('pt-PT', { timeZone: 'Africa/Luanda' });
    if (state === 'expired') return { alert: true, text: `Mensalidade em atraso · ${kz(fee)} por mês`, detail: `A mensalidade desta viatura terminou a ${until}. Pague-a com o saldo para voltar a ficar online.` };
    if (state === 'active') {
      const days = Math.floor((active.paidUntil!.getTime() - Date.now()) / 86_400_000);
      return { alert: days < 5, text: days < 5 ? `Mensalidade termina a ${until}` : `Mensalidade em dia até ${until}`, detail: `Esta viatura combina o preço com o cliente e paga uma mensalidade de ${kz(fee)}, descontada do saldo.` };
    }
    if (state === 'trial') return { alert: false, text: `Mensalidade de ${kz(fee)} · período grátis ao ficar online`, detail: 'O período grátis começa quando ficar online pela primeira vez. Depois paga-se com o saldo.' };
  }
  const tariff = driver.vehicle ? servedCategories(driver.vehicle).some((c) => !isNegotiated(c)) : true;
  if (!tariff) return null;
  if (driversFree()) {
    return { alert: false, text: 'Bazá gratuito para motoristas · sem taxas', detail: 'Neste momento o Bazá não cobra nada aos motoristas: as corridas não descontam taxa e não precisa de saldo para receber pedidos.' };
  }
  const free = freeRidesLeft(driver);
  const balance = balanceOf(driver);
  if (free > 0) {
    return { alert: false, text: `${free === 1 ? '1 viagem grátis' : `${free} viagens grátis`} · saldo ${kz(Math.max(0, balance))}`, detail: `As próximas ${free === 1 ? 'corrida não desconta' : `${free} corridas não descontam`} a taxa. Depois, cada corrida desconta ${rate} do preço do saldo.` };
  }
  if (balance <= 0) return { alert: true, text: 'Sem saldo · carregue para receber pedidos', detail: `Cada corrida desconta ${rate} do preço do saldo. Sem saldo para a taxa, não recebe pedidos.` };
  return { alert: balance < 1000, text: `Saldo ${kz(balance)}${balance < 1000 ? ' · está a acabar' : ''}`, detail: `Cada corrida desconta ${rate} do preço do saldo. Sem saldo para a taxa de uma corrida, não a recebe.` };
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
    /** Saldo pré-pago (o app mostra-o; a taxa de cada corrida sai daqui). */
    balance: {
      amount: balanceOf(driver),
      freeRidesLeft: freeRidesLeft(driver),
      rate: settings.commissionRate,
      /** Taxa a 0 %: gratuito, o app esconde "Carregar saldo". */
      free: driversFree(),
      /** Carregar por referência (gerada pela API). false: só transferência comunicada. */
      topup: {
        available: topupAvailable(driver),
        min: config.driverBalance.topupMin,
        max: config.driverBalance.topupMax,
        presets: config.driverBalance.topupPresets,
        label: 'Pagar por referência Multicaixa',
      },
    },
    note: accountNote(driver),
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
    // Carregamento do saldo por transferência ou em dinheiro: a equipa confirma.
    amount = input.amount ?? 0;
    if (amount <= 0) throw new HttpError(400, 'Indique o valor que carregou.');
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
      await payCommission(driver, request.amount, { note: `Carregamento · ${note}`, by: opts.by });
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
          : `O seu saldo foi carregado com ${kz(request.amount)}.`
        : (opts.note ?? ''),
    });
  }
  return request;
}

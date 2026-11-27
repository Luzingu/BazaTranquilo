import { SERVICE_KEYS, config, services } from '../config.js';
import { SettingModel } from '../models/misc.js';
import { loadPricing } from './pricing.js';

// Definições que a equipa pode mudar no painel sem reiniciar o servidor.
// Ficam na colecção `definicoes`; o valor de arranque vem de config.ts.

export const settings = {
  /** Parte de cada corrida que fica para o Bazá (0,15 = 15 %). */
  commissionRate: config.commissionRate,
  /**
   * Mensalidade (Kz) por tipo de viatura de preço combinado. 0 = gratuito: a
   * viatura fica sempre activa. Só as categorias `negotiated` contam.
   */
  monthlyFees: {} as Record<string, number>,
  /**
   * Entrada por código SMS. Desligada (ex.: sem saldo de SMS ou operadora em
   * baixo), entra-se e cria-se conta só com o número de telefone e a senha.
   */
  otpEnabled: true,
  /**
   * Código SMS para confirmar o número ao criar conta. Desligado, a conta
   * cria-se só com a senha e fica com o número por confirmar (como quando o
   * SMS falha); o app não volta a pedir o código enquanto estiver desligado.
   */
  signupSmsEnabled: true,
  /** Parte do valor de cada passageiro de uma viagem intermunicipal que fica para o Bazá. */
  intercityCommissionRate: 0.1,
  /** Viagens sem taxa para cada motorista novo (fixadas na conta quando é criada). */
  freeRides: config.driverBalance.freeRides,
};

/** Categorias de preço combinado, que pagam mensalidade em vez de comissão. */
export const NEGOTIATED = SERVICE_KEYS.filter((k) => (services[k] as { negotiated?: boolean }).negotiated);
export const isNegotiated = (category: string) => (NEGOTIATED as string[]).includes(category);
export const monthlyFee = (category: string) => (isNegotiated(category) ? (settings.monthlyFees[category] ?? 0) : 0);

/** Comissão de uma corrida: percentagem nas de tarifa; nada nas de preço combinado. */
export const commissionFor = (category: string, fare: number) =>
  isNegotiated(category) ? 0 : Math.round(fare * settings.commissionRate);

export const MAX_COMMISSION_RATE = 0.5;

export async function loadSettings() {
  await loadPricing();
  const saved = await SettingModel.findOne({ key: 'commissionRate' });
  if (typeof saved?.value === 'number' && saved.value >= 0 && saved.value <= MAX_COMMISSION_RATE) {
    settings.commissionRate = saved.value;
  }
  const otp = await SettingModel.findOne({ key: 'otpEnabled' });
  if (typeof otp?.value === 'boolean') settings.otpEnabled = otp.value;
  const signupSms = await SettingModel.findOne({ key: 'signupSmsEnabled' });
  if (typeof signupSms?.value === 'boolean') settings.signupSmsEnabled = signupSms.value;
  const inter = await SettingModel.findOne({ key: 'intercityCommissionRate' });
  if (typeof inter?.value === 'number' && inter.value >= 0 && inter.value <= MAX_COMMISSION_RATE) {
    settings.intercityCommissionRate = inter.value;
  }
  const free = await SettingModel.findOne({ key: 'freeRides' });
  if (typeof free?.value === 'number' && free.value >= 0) settings.freeRides = free.value;
  const fees = await SettingModel.findOne({ key: 'monthlyFees' });
  if (fees?.value && typeof fees.value === 'object') {
    for (const k of NEGOTIATED) {
      const v = (fees.value as Record<string, unknown>)[k];
      if (typeof v === 'number' && v >= 0) settings.monthlyFees[k] = v;
    }
  }
}

export async function setMonthlyFees(fees: Record<string, number>, by: string) {
  const clean: Record<string, number> = {};
  for (const k of NEGOTIATED) clean[k] = Math.max(0, Math.round(fees[k] ?? settings.monthlyFees[k] ?? 0));
  await SettingModel.updateOne({ key: 'monthlyFees' }, { value: clean, by }, { upsert: true });
  settings.monthlyFees = clean;
}

export async function setIntercityCommissionRate(rate: number, by: string) {
  await SettingModel.updateOne({ key: 'intercityCommissionRate' }, { value: rate, by }, { upsert: true });
  settings.intercityCommissionRate = rate;
}

export async function setFreeRides(count: number, by: string) {
  await SettingModel.updateOne({ key: 'freeRides' }, { value: count, by }, { upsert: true });
  settings.freeRides = count;
}

export async function setOtpEnabled(enabled: boolean, by: string) {
  await SettingModel.updateOne({ key: 'otpEnabled' }, { value: enabled, by }, { upsert: true });
  settings.otpEnabled = enabled;
}

export async function setSignupSmsEnabled(enabled: boolean, by: string) {
  await SettingModel.updateOne({ key: 'signupSmsEnabled' }, { value: enabled, by }, { upsert: true });
  settings.signupSmsEnabled = enabled;
}

/** Muda a comissão das corridas pedidas a partir de agora (as já pedidas mantêm a que tinham). */
export async function setCommissionRate(rate: number, by: string) {
  await SettingModel.updateOne({ key: 'commissionRate' }, { value: rate, by }, { upsert: true });
  settings.commissionRate = rate;
}

/**
 * Estado da mensalidade de uma viatura:
 * - `none`: categoria sem mensalidade (corridas com tarifa e comissão)
 * - `free`: categoria de preço combinado, mas a mensalidade está a 0
 * - `trial`: ainda não começou a contar; o período grátis arranca ao ficar online
 * - `active` / `expired`: paga até `paidUntil`, ou já terminada
 */
export function subscriptionState(category: string, paidUntil?: Date | null) {
  if (!isNegotiated(category)) return 'none' as const;
  if (monthlyFee(category) <= 0) return 'free' as const;
  if (!paidUntil) return 'trial' as const;
  return paidUntil.getTime() >= Date.now() ? ('active' as const) : ('expired' as const);
}

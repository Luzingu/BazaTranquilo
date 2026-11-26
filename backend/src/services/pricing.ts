import { HELPER_FEE, SERVICE_KEYS, STOP_FEE, config, service, type RideCategory } from '../config.js';
import { SettingModel } from '../models/misc.js';

// Preço das corridas de tarifa (Moto, Económico, Conforto) e taxa por procura.
// Tudo se altera no painel (Finanças › Tarifas e procura) e fica na colecção
// `definicoes`; os valores de arranque vêm de config.ts.
//
// Fórmula (a mesma que o painel mostra):
//   subtotal = base + km × preço/km + minutos × preço/minuto
//   preço    = máx(mínimo, subtotal) × multiplicador da procura,
//              arredondado para cima a 50 Kz, + paragens × preço por paragem
//
// O multiplicador da procura é o MAIOR entre a procura automática da zona e o
// horário em vigor (nunca se somam), limitado pelo tecto. Com ×1 o preço é o
// mesmo que antes de existir a taxa (os mínimos são múltiplos de 50).

export const FARE_STEP = config.fareStep;

export interface Tariff {
  base: number;
  perKm: number;
  perMin: number;
  minimum: number;
}

/** "Se houver `ratio` pedidos por cada motorista livre, multiplica por `multiplier`." */
export interface DemandTier {
  ratio: number;
  multiplier: number;
}

/** Faixa horária com multiplicador (hora de Luanda). `days`: 0 = domingo … 6 = sábado. */
export interface ScheduleRule {
  label: string;
  days: number[];
  start: string;
  end: string;
  multiplier: number;
}

export interface SurgeSettings {
  /** Procura automática: compara pedidos à procura com motoristas livres à volta da recolha. */
  autoEnabled: boolean;
  radiusKm: number;
  /** Só contam os pedidos feitos nos últimos `windowMin` minutos. */
  windowMin: number;
  tiers: DemandTier[];
  schedules: ScheduleRule[];
  /** Tecto: o multiplicador nunca passa daqui, venha de onde vier. */
  maxMultiplier: number;
}

/** Categorias com tarifa (as de preço combinado não usam a fórmula). */
export const TARIFF_KEYS = SERVICE_KEYS.filter((k) => !(service(k) as { negotiated?: boolean }).negotiated);

const defaultTariff = (k: RideCategory): Tariff => {
  const s = service(k);
  return { base: s.base, perKm: s.perKm, perMin: s.perMin, minimum: s.minimum };
};

export const DEFAULT_SURGE: SurgeSettings = {
  autoEnabled: false,
  radiusKm: 3,
  windowMin: 10,
  tiers: [
    { ratio: 2, multiplier: 1.2 },
    { ratio: 3, multiplier: 1.5 },
  ],
  schedules: [],
  maxMultiplier: 2,
};

export const pricing = {
  tariffs: Object.fromEntries(TARIFF_KEYS.map((k) => [k, defaultTariff(k)])) as Record<string, Tariff>,
  stopFee: STOP_FEE,
  surge: structuredClone(DEFAULT_SURGE),
};

export const tariffOf = (category: RideCategory): Tariff => pricing.tariffs[category] ?? defaultTariff(category);

// ── Fórmula ─────────────────────────────────────────────────────────────────

const roundUp = (n: number) => Math.ceil(n / FARE_STEP) * FARE_STEP;
const money = (n: number) => Math.round(n * 100) / 100;

/** O cálculo completo, passo a passo (o painel mostra-o no simulador). */
export function fareBreakdown(category: RideCategory, distanceM: number, durationS: number, stops = 0, multiplier = 1, helpers = 0) {
  const t = tariffOf(category);
  const km = distanceM / 1000;
  const min = durationS / 60;
  const kmPart = money(km * t.perKm);
  const minPart = money(min * t.perMin);
  const subtotal = money(t.base + kmPart + minPart);
  const usedMinimum = subtotal < t.minimum;
  const afterMinimum = Math.max(t.minimum, subtotal);
  const surged = money(afterMinimum * multiplier);
  const rounded = roundUp(surged);
  const stopsPart = stops * pricing.stopFee;
  const helpersPart = helpers * HELPER_FEE;
  return {
    tariff: t,
    km: money(km),
    min: money(min),
    kmPart,
    minPart,
    subtotal,
    usedMinimum,
    afterMinimum,
    multiplier,
    surged,
    rounded,
    stops,
    stopFee: pricing.stopFee,
    stopsPart,
    helpersPart,
    total: rounded + stopsPart + helpersPart,
  };
}

export const fareFor = (category: RideCategory, distanceM: number, durationS: number, stops = 0, multiplier = 1, helpers = 0) =>
  fareBreakdown(category, distanceM, durationS, stops, multiplier, helpers).total;

// ── Taxa por procura ────────────────────────────────────────────────────────

const TZ = 'Africa/Luanda';
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const toMin = (hhmm: string) => {
  const [h, m] = hhmm.split(':').map(Number);
  return h! * 60 + m!;
};

/** Dia da semana (0 = domingo) e minutos desde a meia-noite, na hora de Luanda. */
export function luandaClock(now = new Date()) {
  const parts = new Intl.DateTimeFormat('en-GB', { timeZone: TZ, weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '0';
  return { day: WEEKDAYS.indexOf(get('weekday')), minutes: Number(get('hour')) * 60 + Number(get('minute')) };
}

/** A regra cobre este momento? Faixas que passam a meia-noite (22:00–05:00) contam para o dia em que começam. */
export function ruleCovers(rule: ScheduleRule, day: number, minutes: number) {
  const start = toMin(rule.start);
  const end = toMin(rule.end);
  if (start === end) return rule.days.includes(day); // dia inteiro
  if (start < end) return rule.days.includes(day) && minutes >= start && minutes < end;
  const yesterday = (day + 6) % 7;
  return (rule.days.includes(day) && minutes >= start) || (rule.days.includes(yesterday) && minutes < end);
}

/** O horário em vigor com o maior multiplicador, ou null. */
export function activeSchedule(now = new Date()) {
  const { day, minutes } = luandaClock(now);
  let best: ScheduleRule | null = null;
  for (const r of pricing.surge.schedules) {
    if (r.multiplier > 1 && ruleCovers(r, day, minutes) && (!best || r.multiplier > best.multiplier)) best = r;
  }
  return best;
}

/** Multiplicador da procura automática para uma relação pedidos/motoristas livres. */
export function demandMultiplier(ratio: number) {
  let m = 1;
  for (const t of pricing.surge.tiers) if (ratio >= t.ratio && t.multiplier > m) m = t.multiplier;
  return m;
}

export interface Surge {
  multiplier: number;
  reason: 'demand' | 'schedule' | null;
  /** O que o passageiro lê ao lado do preço ("Procura alta", "Tarifa nocturna"). */
  label: string | null;
}

export const NO_SURGE: Surge = { multiplier: 1, reason: null, label: null };

/**
 * Junta as duas taxas: vale a maior, limitada pelo tecto. `demand` é a
 * contagem à volta da recolha (o pedido actual conta como um a mais).
 */
export function combineSurge(demand: { searching: number; free: number } | null, now = new Date()): Surge {
  const s = pricing.surge;
  const schedule = activeSchedule(now);
  const byDemand = s.autoEnabled && demand ? demandMultiplier((demand.searching + 1) / Math.max(demand.free, 1)) : 1;
  const bySchedule = schedule?.multiplier ?? 1;
  const top = Math.min(Math.max(byDemand, bySchedule), s.maxMultiplier);
  if (top <= 1) return NO_SURGE;
  const multiplier = Math.round(top * 100) / 100;
  return byDemand >= bySchedule
    ? { multiplier, reason: 'demand', label: 'Procura alta' }
    : { multiplier, reason: 'schedule', label: schedule!.label };
}

// ── Gravar e carregar ───────────────────────────────────────────────────────

export async function loadPricing() {
  const [tariffs, stopFee, surge] = await Promise.all([
    SettingModel.findOne({ key: 'tariffs' }),
    SettingModel.findOne({ key: 'stopFee' }),
    SettingModel.findOne({ key: 'surge' }),
  ]);
  if (tariffs?.value && typeof tariffs.value === 'object') {
    for (const k of TARIFF_KEYS) {
      const v = (tariffs.value as Record<string, Partial<Tariff>>)[k];
      if (v && [v.base, v.perKm, v.perMin, v.minimum].every((n) => typeof n === 'number' && n >= 0)) pricing.tariffs[k] = v as Tariff;
    }
  }
  if (typeof stopFee?.value === 'number' && stopFee.value >= 0) pricing.stopFee = stopFee.value;
  if (surge?.value && typeof surge.value === 'object') pricing.surge = { ...structuredClone(DEFAULT_SURGE), ...(surge.value as SurgeSettings) };
}

export async function setTariffs(tariffs: Record<string, Tariff>, stopFee: number, by: string) {
  const clean: Record<string, Tariff> = {};
  for (const k of TARIFF_KEYS) clean[k] = tariffs[k] ?? tariffOf(k);
  await Promise.all([
    SettingModel.updateOne({ key: 'tariffs' }, { value: clean, by }, { upsert: true }),
    SettingModel.updateOne({ key: 'stopFee' }, { value: stopFee, by }, { upsert: true }),
  ]);
  pricing.tariffs = clean;
  pricing.stopFee = stopFee;
}

export async function setSurge(surge: SurgeSettings, by: string) {
  const clean: SurgeSettings = {
    ...surge,
    tiers: [...surge.tiers].sort((a, b) => a.ratio - b.ratio),
    schedules: surge.schedules.map((r) => ({ ...r, days: [...new Set(r.days)].sort() })),
  };
  await SettingModel.updateOne({ key: 'surge' }, { value: clean, by }, { upsert: true });
  pricing.surge = clean;
}

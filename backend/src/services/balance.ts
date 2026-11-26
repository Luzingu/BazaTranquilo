import { settings } from './settings.js';

// Saldo pré-pago dos motoristas (decisão do dono, 2026-11-26).
//
// O saldo é o simétrico da conta-corrente `commissionDue`: carregar o saldo
// abate-a (fica negativa = saldo positivo), cada corrida de tarifa acrescenta a
// taxa, a mensalidade paga com o saldo também. Assim o histórico (CommissionEntry),
// o painel e o crédito das corridas por conta de empresa continuam a valer.
//
// Regra: sem saldo para a taxa de uma corrida (e sem viagens grátis), o
// motorista não a recebe, não a aceita e não faz propostas para ela.

/** Taxa a 0 %: o Bazá é gratuito para os motoristas — ninguém precisa de saldo nem é bloqueado. */
export const driversFree = () => settings.commissionRate <= 0;

type WithBalance = { commissionDue?: number | null; freeRidesLeft?: number | null };

export const balanceOf = (d: WithBalance) => -(d.commissionDue ?? 0);

/** Viagens grátis que restam (contas anteriores ao saldo: vale o valor do painel). */
export const freeRidesLeft = (d: WithBalance) => Math.max(0, d.freeRidesLeft ?? settings.freeRides);

/** O motorista pode fazer uma corrida com esta taxa? */
export const coversFee = (d: WithBalance, fee: number) => fee <= 0 || freeRidesLeft(d) > 0 || balanceOf(d) >= fee;

/** O mesmo, como filtro do MongoDB sobre motoristas. */
export function coversFeeFilter(fee: number) {
  if (fee <= 0) return {};
  const or: Record<string, unknown>[] = [{ freeRidesLeft: { $gt: 0 } }, { commissionDue: { $lte: -fee } }];
  if (settings.freeRides > 0) or.push({ freeRidesLeft: { $exists: false } });
  return { $or: or };
}

const kz = (n: number) => `${String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ' ')} Kz`;

export const noBalanceMessage = (fee: number) =>
  `Saldo insuficiente para a taxa desta corrida (${kz(fee)}). Carregue o saldo em Menu › O meu saldo.`;

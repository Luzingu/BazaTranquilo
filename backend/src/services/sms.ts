import { config } from '../config.js';
import { HttpError } from '../http.js';

// Envio de SMS (códigos de confirmação). Em produção usa a TelcoSMS (Angola);
// sem chave configurada, em desenvolvimento, o SMS é só escrito no log.

/** true quando os SMS são mesmo enviados (e, portanto, custam saldo). */
export const smsIsReal = () => config.smsProvider === 'telcosms';

/**
 * Converte um telefone para o formato da TelcoSMS: 9 dígitos começados por 9.
 * Devolve null se não for um telemóvel angolano.
 */
export function toTelcoNumber(phone: string): string | null {
  let digits = phone.replace(/\D/g, '');
  if (digits.length === 12 && digits.startsWith('244')) digits = digits.slice(3);
  return /^9\d{8}$/.test(digits) ? digits : null;
}

// Cada SMS custa dinheiro: limita-se o número de envios por telefone, para um
// atacante não gastar o saldo nem incomodar o dono do número. (Em memória: chega
// para um servidor; com vários servidores passaria para a base de dados.)
const MIN_INTERVAL_MS = 60_000;
const MAX_PER_HOUR = 5;
const sentAt = new Map<string, number[]>();

function checkQuota(number: string) {
  const now = Date.now();
  const recent = (sentAt.get(number) ?? []).filter((t) => now - t < 3_600_000);
  const last = recent.at(-1);
  if (last && now - last < MIN_INTERVAL_MS) {
    const wait = Math.ceil((MIN_INTERVAL_MS - (now - last)) / 1000);
    throw new HttpError(429, `Já enviámos um código para este número. Aguarde ${wait} segundos para pedir outro.`);
  }
  if (recent.length >= MAX_PER_HOUR) {
    throw new HttpError(429, 'Pediu demasiados códigos para este número. Tente de novo dentro de uma hora.');
  }
  recent.push(now);
  sentAt.set(number, recent);
  // Evita que o mapa cresça sem limite.
  if (sentAt.size > 5000) {
    for (const [key, times] of sentAt) if (now - (times.at(-1) ?? 0) > 3_600_000) sentAt.delete(key);
  }
}

async function sendViaTelco(number: string, text: string): Promise<boolean> {
  let status = 0;
  try {
    const res = await fetch(`${config.telcoSmsUrl}/send_message`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({
        message: { api_key_app: config.telcoSmsApiKey, phone_number: number, message_body: text },
      }),
      signal: AbortSignal.timeout(15_000),
    });
    status = res.status;
    if (!res.ok) return false;
    const data = (await res.json()) as { status?: unknown };
    return Number(data.status) === 200;
  } catch {
    return false;
  } finally {
    // No log fica só o telefone e o código HTTP: nunca a chave nem o texto (tem o código).
    console.log(`[SMS] ${number} → HTTP ${status || 'sem resposta'}`);
  }
}

/**
 * Envia um SMS. Lança um erro com a mensagem a mostrar ao utilizador se o
 * número não servir, se o limite de envios foi atingido ou se o envio falhar.
 */
export async function sendSms(phone: string, text: string) {
  if (!smsIsReal()) {
    if (!config.isDev) throw new HttpError(503, 'Envio de SMS não configurado.');
    console.log(`[SMS simulado → ${phone}] ${text}`);
    return;
  }
  const number = toTelcoNumber(phone);
  if (!number) throw new HttpError(400, 'Só é possível enviar o código para telemóveis angolanos (9 dígitos, começados por 9).');
  checkQuota(number);
  if (!(await sendViaTelco(number, text))) {
    // Não conta para o limite um SMS que não saiu.
    sentAt.get(number)?.pop();
    throw new HttpError(502, 'Não foi possível enviar o SMS. Tente de novo dentro de momentos.');
  }
}

/** Saldo de SMS na TelcoSMS, para o painel do administrador. */
let balanceCache: { at: number; value: SmsBalance | null } | null = null;
export interface SmsBalance {
  available: number;
  sent: number;
  planExpired: boolean;
}
export async function smsBalance(): Promise<SmsBalance | null> {
  if (!smsIsReal()) return null;
  if (balanceCache && Date.now() - balanceCache.at < 5 * 60_000) return balanceCache.value;
  let value: SmsBalance | null = null;
  try {
    const res = await fetch(
      `${config.telcoSmsUrl}/check_balance?api_key_app=${encodeURIComponent(config.telcoSmsApiKey)}`,
      { headers: { Accept: 'application/json' }, signal: AbortSignal.timeout(15_000) },
    );
    const data = (await res.json()) as { status?: unknown; company_info?: Record<string, unknown> };
    if (res.ok && Number(data.status) === 200 && data.company_info) {
      value = {
        available: Number(data.company_info.sms_available ?? 0),
        sent: Number(data.company_info.sms_sent ?? 0),
        planExpired: String(data.company_info.plan_expirad ?? '').toLowerCase() === 'yes',
      };
    }
  } catch {
    value = null;
  }
  balanceCache = { at: Date.now(), value };
  return value;
}

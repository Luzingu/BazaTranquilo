import { createSign } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { config } from '../config.js';
import { DriverModel, PassengerModel } from '../models/accounts.js';

// Notificações "push" (Firebase Cloud Messaging), para avisar quem tem o app
// fechado. Fica desligado enquanto não existir a chave da conta de serviço do
// Firebase (ficheiro indicado em FIREBASE_KEY_FILE, fora do git).
//
// Nos registos só fica o resultado do envio — nunca a chave nem os tokens.

interface ServiceKey {
  project_id: string;
  client_email: string;
  private_key: string;
}

let key: ServiceKey | null | undefined;
function serviceKey(): ServiceKey | null {
  if (key !== undefined) return key;
  key = null;
  try {
    if (config.firebaseKeyFile && existsSync(config.firebaseKeyFile)) {
      const data = JSON.parse(readFileSync(config.firebaseKeyFile, 'utf8')) as Partial<ServiceKey>;
      if (data.project_id && data.client_email && data.private_key) key = data as ServiceKey;
      else console.warn('Push: o ficheiro da chave do Firebase não é uma chave de conta de serviço.');
    }
  } catch {
    console.warn('Push: não foi possível ler a chave do Firebase.');
  }
  return key;
}

export const pushEnabled = () => !!serviceKey();

const b64 = (data: string | Buffer) => Buffer.from(data).toString('base64url');

let access: { token: string; expiresAt: number } | null = null;
async function accessToken(k: ServiceKey): Promise<string> {
  if (access && access.expiresAt > Date.now() + 60_000) return access.token;
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${b64(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))}.${b64(
    JSON.stringify({
      iss: k.client_email,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    }),
  )}`;
  const signature = createSign('RSA-SHA256').update(unsigned).sign(k.private_key);
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${unsigned}.${b64(signature)}`,
    }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) throw new Error(`autenticação no Firebase falhou (HTTP ${res.status})`);
  const data = (await res.json()) as { access_token: string; expires_in: number };
  access = { token: data.access_token, expiresAt: Date.now() + data.expires_in * 1000 };
  return access.token;
}

export interface PushMessage {
  title: string;
  body: string;
  /** Corridas e chamadas: toca e aparece por cima. */
  urgent?: boolean;
  /**
   * Aviso falado (ex.: 'voz_chegou'): a notificação toca a gravação em vez do
   * som normal, mesmo com o app fechado. Os sons vivem no app
   * (android/app/src/main/res/raw) e cada um tem o seu canal `baza_<voz>`.
   */
  voice?: 'voz_aceite' | 'voz_chegou' | 'voz_inicio' | 'voz_fim' | 'alerta_perigo';
}

/** Envia para um dispositivo. Devolve 'gone' se o token já não existe. */
async function sendTo(k: ServiceKey, token: string, msg: PushMessage): Promise<'ok' | 'gone' | 'error'> {
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${k.project_id}/messages:send`, {
    method: 'POST',
    headers: { authorization: `Bearer ${await accessToken(k)}`, 'content-type': 'application/json' },
    body: JSON.stringify({
      message: {
        token,
        notification: { title: msg.title, body: msg.body },
        android: {
          priority: 'HIGH',
          ttl: msg.urgent ? '60s' : '600s',
          notification: msg.voice
            ? { channel_id: `baza_${msg.voice}`, sound: msg.voice }
            : { channel_id: msg.urgent ? 'baza_urgente' : 'baza_avisos', sound: 'default' },
        },
      },
    }),
    signal: AbortSignal.timeout(10_000),
  });
  if (res.ok) return 'ok';
  if (res.status === 404 || res.status === 400) return 'gone';
  console.warn(`Push: envio falhou (HTTP ${res.status}).`);
  return 'error';
}

/** Envia um aviso aos dispositivos indicados; devolve os que já não existem. */
export async function pushToTokens(tokens: string[], msg: PushMessage): Promise<string[]> {
  const k = serviceKey();
  if (!k || !tokens.length) return [];
  const gone: string[] = [];
  try {
    for (const token of tokens) if ((await sendTo(k, token, msg)) === 'gone') gone.push(token);
  } catch (err) {
    console.warn('Push:', (err as Error).message);
  }
  return gone;
}

/** Envia um aviso a todos os dispositivos de uma conta (passageiro ou motorista). */
export async function pushToUser(userId: string, msg: PushMessage) {
  const k = serviceKey();
  if (!k) return;
  try {
    const account =
      (await DriverModel.findById(userId).select('pushTokens')) ??
      (await PassengerModel.findById(userId).select('pushTokens'));
    const tokens: string[] = account?.pushTokens ?? [];
    if (!tokens.length) return;
    const gone: string[] = [];
    for (const token of tokens) if ((await sendTo(k, token, msg)) === 'gone') gone.push(token);
    if (gone.length) await account!.updateOne({ $pull: { pushTokens: { $in: gone } } });
  } catch (err) {
    console.warn('Push:', (err as Error).message);
  }
}

const kz = (n: unknown) => `${Number(n ?? 0).toLocaleString('pt-PT').replace(/\s/g, ' ')} Kz`;

/** O aviso que corresponde a um evento em tempo real, ou null se não merece aviso. */
export function pushForEvent(userId: string, event: string, payload: any): PushMessage | null {
  if (event === 'ride:offer') {
    return {
      title: `Nova corrida · ${kz(payload?.fare)}`,
      body: `${payload?.pickup?.address ?? ''} → ${payload?.dropoff?.address ?? ''}`,
      urgent: true,
    };
  }
  // Viagens intermunicipais: o texto do aviso já vem pronto no evento.
  if (event === 'intercity:update') {
    return typeof payload?.title === 'string' ? { title: payload.title, body: String(payload.body ?? ''), urgent: true } : null;
  }
  // Aviso enviado pela equipa no painel.
  if (event === 'notice:new') {
    return typeof payload?.title === 'string' ? { title: payload.title, body: String(payload.message ?? '').slice(0, 180), urgent: true } : null;
  }
  // Um amigo pediu ajuda e tem esta pessoa como contacto de confiança.
  if (event === 'guardian:alert') {
    return typeof payload?.title === 'string' ? { title: payload.title, body: String(payload.body ?? ''), urgent: true, voice: 'alerta_perigo' } : null;
  }
  if (event === 'chat:message') {
    const text = payload?.message?.text;
    return typeof text === 'string' ? { title: 'Nova mensagem', body: text.slice(0, 140) } : null;
  }
  if (event === 'ride:update') {
    const isDriver = payload?.driver?.id === userId;
    const status = payload?.status;
    if (isDriver) {
      return status === 'cancelled' ? { title: 'Corrida cancelada', body: 'O passageiro cancelou a corrida.' } : null;
    }
    switch (status) {
      case 'accepted':
        return { title: 'Motorista a caminho', body: `${payload?.driver?.name ?? 'O motorista'} aceitou a sua corrida.`, voice: 'voz_aceite' };
      case 'arrived':
        return { title: 'O motorista chegou', body: `Está à sua espera em ${payload?.pickup?.address ?? 'no ponto de recolha'}.`, urgent: true, voice: 'voz_chegou' };
      case 'in_progress':
        return { title: 'Viagem iniciada', body: 'Bem-vindo ao Bazá Tranquilo. Boa viagem!', voice: 'voz_inicio' };
      case 'completed':
        return { title: 'Chegou ao destino', body: `Total: ${kz(payload?.fare)}. Obrigado por viajar com o Bazá.`, voice: 'voz_fim' };
      case 'cancelled':
        return { title: 'Corrida cancelada', body: 'A sua corrida foi cancelada.' };
      default:
        return null;
    }
  }
  return null;
}

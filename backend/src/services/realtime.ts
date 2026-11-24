import type { Server as HttpServer } from 'node:http';
import { Server } from 'socket.io';
import { z } from 'zod';
import { verifyToken } from '../http.js';
import { findAccountById, type Role } from '../models/accounts.js';
import { RideModel } from '../models/Ride.js';
import { pushEnabled, pushForEvent, pushToUser } from './push.js';
import { updateDriverLocation } from './rides.js';

let io: Server | undefined;

/** Desliga as ligações em tempo real de uma conta (as sessões dela deixaram de valer). */
export function dropLiveSessions(userId: string) {
  io?.in(`user:${userId}`).disconnectSockets(true);
}

const locationSchema = z.object({
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  heading: z.number().optional(),
});

export function initRealtime(server: HttpServer) {
  io = new Server(server, { cors: { origin: '*' } });

  io.use((socket, next) => {
    const token = socket.handshake.auth?.token;
    const auth = typeof token === 'string' ? verifyToken(token) : null;
    if (!auth) return next(new Error('unauthorized'));
    // A sessão tem de ser da versão actual da conta (cai quando o dono do número a recupera).
    findAccountById(auth.role, auth.id)
      .then((account) => {
        if (!account || account.deactivatedAt || (account.sessionVersion ?? 0) !== auth.version) {
          return next(new Error('unauthorized'));
        }
        socket.data.userId = auth.id;
        socket.data.role = auth.role;
        next();
      })
      .catch(() => next(new Error('unauthorized')));
  });

  io.on('connection', (socket) => {
    const userId = socket.data.userId as string;
    socket.join(`user:${userId}`);

    // Chamadas de voz dentro do app: o servidor só encaminha a sinalização
    // (convite, aceitar, descrições e candidatos WebRTC) entre as duas pessoas
    // de uma corrida em curso. O áudio vai directamente de um telemóvel ao outro.
    socket.on('call:signal', (payload: unknown) => {
      relayCallSignal(userId, socket.data.role as Role, payload).catch((err) => console.error(err));
    });

    socket.on('driver:location', (payload: unknown) => {
      const parsed = locationSchema.safeParse(payload);
      if (!parsed.success || socket.data.role !== 'driver') return;
      updateDriverLocation(userId, parsed.data).catch((err) => console.error(err));
    });
  });
}

const callSignal = z.object({
  rideId: z.string().regex(/^[0-9a-f]{24}$/i),
  type: z.enum(['invite', 'ringing', 'accept', 'reject', 'busy', 'offer', 'answer', 'candidate', 'hangup']),
  // Descrição ou candidato WebRTC; limitado para ninguém usar o canal para outra coisa.
  data: z.record(z.string(), z.unknown()).optional(),
});

async function relayCallSignal(userId: string, role: Role, payload: unknown) {
  const parsed = callSignal.safeParse(payload);
  if (!parsed.success || JSON.stringify(parsed.data.data ?? {}).length > 20_000) return;
  const { rideId, type, data } = parsed.data;
  // Só as duas pessoas de uma corrida com motorista atribuído se podem ligar.
  const ride = await RideModel.findOne({
    _id: rideId,
    [role === 'passenger' ? 'passenger' : 'driver']: userId,
    status: { $in: ['accepted', 'arrived', 'in_progress'] },
  }).select('passenger driver');
  if (!ride?.driver) {
    // Desligar tem de chegar mesmo que a corrida tenha acabado entretanto.
    if (type !== 'hangup') emitToUser(userId, 'call:signal', { rideId, type: 'unavailable', from: 'server' });
    if (type !== 'hangup') return;
    const ended = await RideModel.findOne({
      _id: rideId,
      [role === 'passenger' ? 'passenger' : 'driver']: userId,
    }).select('passenger driver');
    if (!ended?.driver) return;
    emitToUser(String(role === 'passenger' ? ended.driver : ended.passenger), 'call:signal', { rideId, type, from: role });
    return;
  }
  const other = String(role === 'passenger' ? ride.driver : ride.passenger);
  if (type === 'invite' && !(await isConnected(other))) {
    // A outra pessoa não tem o app aberto: não há como a chamada tocar. Fica o aviso.
    void pushToUser(other, {
      title: 'Chamada perdida',
      body: `${role === 'passenger' ? 'O passageiro' : 'O motorista'} tentou ligar-lhe. Abra o Bazá para responder.`,
      urgent: true,
    });
    emitToUser(userId, 'call:signal', { rideId, type: 'unavailable', from: 'server' });
    return;
  }
  emitToUser(other, 'call:signal', { rideId, type, data, from: role });
}

/** Envia um evento a todos os dispositivos ligados de um passageiro ou motorista. */
export function emitToUser(userId: string, event: string, payload: unknown) {
  io?.to(`user:${userId}`).emit(event, payload);
  if (pushEnabled()) notifyIfAway(userId, event, payload).catch((err) => console.error(err));
}

/** Quem não tem o app ligado (fechado ou sem rede) é avisado por notificação push. */
async function notifyIfAway(userId: string, event: string, payload: unknown) {
  const msg = pushForEvent(userId, event, payload);
  if (!msg || (await isConnected(userId))) return;
  await pushToUser(userId, msg);
}

const isConnected = async (userId: string) => !!(await io?.in(`user:${userId}`).fetchSockets())?.length;

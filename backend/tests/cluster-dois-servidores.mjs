// Prova do tempo real entre DOIS servidores pela base partilhada (réplica no Serve2, 2026-11-27).
// Uso: MONGODB_TEST_URI=… node tests/cluster-dois-servidores.mjs   (só a base de teste)
import { createServer } from 'node:http';
import { Server } from 'socket.io';
import { io as cliente } from 'socket.io-client';
import { createAdapter } from '@socket.io/mongo-adapter';
import { MongoClient } from 'mongodb';

const uri = process.env.MONGODB_TEST_URI;
if (!uri || !/baza_teste/.test(uri)) { console.error('Precisa de MONGODB_TEST_URI (base baza_teste).'); process.exit(2); }
const mongo = new MongoClient(uri); await mongo.connect();
const db = mongo.db(); const COL = 'socketio_eventos_teste';
if (!(await db.listCollections({ name: COL }).hasNext())) await db.createCollection(COL, { capped: true, size: 1e6 });

function servidor(porta) {
  const http = createServer(); const io = new Server(http);
  io.adapter(createAdapter(db.collection(COL)));
  io.on('connection', (s) => s.join(`user:${s.handshake.auth.u}`));
  return new Promise((r) => http.listen(porta, '127.0.0.1', () => r({ io, http })));
}
const A = await servidor(4191), B = await servidor(4192);
const c = cliente('http://127.0.0.1:4192', { transports: ['websocket'], auth: { u: 'motorista1' } });
await new Promise((r) => c.on('connect', r));
await new Promise((r) => setTimeout(r, 1500)); // o adaptador anuncia-se aos outros
let ok = 0, falhas = 0; const v = (c_, t) => { c_ ? ok++ : falhas++; console.log(`${c_ ? '✓' : '✗'} ${t}`); };
const recebido = new Promise((r) => c.on('ride:offer', r));
A.io.to('user:motorista1').emit('ride:offer', { rideId: 'x' });
v(await Promise.race([recebido.then(() => true), new Promise((r) => setTimeout(() => r(false), 5000))]), 'evento emitido no servidor A chega ao cliente ligado ao B');
v((await A.io.in('user:motorista1').fetchSockets()).length === 1, 'o servidor A sabe que o cliente está ligado (no B)');
v((await A.io.in('user:ninguem').fetchSockets()).length === 0, 'quem não está ligado continua a não aparecer');
await A.io.in('user:motorista1').disconnectSockets(true);
await new Promise((r) => setTimeout(r, 1500));
v(!c.connected, 'desligar no A desliga a ligação no B (sessão que deixou de valer)');
c.close(); A.io.close(); B.io.close(); await db.collection(COL).drop().catch(() => {}); await mongo.close();
console.log(`\n${ok} verificações passaram, ${falhas} falharam.`); process.exit(falhas ? 1 : 0);

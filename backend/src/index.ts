import { createServer } from 'node:http';
import cors from 'cors';
import express from 'express';
import rateLimit, { ipKeyGenerator } from 'express-rate-limit';
import helmet from 'helmet';
import mongoose from 'mongoose';
import { config } from './config.js';
import { HttpError, errorHandler, verifyToken } from './http.js';
import {
  catalogRouter,
  driverRouter,
  favoritesRouter,
  placesRouter,
  ridesRouter,
  vehiclesRouter,
  walletRouter,
} from './routes/api.js';
import { authRouter, meRouter } from './routes/auth.js';
import { documentsRouter } from './routes/documents.js';
import { legalRouter } from './routes/legal.js';
import { mapsRouter } from './routes/maps.js';
import { ensureFirstAdmin, ensureFleetUsers, panelApi, panelStatic } from './routes/panel.js';
import { safetyRouter, shareRouter, guardianRouter } from './routes/share.js';
import { supportRouter, noticesRouter } from './routes/support.js';
import { intercityRouter } from './routes/intercity.js';
import { agentRouter, escalateStaleAlerts, purgeOldAudio } from './routes/agent.js';
import { loadSettings } from './services/settings.js';
import { sendFile } from './services/files.js';
import { initRealtime } from './services/realtime.js';
import { resumeSearches } from './services/rides.js';

const app = express();
app.set('trust proxy', 1);
app.use(helmet());
app.use(cors());
app.use(express.json({ limit: '100kb' }));

// Protecção contra excesso de pedidos. Conta por conta (quando há sessão) e
// não só por IP: nas redes móveis muitos clientes partilham o mesmo IP.
const requester = (req: express.Request) => {
  const header = req.headers.authorization ?? '';
  const auth = header.startsWith('Bearer ') ? verifyToken(header.slice(7)) : null;
  return auth ? `u:${auth.id}` : `ip:${ipKeyGenerator(req.ip ?? '')}`;
};
const tooMany = { error: 'Demasiados pedidos. Aguarde um momento e tente de novo.' };
// As imagens do mapa são muitos pedidos pequenos: têm um limite próprio, mais largo.
app.use('/map/tiles', rateLimit({ windowMs: 60_000, limit: 2400, keyGenerator: requester, standardHeaders: true, legacyHeaders: false, message: tooMany }));
app.use(
  rateLimit({
    windowMs: 60_000,
    limit: 600,
    keyGenerator: requester,
    skip: (req) => req.path.startsWith('/map/tiles') || req.path === '/health',
    standardHeaders: true,
    legacyHeaders: false,
    message: tooMany,
  }),
);

app.get('/health', (_req, res) => {
  res.json({ ok: true, name: 'Bazá Tranquilo API' });
});
// Fotos de perfil: públicas (o app mostra-as a partir de outra origem). Só
// ficheiros do tipo "avatar" saem por aqui — os documentos são privados.
app.get('/uploads/:id', helmet.crossOriginResourcePolicy({ policy: 'cross-origin' }), async (req, res) => {
  await sendFile(res, String(req.params.id), 'avatar');
});
app.use(legalRouter);
app.use('/map', mapsRouter);
app.use('/auth', authRouter);
app.use('/me', meRouter);
app.use('/places', placesRouter);
app.use('/acompanhar', shareRouter);
app.use('/rides', safetyRouter);
app.use('/rides', ridesRouter);
app.use('/favorites', favoritesRouter);
app.use('/catalog', catalogRouter);
app.use('/vehicles', vehiclesRouter);
app.use('/documents', documentsRouter);
app.use('/painel/api', panelApi);
app.use('/painel', panelStatic);
app.use('/driver', driverRouter);
app.use('/support', supportRouter);
app.use('/notices', noticesRouter);
app.use('/agent', agentRouter);
app.use('/guardian', guardianRouter);
app.use('/intercity', intercityRouter);
app.use('/wallet', walletRouter);
app.use(() => {
  throw new HttpError(404, 'Rota não encontrada.');
});
app.use(errorHandler);

const server = createServer(app);
initRealtime(server);

await mongoose.connect(config.mongoUri);
await mongoose.syncIndexes();
await loadSettings();
await resumeSearches();
await ensureFirstAdmin();
await ensureFleetUsers();
// Alertas de perigo que nenhum agente assumiu sobem para o comando provincial.
setInterval(() => escalateStaleAlerts().catch((err) => console.error(err)), 30_000).unref();
setInterval(() => purgeOldAudio().catch((err) => console.error(err)), 3600_000).unref();
server.listen(config.port, () => {
  console.log(`Bazá API em http://localhost:${config.port} (${config.isDev ? 'desenvolvimento' : 'produção'})`);
});

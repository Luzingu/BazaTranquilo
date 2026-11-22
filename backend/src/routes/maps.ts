import { Router } from 'express';
import helmet from 'helmet';
import { config } from '../config.js';
import { HttpError } from '../http.js';

// Imagens do mapa servidas pelo nosso próprio servidor de mapas. O app pede-as
// aqui (um só endereço para tudo) e a API vai buscá-las ao servidor de mapas.
export const mapsRouter = Router();

/** O app pergunta de onde deve carregar o mapa. */
mapsRouter.get('/config', (_req, res) => {
  res.json({ ownTiles: !!config.tileUpstream });
});

mapsRouter.get(
  '/tiles/:z/:x/:y.png',
  helmet.crossOriginResourcePolicy({ policy: 'cross-origin' }),
  async (req, res) => {
    if (!config.tileUpstream) throw new HttpError(404, 'Este servidor não tem mapas próprios.');
    const { z, x, y } = req.params as Record<string, string>;
    if (![z, x, y].every((v) => /^\d{1,7}$/.test(v)) || Number(z) > 20) throw new HttpError(400, 'Pedido inválido.');
    const url = config.tileUpstream.replace('{z}', z).replace('{x}', x).replace('{y}', y);
    let upstream: Response;
    try {
      upstream = await fetch(url, { signal: AbortSignal.timeout(15_000) });
    } catch {
      throw new HttpError(502, 'Servidor de mapas indisponível.');
    }
    if (!upstream.ok) throw new HttpError(upstream.status === 404 ? 404 : 502, 'Imagem do mapa indisponível.');
    res.set('Content-Type', upstream.headers.get('content-type') ?? 'image/png');
    res.set('Cache-Control', 'public, max-age=604800');
    res.send(Buffer.from(await upstream.arrayBuffer()));
  },
);

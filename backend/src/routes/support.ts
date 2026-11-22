import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { HttpError, parse, requireAuth } from '../http.js';
import { TICKET_CATEGORIES, TicketModel, NoticeModel } from '../models/misc.js';
import { RideModel } from '../models/Ride.js';

// Ajuda e suporte no app: contactos da equipa e pedidos (objecto perdido,
// problema com uma corrida, pagamento, segurança…), respondidos no painel.
export const supportRouter = Router();
supportRouter.use(requireAuth);

const MAX_OPEN = 5;

export const ticketOut = (t: InstanceType<typeof TicketModel>) => ({
  id: t.id as string,
  category: t.category,
  message: t.message,
  rideId: t.ride ? String(t.ride) : null,
  status: t.status,
  reply: t.reply ?? null,
  repliedAt: t.repliedAt ?? null,
  createdAt: t.get('createdAt') as Date,
});

supportRouter.get('/info', (_req, res) => {
  res.json({
    email: config.legal.email || null,
    phone: config.legal.phone || null,
    emergencyNumber: config.emergencyNumber,
    cancellation: {
      graceSeconds: config.cancellation.graceMs / 1000,
      maxLate: config.cancellation.maxLate,
      suspendMinutes: config.cancellation.suspendMs / 60_000,
    },
  });
});

supportRouter.get('/tickets', async (req, res) => {
  const tickets = await TicketModel.find({ account: req.account._id }).sort({ createdAt: -1 }).limit(50);
  res.json({ tickets: tickets.map(ticketOut) });
});

supportRouter.post('/tickets', async (req, res) => {
  const body = parse(
    z.object({
      category: z.enum(TICKET_CATEGORIES),
      message: z.string().trim().min(10, 'Descreva o que aconteceu (pelo menos 10 letras).').max(1500),
      rideId: z.string().regex(/^[0-9a-f]{24}$/i).optional(),
    }),
    req.body,
  );
  if ((await TicketModel.countDocuments({ account: req.account._id, status: 'open' })) >= MAX_OPEN) {
    throw new HttpError(429, 'Já tem vários pedidos por responder. Aguarde a resposta da equipa.');
  }
  if (body.rideId) {
    const mine = req.role === 'driver' ? { driver: req.account._id } : { passenger: req.account._id };
    if (!(await RideModel.exists({ _id: body.rideId, ...mine }))) throw new HttpError(404, 'Corrida não encontrada.');
  }
  const ticket = await TicketModel.create({
    account: req.account._id,
    role: req.role,
    name: req.account.name,
    phone: req.account.phone,
    category: body.category,
    message: body.message,
    ride: body.rideId,
  });
  res.status(201).json({ ticket: ticketOut(ticket) });
});

// ── Avisos da equipa ────────────────────────────────────────────────────────
export const noticesRouter = Router();
noticesRouter.use(requireAuth);

/** Os avisos desta conta, dos mais recentes para os mais antigos. */
noticesRouter.get('/', async (req, res) => {
  const list = await NoticeModel.find({ account: req.account._id }).sort({ createdAt: -1 }).limit(50);
  res.json({
    unread: list.filter((n) => !n.readAt).length,
    notices: list.map((n) => ({
      id: n.id as string,
      title: n.title,
      message: n.message,
      read: !!n.readAt,
      createdAt: n.get('createdAt') as Date,
    })),
  });
});

/** Marca um aviso como lido ("Entendi"). */
noticesRouter.post('/:id/read', async (req, res) => {
  if (!/^[0-9a-f]{24}$/i.test(String(req.params.id))) {
    res.status(400).json({ error: 'identificador inválido' });
    return;
  }
  await NoticeModel.updateOne({ _id: req.params.id, account: req.account._id, readAt: null }, { readAt: new Date() });
  res.json({ ok: true });
});

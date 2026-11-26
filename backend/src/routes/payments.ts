import express, { Router } from 'express';
import { z } from 'zod';
import { HttpError, parse, requireAuth } from '../http.js';
import { PaymentModel } from '../models/misc.js';
import { handleWebhook, sessionView } from '../services/gateway.js';

// Sessões de pagamento (genéricas: o app mostra o que aqui vem) e as
// notificações dos fornecedores de pagamento.
export const paymentsRouter = Router();

/** Notificação do fornecedor (sem sessão: o adaptador valida a autenticidade). */
paymentsRouter.post('/webhook/:provider', express.json({ limit: '64kb' }), async (req, res) => {
  res.json(await handleWebhook(String(req.params.provider), req));
});

paymentsRouter.get('/:id', requireAuth, async (req, res) => {
  const id = parse(z.string().regex(/^[0-9a-f]{24}$/i), req.params.id);
  const payment = await PaymentModel.findOne({ _id: id, user: req.account._id, role: req.role });
  if (!payment) throw new HttpError(404, 'Pagamento não encontrado.');
  res.json({ payment: sessionView(payment) });
});

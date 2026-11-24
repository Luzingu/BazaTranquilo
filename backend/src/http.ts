import type { NextFunction, Request, Response } from 'express';
import jwt from 'jsonwebtoken';
import { z } from 'zod';
import { config } from './config.js';
import {
  GarageError,
  driverIsComplete,
  dropOfflineIfUnverified,
  findAccountById,
  type AccountDoc,
  type DriverDoc,
  type PassengerDoc,
  type Role,
} from './models/accounts.js';

export class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
    /** Campos a juntar à resposta, para o app decidir o que fazer (ex.: `otherRole`). */
    public extra?: Record<string, unknown>,
  ) {
    super(message);
  }
}

export function parse<T extends z.ZodType>(schema: T, data: unknown): z.infer<T> {
  const result = schema.safeParse(data);
  if (!result.success) {
    const issue = result.error.issues[0];
    throw new HttpError(400, `${issue?.path.join('.') || 'dados'}: ${issue?.message ?? 'inválido'}`);
  }
  return result.data;
}

declare global {
  namespace Express {
    interface Request {
      role: Role;
      account: AccountDoc;
      /** Definido nas rotas protegidas por requirePassenger. */
      passenger: PassengerDoc;
      /** Definido nas rotas protegidas por requireDriver. */
      driver: DriverDoc;
    }
  }
}

/** `version`: a `sessionVersion` da conta (0 nas contas que nunca foram recuperadas). */
export function signToken(role: Role, id: string, version = 0) {
  return jwt.sign({ sub: id, role, ...(version ? { v: version } : {}) }, config.jwtSecret, { expiresIn: '30d' });
}

export function verifyToken(token: string): { id: string; role: Role; version: number } | null {
  try {
    const p = jwt.verify(token, config.jwtSecret);
    if (typeof p !== 'object' || typeof p.sub !== 'string') return null;
    if (p.role !== 'passenger' && p.role !== 'driver') return null;
    return { id: p.sub, role: p.role, version: typeof p.v === 'number' ? p.v : 0 };
  } catch {
    return null;
  }
}

export async function requireAuth(req: Request, _res: Response, next: NextFunction) {
  const header = req.headers.authorization ?? '';
  const auth = header.startsWith('Bearer ') ? verifyToken(header.slice(7)) : null;
  const account = auth ? await findAccountById(auth.role, auth.id) : null;
  if (!auth || !account) throw new HttpError(401, 'Sessão inválida. Entre novamente.');
  // O dono do número confirmou-o por SMS e recuperou a conta: as sessões antigas caem.
  if ((account.sessionVersion ?? 0) !== auth.version || account.deactivatedAt) {
    throw new HttpError(401, 'Sessão inválida. Entre novamente.');
  }
  req.role = auth.role;
  req.account = account;
  if (auth.role === 'driver') {
    req.driver = account as DriverDoc;
    // Evita o impasse "fique offline para editar" / "complete o registo para ficar offline".
    if (dropOfflineIfUnverified(req.driver)) await req.driver.save();
  }
  else req.passenger = account as PassengerDoc;
  next();
}

export function requirePassenger(req: Request, _res: Response, next: NextFunction) {
  if (req.role !== 'passenger') throw new HttpError(403, 'Apenas para contas de passageiro.');
  next();
}

export function requireDriver(req: Request, _res: Response, next: NextFunction) {
  if (req.role !== 'driver') throw new HttpError(403, 'Apenas para contas de motorista.');
  next();
}

/** Motorista com carta de condução e viatura registadas. */
export function requireCompleteDriver(req: Request, _res: Response, next: NextFunction) {
  if (req.role !== 'driver') throw new HttpError(403, 'Apenas para contas de motorista.');
  if (!driverIsComplete(req.driver)) {
    throw new HttpError(403, 'Complete o registo: foto de perfil, carta de condução e documentos da viatura.');
  }
  next();
}

export function errorHandler(err: unknown, _req: Request, res: Response, _next: NextFunction) {
  if (err instanceof HttpError) {
    res.status(err.status).json({ ...err.extra, error: err.message });
    return;
  }
  if (err instanceof GarageError) {
    res.status(400).json({ error: err.message });
    return;
  }
  const e = err as { code?: number; name?: string; type?: string; status?: number };
  if (e?.code === 11000) {
    res.status(409).json({ error: 'Já existe uma conta com esses dados.' });
    return;
  }
  if (e?.name === 'CastError') {
    res.status(400).json({ error: 'Identificador inválido.' });
    return;
  }
  if (e?.type === 'entity.parse.failed' || e?.status === 400) {
    res.status(400).json({ error: 'Pedido inválido.' });
    return;
  }
  console.error(err);
  res.status(500).json({ error: 'Erro interno. Tente novamente.' });
}

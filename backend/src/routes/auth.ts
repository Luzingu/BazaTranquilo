import { createHmac, randomInt, timingSafeEqual } from 'node:crypto';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import express, { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { z } from 'zod';
import { SERVICE_KEYS, config } from '../config.js';
import { HttpError, parse, requireAuth, signToken } from '../http.js';
import {
  DriverModel,
  PassengerModel,
  assertPhoneFreeForRole,
  createAccount,
  findAccount,
  publicAccount,
  setLicenseData,
  setMainVehicle,
} from '../models/accounts.js';
import { MessageModel, NoticeModel, OtpModel } from '../models/misc.js';
import { ACTIVE_STATUSES, RideModel } from '../models/Ride.js';
import { deleteFile, deleteFilesOf, saveImage } from '../services/files.js';
import { settings } from '../services/settings.js';
import { agentByPhone, agentTicketFor } from './agent.js';
import { sendSms, smsIsReal, smsLooksHealthy } from '../services/sms.js';
import { dropLiveSessions } from '../services/realtime.js';

export const authRouter = Router();

// Em desenvolvimento o limite é largo, para os testes automáticos (muitas contas seguidas).
const limiter = rateLimit({ windowMs: 10 * 60_000, limit: config.isDev ? 400 : 30, standardHeaders: true, legacyHeaders: false });

/** Tipo de conta em que se está a entrar (cada número só tem um tipo). */
const role = z.enum(['passenger', 'driver']);

/** Aceita "923 456 789", "+244923456789", etc. e devolve o formato +244XXXXXXXXX. */
export function normalizePhone(raw: string) {
  let digits = raw.replace(/[^\d+]/g, '');
  if (digits.startsWith('00')) digits = `+${digits.slice(2)}`;
  if (/^9\d{8}$/.test(digits)) digits = `+244${digits}`;
  if (/^2449\d{8}$/.test(digits)) digits = `+${digits}`;
  if (!/^\+\d{9,15}$/.test(digits)) throw new HttpError(400, 'Número de telefone inválido.');
  return digits;
}

const hashCode = (key: string, code: string) =>
  createHmac('sha256', config.jwtSecret).update(`${key}:${code}`).digest('hex');

/**
 * Em desenvolvimento, sem SMS reais, o código vai na resposta para o app o
 * mostrar. Com SMS reais nunca vai: só quem tem o telemóvel o recebe.
 */
const devCode = (code: string) => (config.isDev && !smsIsReal() ? { devCode: code } : {});

/** Texto dos SMS: curto, para caber num só SMS. */
const otpText = (code: string) => `Bazá: o seu código é ${code}. Válido por 5 minutos. Não o partilhe.`;

/** Senha do app: 6 a 72 caracteres (o limite do bcrypt). */
const password = z.string().min(6, 'A senha deve ter pelo menos 6 caracteres.').max(72);
const hashPassword = (value: string) => bcrypt.hash(value, 11);

const OTP_OFF = 'Já tem conta com este número: entre com o número e a senha.';

// ── Criar conta quando o SMS falha ──────────────────────────────────────────
// Se o servidor não conseguir enviar o código a quem cria conta, a pessoa não
// fica à porta: recebe um bilhete curto, escolhe a senha e entra. A conta fica
// com o número "por confirmar" e o app pede o código mais tarde, quando o SMS
// estiver a funcionar e a pessoa não estiver numa corrida (/me/phone-confirmation).
// Quem confirmar depois o número por SMS no ecrã de entrada é o dono dele e
// recupera a conta (ver /otp/verify).
const SIGNUP_TICKET_TTL = '15m';
const signSignupTicket = (phone: string, r: 'passenger' | 'driver') =>
  jwt.sign({ sub: phone, signupRole: r }, config.jwtSecret, { expiresIn: SIGNUP_TICKET_TTL });
function readSignupTicket(token: string): { phone: string; role: 'passenger' | 'driver' } | null {
  try {
    const p = jwt.verify(token, config.jwtSecret);
    if (typeof p !== 'object' || typeof p.sub !== 'string') return null;
    if (p.signupRole !== 'passenger' && p.signupRole !== 'driver') return null;
    return { phone: p.sub, role: p.signupRole };
  } catch {
    return null;
  }
}

/** O SMS falhou do lado do servidor ou da operadora (não por erro de quem o pediu). */
const smsFailedOnOurSide = (err: unknown) => {
  const status = err instanceof HttpError ? err.status : 500;
  return status >= 500;
};

/** O que o ecrã de entrada do app precisa de saber antes de pedir dados. */
authRouter.get('/options', (_req, res) => {
  res.json({ otp: settings.otpEnabled });
});

authRouter.post('/otp/request', limiter, async (req, res) => {
  const body = parse(z.object({ phone: z.string().min(6).max(20), role }), req.body);
  const phone = normalizePhone(body.phone);
  if (await agentByPhone(phone)) throw new HttpError(409, 'Este número não pode ser usado aqui.');
  if (!(await findAccount(body.role, { phone }))) await assertPhoneFreeForRole(body.role, phone);
  // Com o código desligado no painel, o SMS só serve para confirmar o número de
  // quem cria conta (ou de quem ainda não tem senha); os restantes usam a senha.
  if (!settings.otpEnabled && (await findAccount(body.role, { phone }))?.passwordHash) {
    throw new HttpError(403, OTP_OFF);
  }
  const key = `${body.role}:${phone}`;
  const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
  await sendSms(phone, otpText(code));
  await OtpModel.findOneAndUpdate(
    { key },
    { codeHash: hashCode(key, code), attempts: 0, expiresAt: new Date(Date.now() + config.otpTtlMs) },
    { upsert: true },
  );
  res.json({ phone, ...devCode(code) });
});

/**
 * Primeiro passo da entrada no app: o servidor decide se pede o código SMS ou a
 * senha. O utilizador não escolhe — a regra vem do painel:
 * - código ligado: envia o SMS; se o envio falhar e a conta tiver senha, pede a senha;
 * - código desligado: quem tem senha entra com ela; quem cria conta (ou ainda
 *   não tem senha) recebe sempre o código, para confirmar o número.
 * Com `noCode` (o app esperou e o código não foi introduzido) não reenvia nada:
 * só diz se esta conta pode entrar com a senha.
 */
authRouter.post('/start', limiter, async (req, res) => {
  const body = parse(z.object({ phone: z.string().min(6).max(20), role, noCode: z.boolean().optional() }), req.body);
  const phone = normalizePhone(body.phone);
  // Número de um agente de um posto policial: entra sempre com o código SMS (e
  // depois a senha), seja qual for o tipo de conta escolhido no ecrã. A resposta
  // é igual à dos outros utilizadores, para o número não se distinguir.
  if (await agentByPhone(phone)) {
    if (body.noCode) {
      res.json({ phone, method: 'otp', via: config.otpChannelLabel });
      return;
    }
    const key = `agent:${phone}`;
    const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
    await sendSms(phone, otpText(code));
    await OtpModel.findOneAndUpdate(
      { key },
      { codeHash: hashCode(key, code), attempts: 0, expiresAt: new Date(Date.now() + config.otpTtlMs) },
      { upsert: true },
    );
    res.json({ phone, method: 'otp', via: config.otpChannelLabel, canUsePassword: false, ...devCode(code) });
    return;
  }
  const existing = await findAccount(body.role, { phone });
  // Um número, um só tipo de conta: avisa antes de gastar um SMS, e o app
  // oferece a troca para o tipo certo (`otherRole`).
  if (!existing) await assertPhoneFreeForRole(body.role, phone);
  const hasPassword = Boolean(existing?.passwordHash);
  if (body.noCode) {
    res.json({ phone, method: hasPassword ? 'password' : 'otp' });
    return;
  }
  if (!settings.otpEnabled && hasPassword) {
    res.json({ phone, method: 'password', reason: 'otp_off' });
    return;
  }
  const key = `${body.role}:${phone}`;
  const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
  try {
    await sendSms(phone, otpText(code));
  } catch (err) {
    // O SMS falhou (operadora, saldo, demasiados pedidos): quem tem senha entra com ela.
    const status = err instanceof HttpError ? err.status : 500;
    if (hasPassword && (status >= 500 || status === 429)) {
      res.json({ phone, method: 'password', reason: 'sms_failed' });
      return;
    }
    // Conta nova e o SMS não saiu: cria-se na mesma, com o número por confirmar.
    if (!existing && smsFailedOnOurSide(err)) {
      res.json({ phone, method: 'signup', reason: 'sms_failed', signupTicket: signSignupTicket(phone, body.role) });
      return;
    }
    throw err;
  }
  await OtpModel.findOneAndUpdate(
    { key },
    { codeHash: hashCode(key, code), attempts: 0, expiresAt: new Date(Date.now() + config.otpTtlMs) },
    { upsert: true },
  );
  // `canUsePassword`: o ecrã do código oferece também a entrada com a senha.
  res.json({ phone, method: 'otp', via: config.otpChannelLabel, canUsePassword: hasPassword, ...devCode(code) });
});

authRouter.post('/otp/verify', limiter, async (req, res) => {
  const body = parse(
    z.object({ phone: z.string().min(6).max(20), code: z.string().regex(/^\d{6}$/), role }),
    req.body,
  );
  const phone = normalizePhone(body.phone);
  const agent = await agentByPhone(phone);
  const key = agent ? `agent:${phone}` : `${body.role}:${phone}`;
  const otp = await OtpModel.findOneAndUpdate(
    { key, expiresAt: { $gt: new Date() }, attempts: { $lt: config.otpMaxAttempts } },
    { $inc: { attempts: 1 } },
  );
  if (!otp) throw new HttpError(400, 'Código expirado. Peça um novo.');
  const expected = Buffer.from(otp.codeHash, 'hex');
  const given = Buffer.from(hashCode(key, body.code), 'hex');
  if (!timingSafeEqual(expected, given)) throw new HttpError(400, 'Código incorrecto.');
  await otp.deleteOne();
  // Agente: o código só dá um bilhete; a sessão abre-se a seguir, com a senha.
  if (agent) {
    res.json(agentTicketFor(agent));
    return;
  }

  let account = await findAccount(body.role, { phone });
  const isNew = !account;
  if (!account) await assertPhoneFreeForRole(body.role, phone);
  account ??= await createAccount(body.role, { phone });
  // Conta criada sem o SMS chegar: quem acabou de receber o código é o dono do
  // número. A conta passa a confirmada, as sessões abertas noutros aparelhos caem
  // e a senha volta a ser definida — se alguém criou a conta com o número de
  // outra pessoa, perde-lhe o acesso.
  let recovered = false;
  if (account.phoneVerified === false) {
    account.phoneVerified = true;
    account.passwordHash = undefined;
    account.sessionVersion = (account.sessionVersion ?? 0) + 1;
    await account.save();
    dropLiveSessions(account.id);
    recovered = true;
  }
  res.json({
    ...(recovered ? { phoneRecovered: true } : {}),
    token: signToken(body.role, account.id, account.sessionVersion),
    user: publicAccount(body.role, account),
    isNew,
  });
});

// ── Entrar com o número e a senha ───────────────────────────────────────────
// Serve quando o código SMS está desligado no painel ou não chega. A senha
// define-se ao criar a conta. O login por email continua descontinuado.

/** Tentativas de senha por número: trava quem tenta adivinhar a senha de alguém. */
const passwordLimiter = rateLimit({
  windowMs: 15 * 60_000,
  limit: config.isDev ? 200 : 10,
  standardHeaders: true,
  legacyHeaders: false,
  skipSuccessfulRequests: true,
  keyGenerator: (req) => `senha:${String(req.body?.role)}:${String(req.body?.phone).replace(/\D/g, '').slice(-9)}`,
  message: { error: 'Demasiadas tentativas. Aguarde 15 minutos ou entre com o código SMS.' },
});

const signedIn = (r: 'passenger' | 'driver', account: Parameters<typeof publicAccount>[1], isNew = false) => ({
  token: signToken(r, account.id, account.sessionVersion),
  user: publicAccount(r, account),
  isNew,
});

authRouter.post('/password/login', limiter, passwordLimiter, async (req, res) => {
  const body = parse(z.object({ phone: z.string().min(6).max(20), role, password: z.string().min(1).max(72) }), req.body);
  const account = await findAccount(body.role, { phone: normalizePhone(body.phone) });
  // A mesma resposta para "não existe" e "senha errada": não revela que números têm conta.
  const ok = account?.passwordHash ? await bcrypt.compare(body.password, account.passwordHash) : false;
  if (!account || !ok) {
    throw new HttpError(
      401,
      settings.otpEnabled
        ? 'Número ou senha incorrectos. Se ainda não definiu uma senha, entre com o código SMS.'
        : 'Número ou senha incorrectos.',
    );
  }
  res.json(signedIn(body.role, account));
});

/**
 * Criar conta sem o código: só com o bilhete que /start dá quando o SMS falha.
 * A senha é obrigatória (é a única forma de voltar a entrar até o número ser
 * confirmado).
 */
authRouter.post('/signup', limiter, async (req, res) => {
  const body = parse(z.object({ ticket: z.string().min(10).max(2000), password }), req.body);
  const ticket = readSignupTicket(body.ticket);
  if (!ticket) throw new HttpError(400, 'O pedido expirou. Volte a escrever o seu número.');
  if (await agentByPhone(ticket.phone)) throw new HttpError(409, 'Este número não pode ser usado aqui.');
  if (await findAccount(ticket.role, { phone: ticket.phone })) {
    throw new HttpError(409, 'Já existe uma conta com este número. Volte atrás e entre com a senha.');
  }
  await assertPhoneFreeForRole(ticket.role, ticket.phone);
  const account = await createAccount(ticket.role, {
    phone: ticket.phone,
    passwordHash: await hashPassword(body.password),
    phoneVerified: false,
  });
  console.log(`Conta criada com o número por confirmar (${ticket.role}): o SMS falhou.`);
  res.json(signedIn(ticket.role, account, true));
});

// Criar conta: confirma-se o número por SMS (rota /otp) e a senha define-se a
// seguir, em PUT /me/password. Se o SMS falhar, /start dá um bilhete para /signup.
authRouter.post('/password/register', () => {
  throw new HttpError(410, 'Para criar conta, confirme o número com o código SMS.');
});

/** Senha esquecida: confirma-se o número por SMS e escolhe-se outra. */
authRouter.post('/password/forgot', limiter, async (req, res) => {
  const body = parse(z.object({ phone: z.string().min(6).max(20), role }), req.body);
  if (!settings.otpEnabled) {
    throw new HttpError(403, 'De momento não é possível repor a senha por SMS. Contacte o suporte do Bazá.');
  }
  const phone = normalizePhone(body.phone);
  const key = `reset:${body.role}:${phone}`;
  const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
  // Só se envia SMS a números com conta, mas a resposta é igual nos dois casos.
  if (await findAccount(body.role, { phone })) {
    await sendSms(phone, otpText(code));
    await OtpModel.findOneAndUpdate(
      { key },
      { codeHash: hashCode(key, code), attempts: 0, expiresAt: new Date(Date.now() + config.otpTtlMs) },
      { upsert: true },
    );
  }
  res.json({ phone, ...devCode(code) });
});

authRouter.post('/password/reset', limiter, async (req, res) => {
  const body = parse(
    z.object({ phone: z.string().min(6).max(20), role, code: z.string().regex(/^\d{6}$/), password }),
    req.body,
  );
  const phone = normalizePhone(body.phone);
  const key = `reset:${body.role}:${phone}`;
  const otp = await OtpModel.findOneAndUpdate(
    { key, expiresAt: { $gt: new Date() }, attempts: { $lt: config.otpMaxAttempts } },
    { $inc: { attempts: 1 } },
  );
  if (!otp) throw new HttpError(400, 'Código expirado. Peça um novo.');
  const expected = Buffer.from(otp.codeHash, 'hex');
  const given = Buffer.from(hashCode(key, body.code), 'hex');
  if (!timingSafeEqual(expected, given)) throw new HttpError(400, 'Código incorrecto.');
  await otp.deleteOne();
  const account = await findAccount(body.role, { phone });
  if (!account) throw new HttpError(400, 'Código expirado. Peça um novo.');
  account.passwordHash = await hashPassword(body.password);
  // O código chegou: o número fica confirmado e quem o tinha usado sem ser dono perde a sessão.
  if (account.phoneVerified === false) {
    account.phoneVerified = true;
    account.sessionVersion = (account.sessionVersion ?? 0) + 1;
    dropLiveSessions(account.id);
  }
  await account.save();
  res.json(signedIn(body.role, account));
});

const emailLoginGone = () => {
  throw new HttpError(410, 'O login por email foi descontinuado. Entre com o seu número de telefone.');
};
authRouter.post('/register', emailLoginGone);
authRouter.post('/login', emailLoginGone);

export const meRouter = Router();
meRouter.use(requireAuth);

meRouter.get('/', (req, res) => {
  res.json({ user: publicAccount(req.role, req.account) });
});

meRouter.patch('/', async (req, res) => {
  const body = parse(
    z.object({
      name: z.string().trim().min(2).max(80).optional(),
      email: z.email().optional(),
      /** null remove o contacto de emergência. */
      emergencyContact: z
        .object({ name: z.string().trim().min(1).max(60), phone: z.string().trim().min(6).max(20) })
        .nullable()
        .optional(),
      vehicle: z
        .object({
          make: z.string().trim().min(1).max(40),
          carModel: z.string().trim().min(1).max(40),
          color: z.string().trim().min(1).max(30),
          plate: z.string().trim().min(3).max(15),
          category: z.enum(SERVICE_KEYS),
          hasAC: z.boolean().optional(),
          insuranceExpiresAt: z.coerce.date().optional(),
        })
        .optional(),
      license: z
        .object({
          number: z.string().trim().min(4).max(30),
          category: z.string().trim().min(1).max(10),
          expiresAt: z.coerce.date(),
        })
        .optional(),
    }),
    req.body,
  );
  if (body.name) req.account.name = body.name;
  if (body.emergencyContact === null) req.account.emergencyContact = undefined;
  else if (body.emergencyContact) {
    req.account.emergencyContact = {
      name: body.emergencyContact.name,
      phone: normalizePhone(body.emergencyContact.phone),
    };
  }
  if (body.email) {
    const email = body.email.toLowerCase();
    const other = await findAccount(req.role, { email });
    if (other && other.id !== req.account.id) {
      throw new HttpError(409, 'Esse email já está a ser usado por outra conta.');
    }
    req.account.email = email;
  }
  if (body.vehicle || body.license) {
    if (req.role !== 'driver') throw new HttpError(403, 'Apenas para contas de motorista.');
    if (body.license && body.license.expiresAt.getTime() < Date.now()) {
      throw new HttpError(400, 'A carta de condução está caducada.');
    }
    if (body.vehicle) {
      if (req.driver.isOnline) throw new HttpError(409, 'Fique offline para alterar a viatura.');
      setMainVehicle(req.driver, { ...body.vehicle, plate: body.vehicle.plate.toUpperCase() });
    }
    if (body.license) setLicenseData(req.driver, body.license);
  }
  await req.account.save();
  res.json({ user: publicAccount(req.role, req.account) });
});

/**
 * Definir ou mudar a senha. Quem ainda não tem senha (conta criada por código
 * SMS) define-a sem mais; quem já tem, confirma a actual.
 */
meRouter.put('/password', limiter, async (req, res) => {
  const body = parse(z.object({ password, current: z.string().max(72).optional() }), req.body);
  if (req.account.passwordHash) {
    const ok = body.current ? await bcrypt.compare(body.current, req.account.passwordHash) : false;
    if (!ok) throw new HttpError(400, 'A senha actual não está correcta.');
  }
  req.account.passwordHash = await hashPassword(body.password);
  await req.account.save();
  res.json({ user: publicAccount(req.role, req.account) });
});

/** Foto de perfil: o corpo do pedido é a própria imagem (JPEG, PNG ou WebP, até 3 MB). */
meRouter.put('/photo', express.raw({ type: () => true, limit: '3mb' }), async (req, res) => {
  const file = await saveImage(req.body, 'avatar', req.account.id);
  const previous = req.account.photo;
  req.account.photo = file;
  await req.account.save();
  await deleteFile(previous);
  res.json({ user: publicAccount(req.role, req.account) });
});

meRouter.delete('/photo', async (req, res) => {
  if (req.role === 'driver') {
    throw new HttpError(400, 'A foto de perfil é obrigatória para motoristas. Pode substituí-la por outra.');
  }
  const previous = req.account.photo;
  req.account.photo = undefined;
  await req.account.save();
  await deleteFile(previous);
  res.json({ user: publicAccount(req.role, req.account) });
});

// ── Notificações push: registar e remover este dispositivo ──────────────────
const pushToken = z.object({ token: z.string().min(20).max(4096) });

meRouter.put('/push-token', async (req, res) => {
  const { token } = parse(pushToken, req.body);
  // Um dispositivo avisa uma só conta: a que está com sessão iniciada nele.
  await PassengerModel.updateMany({ pushTokens: token }, { $pull: { pushTokens: token } });
  await DriverModel.updateMany({ pushTokens: token }, { $pull: { pushTokens: token } });
  await req.account.updateOne({ $addToSet: { pushTokens: token } });
  res.json({ ok: true });
});

meRouter.post('/push-token/remove', async (req, res) => {
  const { token } = parse(pushToken, req.body);
  await req.account.updateOne({ $pull: { pushTokens: token } });
  res.json({ ok: true });
});

// ── Eliminar a conta ────────────────────────────────────────────────────────
// Apaga os dados pessoais (nome, telefone, fotos, documentos, locais guardados).
// As corridas já feitas ficam, sem ligação à pessoa, para as contas do outro
// interveniente e para as obrigações legais do serviço.
meRouter.delete('/', async (req, res) => {
  const id = req.account._id;
  const mine = req.role === 'driver' ? { driver: id } : { passenger: id };
  if (await RideModel.exists({ ...mine, status: { $in: ACTIVE_STATUSES } })) {
    throw new HttpError(409, 'Tem uma corrida em curso. Termine-a ou cancele-a antes de eliminar a conta.');
  }
  await deleteFilesOf(req.account.id);
  await NoticeModel.deleteMany({ account: id });
  // Mensagens que esta pessoa escreveu no chat das suas corridas.
  const rideIds = await RideModel.find(mine).distinct('_id');
  await MessageModel.deleteMany({ ride: { $in: rideIds }, role: req.role });
  if (req.role === 'driver') {
    await PassengerModel.updateMany({ favoriteDrivers: id }, { $pull: { favoriteDrivers: id } });
    await DriverModel.deleteOne({ _id: id });
  } else {
    await PassengerModel.deleteOne({ _id: id });
  }
  console.log(`Conta eliminada a pedido do titular (${req.role}).`);
  res.json({ ok: true });
});

// ── Alterar o telefone: só depois de confirmar o número novo por SMS ────────
meRouter.post('/phone/request', limiter, async (req, res) => {
  const body = parse(z.object({ phone: z.string().min(6).max(20) }), req.body);
  const phone = normalizePhone(body.phone);
  if (phone === req.account.phone) throw new HttpError(400, 'Esse já é o seu número.');
  if (await agentByPhone(phone)) throw new HttpError(409, 'Esse número já está a ser usado por outra conta.');
  const other = await findAccount(req.role, { phone });
  if (other) throw new HttpError(409, 'Esse número já está a ser usado por outra conta.');
  await assertPhoneFreeForRole(req.role, phone, 'Esse número já está a ser usado por outra conta.');
  const key = `change:${req.role}:${req.account.id}:${phone}`;
  const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
  await sendSms(phone, otpText(code));
  await OtpModel.findOneAndUpdate(
    { key },
    { codeHash: hashCode(key, code), attempts: 0, expiresAt: new Date(Date.now() + config.otpTtlMs) },
    { upsert: true },
  );
  res.json({ phone, ...devCode(code) });
});

meRouter.post('/phone/verify', limiter, async (req, res) => {
  const body = parse(
    z.object({ phone: z.string().min(6).max(20), code: z.string().regex(/^\d{6}$/) }),
    req.body,
  );
  const phone = normalizePhone(body.phone);
  const key = `change:${req.role}:${req.account.id}:${phone}`;
  const otp = await OtpModel.findOneAndUpdate(
    { key, expiresAt: { $gt: new Date() }, attempts: { $lt: config.otpMaxAttempts } },
    { $inc: { attempts: 1 } },
  );
  if (!otp) throw new HttpError(400, 'Código expirado. Peça um novo.');
  const expected = Buffer.from(otp.codeHash, 'hex');
  const given = Buffer.from(hashCode(key, body.code), 'hex');
  if (!timingSafeEqual(expected, given)) throw new HttpError(400, 'Código incorrecto.');
  await otp.deleteOne();
  // Pode ter sido registado noutro tipo de conta entre o pedido e a confirmação.
  await assertPhoneFreeForRole(req.role, phone, 'Esse número já está a ser usado por outra conta.');
  req.account.phone = phone;
  req.account.phoneVerified = true;
  await req.account.save(); // o índice único trava números repetidos
  res.json({ user: publicAccount(req.role, req.account) });
});


// ── Confirmar o número mais tarde (contas criadas quando o SMS falhou) ──────
// O app pergunta aqui se é boa altura para pedir o código. Só é quando o envio
// de SMS parece estar a funcionar e a pessoa não está numa corrida (nem, sendo
// motorista, online à espera de pedidos: não se mete um código à frente de uma
// corrida a chegar).

type ConfirmBlock = 'sms_down' | 'in_ride' | 'online';

async function confirmationBlock(req: express.Request): Promise<ConfirmBlock | null> {
  const mine = req.role === 'driver' ? { driver: req.account._id } : { passenger: req.account._id };
  if (await RideModel.exists({ ...mine, status: { $in: ACTIVE_STATUSES } })) return 'in_ride';
  if (req.role === 'driver' && req.driver.isOnline) return 'online';
  if (!(await smsLooksHealthy())) return 'sms_down';
  return null;
}

const confirmKey = (req: express.Request) => `confirm:${req.role}:${req.account.id}`;

meRouter.get('/phone-confirmation', async (req, res) => {
  if (req.account.phoneVerified !== false) {
    res.json({ verified: true, canAskNow: false });
    return;
  }
  const block = await confirmationBlock(req);
  res.json({ verified: false, canAskNow: !block, ...(block ? { reason: block } : {}), phone: req.account.phone });
});

meRouter.post('/phone-confirmation/request', limiter, async (req, res) => {
  if (req.account.phoneVerified !== false) throw new HttpError(400, 'O seu número já está confirmado.');
  if (!req.account.phone) throw new HttpError(400, 'A conta não tem número de telefone.');
  const block = await confirmationBlock(req);
  if (block === 'in_ride') throw new HttpError(409, 'Termine a corrida primeiro: confirmamos o número a seguir.');
  if (block === 'online') throw new HttpError(409, 'Fique offline para confirmar o número.');
  const key = confirmKey(req);
  const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
  // Mesmo que o estado do SMS pareça mau, deixa-se tentar quando é a pessoa a pedir.
  await sendSms(req.account.phone, otpText(code));
  await OtpModel.findOneAndUpdate(
    { key },
    { codeHash: hashCode(key, code), attempts: 0, expiresAt: new Date(Date.now() + config.otpTtlMs) },
    { upsert: true },
  );
  res.json({ phone: req.account.phone, ...devCode(code) });
});

meRouter.post('/phone-confirmation/verify', limiter, async (req, res) => {
  const body = parse(z.object({ code: z.string().regex(/^\d{6}$/) }), req.body);
  const key = confirmKey(req);
  const otp = await OtpModel.findOneAndUpdate(
    { key, expiresAt: { $gt: new Date() }, attempts: { $lt: config.otpMaxAttempts } },
    { $inc: { attempts: 1 } },
  );
  if (!otp) throw new HttpError(400, 'Código expirado. Peça um novo.');
  const expected = Buffer.from(otp.codeHash, 'hex');
  const given = Buffer.from(hashCode(key, body.code), 'hex');
  if (!timingSafeEqual(expected, given)) throw new HttpError(400, 'Código incorrecto.');
  await otp.deleteOne();
  req.account.phoneVerified = true;
  await req.account.save();
  res.json({ user: publicAccount(req.role, req.account) });
});

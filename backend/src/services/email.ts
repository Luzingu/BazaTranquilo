import nodemailer, { type Transporter } from 'nodemailer';
import { config } from '../config.js';

// Envio de e-mail. Canal principal: SMTP; reserva: um Web App do Google Apps
// Script (só HTML, sem escolher remetente). Sem nada configurado, em
// desenvolvimento, o e-mail é só escrito no log.

/** true quando os e-mails são mesmo enviados. */
export const emailIsReal = () => config.mail.transport === 'smtp' && !!config.mail.smtpUser;

let transporter: Transporter | null = null;
function smtp() {
  transporter ??= nodemailer.createTransport({
    host: config.mail.smtpHost,
    port: config.mail.smtpPort,
    secure: config.mail.smtpPort === 465, // SSL implícito na 465; STARTTLS na 587
    auth: { user: config.mail.smtpUser, pass: config.mail.smtpPass },
    connectionTimeout: config.mail.timeoutMs,
    greetingTimeout: config.mail.timeoutMs,
    socketTimeout: config.mail.timeoutMs,
  });
  return transporter;
}

/** Confirma a ligação e as credenciais SMTP, sem enviar nada. */
export async function verifyEmailConnection(): Promise<boolean> {
  if (!emailIsReal()) return false;
  try {
    await smtp().verify();
    return true;
  } catch (err) {
    console.warn('[email] verificação SMTP falhou:', (err as Error).name);
    return false;
  }
}

const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

/** Modelo base dos e-mails do Bazá. `body` é HTML já seguro. */
export function emailLayout(title: string, body: string) {
  return `<!doctype html><html lang="pt"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body style="margin:0;background:#f4f5f7;font-family:Arial,Helvetica,sans-serif;color:#14161a">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f5f7;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#ffffff;border-radius:14px;overflow:hidden">
<tr><td style="background:#ffc400;padding:18px 24px"><div style="font-size:24px;font-weight:bold">Bazá <span style="font-weight:normal">Tranquilo</span></div><div style="font-size:13px;margin-top:2px">Bazá com Segurança</div></td></tr>
<tr><td style="padding:24px"><h1 style="margin:0 0 12px;font-size:20px">${esc(title)}</h1>${body}</td></tr>
<tr><td style="padding:16px 24px;border-top:1px solid #e5e7eb;color:#6b7280;font-size:12px">Recebeu este e-mail por ter uma conta no Bazá Tranquilo. Se não reconhece este pedido, ignore a mensagem.</td></tr>
</table></td></tr></table></body></html>`;
}

/** Parágrafo de texto simples (escapado) para usar no corpo. */
export const p = (text: string) => `<p style="margin:0 0 12px;font-size:15px;line-height:1.5">${esc(text)}</p>`;
/** Código em destaque, para copiar. */
export const codeBlock = (code: string) =>
  `<p style="margin:16px 0;font-size:32px;font-weight:bold;letter-spacing:6px;background:#f4f5f7;border-radius:10px;padding:14px;text-align:center">${esc(code)}</p>`;

async function sendViaAppsScript(to: string, subject: string, html: string): Promise<boolean> {
  if (!config.mail.serviceUrl) return false;
  const query = new URLSearchParams({ senha: config.mail.servicePass, email: to, assunto: subject, corpoHtml: html });
  // Os dados vão no endereço: corpos longos falham, por isso nem se tenta.
  if (query.toString().length > 6000) return false;
  try {
    const res = await fetch(`${config.mail.serviceUrl}?${query}`, { redirect: 'follow', signal: AbortSignal.timeout(30_000) });
    return (await res.text()).toLowerCase().includes('sucesso');
  } catch {
    return false;
  }
}

/**
 * Envia um e-mail HTML. Devolve false se falhar (sem excepção): quem chama
 * decide o que fazer. No log fica só o destino e o resultado — nunca senhas
 * nem o conteúdo.
 */
export async function sendEmail(to: string, subject: string, html: string): Promise<boolean> {
  if (!to) return false;
  if (!emailIsReal()) {
    if (config.isDev) console.log(`[e-mail simulado → ${to}] ${subject}`);
    return config.isDev;
  }
  try {
    await smtp().sendMail({
      from: { name: config.mail.fromName, address: config.mail.from },
      to,
      subject,
      html,
      text: 'Abra esta mensagem num leitor de e-mail com HTML.',
    });
    console.log(`[email] ${to} → enviado por SMTP`);
    return true;
  } catch (err) {
    console.warn(`[email] ${to} → SMTP falhou (${(err as Error).name}); a tentar a reserva`);
  }
  const ok = await sendViaAppsScript(to, subject, html);
  console.log(`[email] ${to} → reserva ${ok ? 'enviou' : 'falhou'}`);
  return ok;
}

/** Envia sem esperar nem falhar o pedido: para avisos que não são críticos. */
export function notifyByEmail(to: string | null | undefined, subject: string, html: string) {
  if (to) void sendEmail(to, subject, html).catch(() => false);
}

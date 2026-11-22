import type { Response } from 'express';
import mongoose from 'mongoose';
import { HttpError } from '../http.js';

// Os ficheiros (fotos de perfil e documentos dos motoristas) ficam guardados
// no próprio MongoDB, em GridFS: colecções `fs.files` e `fs.chunks`.

/** "avatar" pode ser visto por qualquer pessoa; "document" é privado. */
export type FileKind = 'avatar' | 'document' | 'audio';

const bucket = () => new mongoose.mongo.GridFSBucket(mongoose.connection.db!);

const CONTENT_TYPES = { jpg: 'image/jpeg', png: 'image/png', webp: 'image/webp' } as const;

/** Reconhece o formato pelos primeiros bytes, sem confiar no que o cliente declara. */
export function imageExtension(data: Buffer): keyof typeof CONTENT_TYPES | null {
  if (data.length < 12) return null;
  if (data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff) return 'jpg';
  if (data.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'png';
  if (data.toString('latin1', 0, 4) === 'RIFF' && data.toString('latin1', 8, 12) === 'WEBP') return 'webp';
  return null;
}

/**
 * Guarda um bloco de som (WAV) de um alerta de perigo e devolve o seu id. O
 * "dono" é o alerta, não a conta: o som só sai pelo alerta a que pertence.
 */
export async function saveAudio(body: unknown, owner: string): Promise<string> {
  const ok = Buffer.isBuffer(body) && body.length > 44 && body.toString('latin1', 0, 4) === 'RIFF' && body.toString('latin1', 8, 12) === 'WAVE';
  if (!ok) throw new HttpError(400, 'Som inválido.');
  const upload = bucket().openUploadStream('audio.wav', { metadata: { kind: 'audio', owner, contentType: 'audio/wav' } });
  await new Promise<void>((resolve, reject) => {
    upload.once('finish', () => resolve());
    upload.once('error', reject);
    upload.end(body as Buffer);
  });
  return upload.id.toString();
}

/** Guarda uma imagem enviada no corpo do pedido e devolve o seu id. */
export async function saveImage(body: unknown, kind: FileKind, owner: string): Promise<string> {
  const ext = Buffer.isBuffer(body) ? imageExtension(body) : null;
  if (!Buffer.isBuffer(body) || !ext) throw new HttpError(400, 'Envie uma fotografia JPEG, PNG ou WebP.');
  const upload = bucket().openUploadStream(`${kind}.${ext}`, {
    metadata: { kind, owner, contentType: CONTENT_TYPES[ext] },
  });
  await new Promise<void>((resolve, reject) => {
    upload.once('finish', () => resolve());
    upload.once('error', reject);
    upload.end(body);
  });
  return upload.id.toString();
}

const toId = (id?: string | null) =>
  id && mongoose.isValidObjectId(id) ? new mongoose.Types.ObjectId(id) : null;

export async function deleteFile(id?: string | null) {
  const _id = toId(id);
  if (_id) await bucket().delete(_id).catch(() => {});
}

/** Apaga todos os ficheiros (foto e documentos) de uma conta. */
export async function deleteFilesOf(owner: string) {
  const files = await bucket().find({ 'metadata.owner': owner }).toArray();
  for (const f of files) await bucket().delete(f._id).catch(() => {});
  return files.length;
}

/**
 * Envia um ficheiro na resposta. `kind` tem de coincidir com o tipo guardado:
 * é o que impede pedir um documento privado pela rota pública das fotos.
 */
export async function sendFile(res: Response, id: string | null | undefined, kind: FileKind) {
  const _id = toId(id);
  const file = _id ? await bucket().find({ _id }).next() : null;
  if (!file || file.metadata?.kind !== kind) throw new HttpError(404, 'Ficheiro não encontrado.');
  res.set('Content-Type', String(file.metadata?.contentType ?? 'application/octet-stream'));
  res.set('Content-Length', String(file.length));
  res.set('Cache-Control', kind === 'avatar' ? 'public, max-age=2592000, immutable' : 'private, no-store');
  await new Promise<void>((resolve, reject) => {
    bucket().openDownloadStream(file._id).once('error', reject).once('end', resolve).pipe(res);
  });
}

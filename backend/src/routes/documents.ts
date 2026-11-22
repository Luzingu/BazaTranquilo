import express, { Router, type Request, type Response } from 'express';
import { z } from 'zod';
import { HttpError, parse, requireAuth, requireDriver } from '../http.js';
import {
  documentFile,
  publicAccount,
  setLicensePhoto,
  setVehicleDocument,
} from '../models/accounts.js';
import { deleteFile, saveImage, sendFile } from '../services/files.js';

// As fotos dos documentos (carta de condução, livrete) são dados pessoais:
// ficam no MongoDB (GridFS) marcadas como privadas e só saem por estas rotas,
// para o próprio motorista (e, no painel web, para o administrador que os revê).

const objectId = z.string().regex(/^[0-9a-f]{24}$/i, 'identificador inválido');
const rawImage = express.raw({ type: () => true, limit: '8mb' });

const storeImage = (req: Request) => saveImage(req.body, 'document', req.driver.id);
const discard = deleteFile;
const sendDocument = (res: Response, file: string | null) => sendFile(res, file, 'document');

// ── Motorista: enviar e ver os seus documentos ──────────────────────────────
export const documentsRouter = Router();
documentsRouter.use(requireAuth, requireDriver);

const side = z.enum(['front', 'back']);

documentsRouter.put('/license/:side', rawImage, async (req, res) => {
  const which = parse(side, req.params.side);
  const file = await storeImage(req);
  let previous: string | null;
  try {
    previous = setLicensePhoto(req.driver, which, file);
    await req.driver.save();
  } catch (err) {
    await discard(file);
    throw err;
  }
  await discard(previous);
  res.json({ user: publicAccount('driver', req.driver) });
});

documentsRouter.get('/license/:side', async (req, res) => {
  await sendDocument(res, documentFile(req.driver, { license: parse(side, req.params.side) }));
});

/** Foto de um documento de uma viatura: livrete, título de propriedade ou seguro. */
const vehicleDoc = z.enum(['registration', 'ownership', 'insurance']);

documentsRouter.put('/vehicles/:id/:doc', rawImage, async (req, res) => {
  const vehicleId = parse(objectId, req.params.id);
  const doc = parse(vehicleDoc, req.params.doc);
  const file = await storeImage(req);
  let previous: string | null;
  try {
    previous = setVehicleDocument(req.driver, vehicleId, doc, file);
    await req.driver.save();
  } catch (err) {
    await discard(file);
    throw err;
  }
  await discard(previous);
  res.json({ user: publicAccount('driver', req.driver) });
});

documentsRouter.get('/vehicles/:id/:doc', async (req, res) => {
  await sendDocument(
    res,
    documentFile(req.driver, { vehicleId: parse(objectId, req.params.id), doc: parse(vehicleDoc, req.params.doc) }),
  );
});

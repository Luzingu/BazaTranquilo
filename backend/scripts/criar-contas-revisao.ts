// Contas para a revisão da Google Play (pedido do dono, 2026-11-26): um
// passageiro e um motorista já aprovado, que entram só com o número e a senha
// (os números estão em REVIEW_PHONES no .env: o servidor nunca lhes envia SMS).
// As fotos dos documentos do motorista são a imagem de partilha do site.
//
//   cd backend && npx tsx scripts/criar-contas-revisao.ts
// Correr de novo gera senhas novas (e mantém as contas). As senhas só aparecem aqui.
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import bcrypt from 'bcryptjs';
import mongoose from 'mongoose';
import { config } from '../src/config.js';
import { DriverModel, PassengerModel } from '../src/models/accounts.js';
import { saveImage } from '../src/services/files.js';

const [passengerPhone, driverPhone] = config.reviewPhones;
if (!passengerPhone || !driverPhone) throw new Error('Defina REVIEW_PHONES no .env (passageiro,motorista).');
await mongoose.connect(config.mongoUri);
const pass = () => `Baza-${randomBytes(4).toString('hex')}`;
const png = readFileSync(new URL('../../site/og.png', import.meta.url));

const pPass = pass();
await PassengerModel.updateOne(
  { phone: passengerPhone },
  { $set: { name: 'Revisão Google (passageiro)', phoneVerified: true, passwordHash: await bcrypt.hash(pPass, 11) }, $inc: { sessionVersion: 1 } },
  { upsert: true },
);

const dPass = pass();
let d = await DriverModel.findOne({ phone: driverPhone });
if (!d) d = await DriverModel.create({ phone: driverPhone, name: 'Revisão Google (motorista)', phoneVerified: true, freeRidesLeft: 0 });
const owner = `driver:${d.id}`;
const img = () => saveImage(png, 'document', owner);
const in3y = new Date(Date.now() + 3 * 365 * 86_400_000);
d.name = 'Revisão Google (motorista)';
d.phoneVerified = true;
d.passwordHash = await bcrypt.hash(dPass, 11);
d.sessionVersion = (d.sessionVersion ?? 0) + 1;
if (!d.photo) d.photo = await saveImage(png, 'avatar', owner);
if (!d.license?.frontPhoto) {
  d.license = { number: 'LD-REVISAO-01', category: 'B', expiresAt: in3y, frontPhoto: await img(), backPhoto: await img(), status: 'approved' } as never;
}
if (!d.vehicles.length) {
  d.vehicles.push({
    make: 'Toyota', carModel: 'Corolla', color: 'Branco', plate: 'LD-00-00-RV', category: 'economy', hasAC: true,
    registrationPhoto: await img(), ownershipPhoto: await img(), insurancePhoto: await img(), insuranceExpiresAt: in3y, status: 'approved',
  });
}
const v = d.vehicles[0]!;
d.vehicle = { make: v.make, carModel: v.carModel, color: v.color, plate: v.plate, category: v.category, hasAC: v.hasAC, id: String(v._id), serves: ['economy'] } as never;
await d.save();

console.log('Contas de revisão (dar à Google em «Acesso ao app»):');
console.log(`  Passageiro: ${passengerPhone.replace('+244', '')}  senha ${pPass}`);
console.log(`  Motorista:  ${driverPhone.replace('+244', '')}  senha ${dPass}`);
await mongoose.disconnect();

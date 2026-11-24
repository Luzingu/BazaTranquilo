// Regra "um número, um só tipo de conta" (2026-11-24): desactiva a conta de
// passageiro dos números que também são de um motorista. Decisão do dono: fica a
// conta de motorista; a de passageiro deixa de entrar, o número fica livre
// (passa para `formerPhone`) e nada se apaga — corridas, avaliações e histórico ficam.
//
// Sem argumentos só mostra o que faria. Para aplicar:
//   cd backend && npx tsx scripts/desactivar-passageiros-com-numero-de-motorista.ts --aplicar
// Salta quem tiver uma corrida de passageiro em curso (correr de novo mais tarde).
import mongoose from 'mongoose';
import { config } from '../src/config.js';
import { DriverModel, PassengerModel } from '../src/models/accounts.js';
import { ACTIVE_STATUSES, RideModel } from '../src/models/Ride.js';

const apply = process.argv.includes('--aplicar');
await mongoose.connect(config.mongoUri);
const phones = await DriverModel.find({ phone: { $exists: true, $ne: null } }).distinct('phone');
const passengers = await PassengerModel.find({ phone: { $in: phones } });
console.log(`${passengers.length} passageiro(s) com número de motorista.${apply ? '' : ' (só a mostrar; use --aplicar)'}`);
let done = 0;
for (const p of passengers) {
  const tail = `…${String(p.phone).slice(-3)}`;
  if (await RideModel.exists({ passenger: p._id, status: { $in: ACTIVE_STATUSES } })) {
    console.log(`  ${tail}: tem uma corrida em curso — fica para depois.`);
    continue;
  }
  console.log(`  ${tail}: ${apply ? 'desactivado' : 'seria desactivado'}.`);
  if (!apply) continue;
  await PassengerModel.updateOne(
    { _id: p._id },
    {
      $set: {
        formerPhone: p.phone,
        deactivatedAt: new Date(),
        deactivatedReason: 'numero_de_motorista',
        pushTokens: [],
      },
      $unset: { phone: '' },
      $inc: { sessionVersion: 1 },
    },
  );
  done++;
}
if (apply) console.log(`${done} conta(s) desactivada(s).`);
await mongoose.disconnect();

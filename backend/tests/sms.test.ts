// Formato dos telefones aceites pela TelcoSMS. Correr com: npm run test:unit
import assert from 'node:assert/strict';
import { toTelcoNumber } from '../src/services/sms.js';

const cases: [string, string | null][] = [
  ['+244 923 456 789', '923456789'],
  ['244923456789', '923456789'],
  ['923-456-789', '923456789'],
  ['923456789', '923456789'],
  ['222123456', null], // fixo
  ['+351912345678', null], // outro país
  ['92345678', null], // curto
  ['', null],
];
for (const [input, expected] of cases) {
  assert.equal(toTelcoNumber(input), expected, `toTelcoNumber(${JSON.stringify(input)})`);
}
console.log(`${cases.length} formatos de telefone verificados.`);

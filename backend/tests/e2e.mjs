// Teste de ponta a ponta da API do Bazá.
// Arranca um servidor próprio (porta 4100) numa base de dados só de teste
// (`baza_teste`), que é apagada no início e no fim — nunca toca nos dados reais.
// Correr com: npm run test:e2e
import { spawn } from 'node:child_process';
import mongoose from 'mongoose';
import { io as connect } from 'socket.io-client';

const PORT = 4100;
// Num servidor em que o MongoDB pede utilizador e senha, indicar o endereço em
// MONGODB_TEST_URI. A base tem de se chamar "baza_teste": é apagada pelo teste.
const DB = process.env.MONGODB_TEST_URI ?? 'mongodb://127.0.0.1:27017/baza_teste';
if (!/^mongodb(\+srv)?:\/\/[^/]+\/baza_teste(\?|$)/.test(DB)) {
  console.error('MONGODB_TEST_URI tem de apontar para a base "baza_teste".');
  process.exit(1);
}
const B = `http://localhost:${PORT}`;
// Segredo próprio dos testes (o servidor de teste não usa o do .env).
const TEST_JWT_SECRET = 'segredo-so-dos-testes-e2e';
const P = '/painel/api';

let passed = 0;
const failures = [];
let section = '';
function check(name, ok, detail = '') {
  if (ok) passed++;
  else failures.push(`[${section}] ${name}${detail ? ` — ${detail}` : ''}`);
  console.log(`  ${ok ? '✓' : '✗'} ${name}${ok || !detail ? '' : ` (${detail})`}`);
}
const group = (name) => console.log(`\n${(section = name)}`);

async function call(method, path, token, body, raw) {
  const res = await fetch(B + path, {
    method,
    headers: {
      'content-type': raw ? 'image/png' : 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: raw ?? (body ? JSON.stringify(body) : undefined),
  });
  const type = res.headers.get('content-type') ?? '';
  return { s: res.status, type, ...(type.includes('json') ? await res.json() : {}) };
}
const otp = async (phone, role) => {
  const o = await call('POST', '/auth/otp/request', null, { phone, role });
  return call('POST', '/auth/otp/verify', null, { phone, code: o.devCode, role });
};
const png = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);
const here = { lat: -8.8383, lng: 13.2344 };
const there = { lat: -8.9147, lng: 13.1869 };
const trip = { pickup: { ...here, address: 'Mutamba' }, dropoff: { ...there, address: 'Talatona' }, paymentMethod: 'cash' };

/** Envia os três documentos de uma viatura: livrete, título de propriedade e seguro. */
async function vehicleDocs(token, vehicleId) {
  for (const doc of ['registration', 'ownership', 'insurance']) {
    await call('PUT', `/documents/vehicles/${vehicleId}/${doc}`, token, null, png);
  }
}

/** Cria um motorista completo (foto, carta, viatura, documentos) e põe-no online. */
async function makeDriver(phone, name, plate, category = 'economy', hasAC = false) {
  const d = await otp(phone, 'driver');
  await call('PUT', '/me/photo', d.token, null, png);
  const r = await call('PATCH', '/me', d.token, {
    name,
    license: { number: `LD-${phone.slice(-4)}`, category: 'B', expiresAt: '2035-01-01' },
    vehicle: { make: 'Toyota', carModel: 'Corolla', color: 'Azul', plate, category, hasAC, insuranceExpiresAt: '2035-01-01' },
  });
  await call('PUT', '/documents/license/front', d.token, null, png);
  await call('PUT', '/documents/license/back', d.token, null, png);
  await vehicleDocs(d.token, r.user.vehicles[0].id);
  await call('POST', '/driver/online', d.token, { online: true, location: here });
  return { ...d, vehicleId: r.user.vehicles[0].id };
}
const finish = async (rideId, token) => {
  for (const status of ['arrived', 'in_progress', 'completed']) await call('POST', `/rides/${rideId}/status`, token, { status });
};

async function run() {
  group('Contas');
  const pas = await otp('923000001', 'passenger');
  check('passageiro entra por telefone', pas.s === 200 && pas.user.role === 'passenger');
  // Um número, um só tipo de conta: o número do passageiro não serve para motorista.
  let dup = await call('POST', '/auth/start', null, { phone: '923000001', role: 'driver' });
  check('o número do passageiro não cria conta de motorista', dup.s === 409 && dup.otherRole === 'passenger' && !dup.devCode);
  dup = await call('POST', '/auth/otp/request', null, { phone: '923000001', role: 'driver' });
  check('nem pelo pedido de código antigo', dup.s === 409 && dup.otherRole === 'passenger');
  const same = await otp('923000018', 'driver');
  check('outro número cria a conta de motorista', same.user?.role === 'driver');
  check('código errado é recusado', (await call('POST', '/auth/otp/verify', null, { phone: '923000001', code: '000000', role: 'passenger' })).s === 400);
  // O login por email foi descontinuado: só telefone.
  for (const path of ['/auth/register', '/auth/login']) {
    const gone = await call('POST', path, null, { role: 'passenger', name: 'Email Teste', email: 'a@teste.dev', password: 'segredo123', code: '123456' });
    check(`${path} está descontinuado`, gone.s === 410);
  }
  check('sem sessão não entra', (await call('GET', '/me')).s === 401);
  check('telefone inválido é recusado', (await call('POST', '/auth/otp/request', null, { phone: '12', role: 'passenger' })).s === 400);
  const other = await otp('923000009', 'passenger'); // outro passageiro, alheio às corridas do teste
  let r = await call('PATCH', '/me', pas.token, { name: 'Ana Teste', email: 'Ana@Teste.dev', emergencyContact: { name: 'Mãe', phone: '923111222' } });
  check('editar nome, email de contacto e contacto de emergência', r.user?.name === 'Ana Teste' && r.user.email === 'ana@teste.dev' && r.user.emergencyContact?.phone === '+244923111222');
  check('a conta diz se tem senha mas nunca a expõe', r.user.hasPassword === false && !('passwordHash' in r.user));

  group('Motorista: registo e documentos');
  const raw = same;
  check('sem documentos não fica online', (await call('POST', '/driver/online', raw.token, { online: true, location: here })).s === 403);
  check('carta caducada é recusada', (await call('PATCH', '/me', raw.token, { license: { number: 'LD-1', category: 'B', expiresAt: '2020-01-01' } })).s === 400);
  check('Conforto sem ar condicionado é recusado', (await call('PATCH', '/me', raw.token, { name: 'Zé', license: { number: 'LD-0001', category: 'B', expiresAt: '2035-01-01' }, vehicle: { make: 'a', carModel: 'b', color: 'Azul', plate: 'LD-00-00-AA', category: 'comfort', hasAC: false } })).s === 400);
  const d1 = await makeDriver('923000002', 'Zé Económico', 'LD-11-11-AA');
  r = await call('GET', '/me', d1.token);
  check('com foto, carta e documentos da viatura fica verificado', r.user.verification === 'approved' && r.user.isOnline);
  // Cada peça é obrigatória: sem foto de perfil, ou sem um dos documentos da viatura, o registo fica incompleto.
  {
    const inc = await otp('923000008', 'driver');
    const rr = await call('PATCH', '/me', inc.token, { name: 'Incompleto', license: { number: 'LD-0008', category: 'B', expiresAt: '2035-01-01' }, vehicle: { make: 'a', carModel: 'b', color: 'Azul', plate: 'LD-08-08-II', category: 'economy', insuranceExpiresAt: '2035-01-01' } });
    const vid = rr.user.vehicles[0].id;
    await call('PUT', '/documents/license/front', inc.token, null, png);
    await call('PUT', '/documents/license/back', inc.token, null, png);
    await vehicleDocs(inc.token, vid);
    check('sem foto de perfil o registo fica incompleto', (await call('GET', '/me', inc.token)).user.verification === 'incomplete');
    const withPhoto = await call('PUT', '/me/photo', inc.token, null, png);
    check('com a foto de perfil fica completo', withPhoto.user.verification === 'approved');
    check('motorista não pode ficar sem foto', (await call('DELETE', '/me/photo', inc.token)).s === 400);
    const inc2 = await otp('923000010', 'driver');
    await call('PUT', '/me/photo', inc2.token, null, png);
    const r2 = await call('PATCH', '/me', inc2.token, { name: 'Sem Seguro', license: { number: 'LD-0010', category: 'B', expiresAt: '2035-01-01' }, vehicle: { make: 'a', carModel: 'b', color: 'Azul', plate: 'LD-10-10-JJ', category: 'economy', insuranceExpiresAt: '2035-01-01' } });
    await call('PUT', '/documents/license/front', inc2.token, null, png);
    await call('PUT', '/documents/license/back', inc2.token, null, png);
    await call('PUT', `/documents/vehicles/${r2.user.vehicles[0].id}/registration`, inc2.token, null, png);
    const partial = await call('PUT', `/documents/vehicles/${r2.user.vehicles[0].id}/ownership`, inc2.token, null, png);
    check('só com livrete e título (sem seguro) fica incompleto', partial.user.verification === 'incomplete' && partial.user.vehicles[0].hasInsurance === false);
    check('seguro caducado é recusado', (await call('PUT', `/vehicles/${r2.user.vehicles[0].id}`, inc2.token, { make: 'a', carModel: 'b', color: 'Azul', plate: 'LD-10-10-JJ', category: 'economy', insuranceExpiresAt: '2020-01-01' })).s === 400);
    check('documento desconhecido é recusado', (await call('PUT', `/documents/vehicles/${r2.user.vehicles[0].id}/multa`, inc2.token, null, png)).s === 400);
  }
  check('ficheiro que não é imagem é recusado', (await call('PUT', '/documents/license/front', d1.token, null, Buffer.from('isto é texto, não imagem'))).s === 400);
  check('motorista vê a sua carta', (await call('GET', '/documents/license/front', d1.token)).type === 'image/png');
  check('outro motorista não vê o livrete', (await call('GET', `/documents/vehicles/${d1.vehicleId}/registration`, raw.token)).s === 404);
  check('passageiro não pode registar viatura', (await call('PATCH', '/me', pas.token, { vehicle: { make: 'a', carModel: 'b', color: 'c', plate: 'abc', category: 'economy' } })).s === 403);
  check('motorista não pode pedir corridas', (await call('POST', '/rides/estimate', d1.token, { pickup: here, dropoff: there })).s === 403);

  group('Preço, serviços e paragens');
  const est = await call('POST', '/rides/estimate', pas.token, { pickup: here, dropoff: there });
  check('estimativa devolve os 9 serviços', est.options?.length === 9);
  check('carteira desligada: não é forma de pagamento', !est.paymentMethods.includes('wallet'));
  const via = await call('POST', '/rides/estimate', pas.token, { pickup: here, dropoff: there, stops: [{ lat: -8.8147, lng: 13.2302 }] });
  const eco = (e) => e.options.find((o) => o.category === 'economy').fare;
  check('uma paragem aumenta o preço', eco(via) > eco(est), `${eco(est)} → ${eco(via)}`);
  check('mais de 3 paragens é recusado', (await call('POST', '/rides/estimate', pas.token, { pickup: here, dropoff: there, stops: Array(4).fill(here) })).s === 400);
  check('carga sem descrição é recusada', (await call('POST', '/rides', pas.token, { ...trip, category: 'truck' })).s === 400);
  check('pagar com carteira é recusado', (await call('POST', '/rides', pas.token, { ...trip, category: 'economy', paymentMethod: 'wallet' })).s === 400);

  group('Corrida completa');
  let ride = (await call('POST', '/rides', pas.token, { ...trip, category: 'economy' })).ride;
  check('pedido criado, à procura', ride?.status === 'searching');
  check('segunda corrida em simultâneo é recusada', (await call('POST', '/rides', pas.token, { ...trip, category: 'economy' })).s === 409);
  check('o motorista recebe a oferta', (await call('GET', '/driver/offers', d1.token)).offers.length === 1);
  check('aceitar', (await call('POST', `/rides/${ride.id}/accept`, d1.token)).ride?.status === 'accepted');
  check('não se pode saltar estados', (await call('POST', `/rides/${ride.id}/status`, d1.token, { status: 'completed' })).s === 409);
  const share = await call('POST', `/rides/${ride.id}/share`, pas.token);
  const token = share.url?.split('/').pop();
  const pub = await call('GET', `/acompanhar/${token}/dados`);
  check('partilha: link público com motorista e matrícula', pub.s === 200 && pub.driver?.plate === 'LD-11-11-AA');
  check('partilha: não expõe telefones nem apelidos', !/923000|Teste|Económico/.test(JSON.stringify(pub)));
  check('partilha: link inventado não existe', (await call('GET', '/acompanhar/aaaaaaaaaaaaaaaaaaaaaaaa/dados')).s === 404);
  // Notificações push: registo do dispositivo
  {
    const tk = 'dispositivo-de-teste-'.padEnd(60, 'x');
    check('registar o dispositivo para notificações', (await call('PUT', '/me/push-token', pas.token, { token: tk })).s === 200);
    check('token de dispositivo inválido é recusado', (await call('PUT', '/me/push-token', pas.token, { token: 'x' })).s === 400);
    check('remover o dispositivo ao sair', (await call('POST', '/me/push-token/remove', pas.token, { token: tk })).s === 200);
  }

  // Páginas legais e eliminação de conta
  for (const [path, word] of [['/termos', 'Termos de Utilização'], ['/privacidade', 'Lei n.º 22/11']]) {
    const page = await fetch(B + path);
    check(`página pública ${path}`, page.status === 200 && (await page.text()).includes(word));
  }
  check('sem mapas próprios configurados, o app usa o mapa público', (await call('GET', '/map/config')).ownTiles === false);
  check('não se elimina a conta com uma corrida em curso', (await call('DELETE', '/me', pas.token)).s === 409);
  {
    const gone = await otp('923000077', 'passenger');
    await call('PUT', '/me/photo', gone.token, null, png);
    check('eliminar a conta', (await call('DELETE', '/me', gone.token)).s === 200);
    check('a sessão da conta eliminada deixa de valer', (await call('GET', '/me', gone.token)).s === 401);
    const again = await otp('923000077', 'passenger');
    check('o mesmo número pode voltar a registar-se, sem dados antigos', again.user?.id !== gone.user?.id && !again.user?.photoUrl);
    await call('DELETE', '/me', again.token);
  }

  // Acompanhamento em tempo real
  await call('POST', '/driver/location', d1.token, { lat: -8.845, lng: 13.24 });
  r = await call('GET', `/rides/${ride.id}/eta`, pas.token);
  check('tempo de chegada do motorista ao ponto de recolha', r.s === 200 && r.target === 'pickup' && r.durationS > 0 && r.driverLocation?.lat === -8.845);
  check('quem não é da corrida não vê o percurso do motorista', (await call('GET', `/rides/${ride.id}/eta`, other.token)).s === 409);

  // Chamada de voz no app: o servidor encaminha a sinalização entre os dois
  check('configuração da chamada (STUN/TURN)', ((await call('GET', `/rides/${ride.id}/call-config`, pas.token)).iceServers ?? []).length >= 1);
  check('quem não é da corrida não obtém a configuração', (await call('GET', `/rides/${ride.id}/call-config`, other.token)).s === 409);
  {
    const sock = (t) => connect(B, { auth: { token: t }, transports: ['websocket'], forceNew: true });
    const ps = sock(pas.token), ds = sock(d1.token), xs = sock(other.token);
    const got = { driver: [], passenger: [], stranger: [] };
    ds.on('call:signal', (m) => got.driver.push(m));
    ps.on('call:signal', (m) => got.passenger.push(m));
    xs.on('call:signal', (m) => got.stranger.push(m));
    await new Promise((r) => setTimeout(r, 600));
    ps.emit('call:signal', { rideId: ride.id, type: 'invite' });
    await new Promise((r) => setTimeout(r, 400));
    check('convite de chamada chega ao motorista', got.driver.length === 1 && got.driver[0].type === 'invite' && got.driver[0].from === 'passenger');
    ds.emit('call:signal', { rideId: ride.id, type: 'accept' });
    ps.emit('call:signal', { rideId: ride.id, type: 'offer', data: { sdp: 'v=0', type: 'offer' } });
    await new Promise((r) => setTimeout(r, 400));
    check('aceitar e oferta WebRTC são encaminhados', got.passenger.some((m) => m.type === 'accept') && got.driver.some((m) => m.type === 'offer' && m.data?.sdp === 'v=0'));
    xs.emit('call:signal', { rideId: ride.id, type: 'invite' });
    await new Promise((r) => setTimeout(r, 400));
    check('um estranho não consegue ligar para a corrida', got.driver.filter((m) => m.type === 'invite').length === 1 && got.stranger.some((m) => m.type === 'unavailable'));
    ds.close();
    await new Promise((r) => setTimeout(r, 300));
    ps.emit('call:signal', { rideId: ride.id, type: 'invite' });
    await new Promise((r) => setTimeout(r, 400));
    check('se o outro não tem o app aberto, avisa quem liga', got.passenger.some((m) => m.type === 'unavailable'));
    ps.close();
    xs.close();
  }

  // Chat da corrida
  check('passageiro envia mensagem', (await call('POST', `/rides/${ride.id}/messages`, pas.token, { text: 'Estou à porta do banco' })).s === 201);
  check('motorista responde', (await call('POST', `/rides/${ride.id}/messages`, d1.token, { text: 'A chegar em 2 minutos' })).s === 201);
  r = await call('GET', `/rides/${ride.id}/messages`, d1.token);
  check('os dois lêem a conversa por ordem', r.messages.length === 2 && r.messages[0].from === 'passenger' && r.messages[1].from === 'driver' && r.open === true);
  check('mensagem vazia é recusada', (await call('POST', `/rides/${ride.id}/messages`, pas.token, { text: '   ' })).s === 400);
  check('quem não é da corrida não lê o chat', (await call('GET', `/rides/${ride.id}/messages`, other.token)).s === 404);
  check('SOS regista alerta', (await call('POST', `/rides/${ride.id}/sos`, pas.token, here)).s === 201);
  await finish(ride.id, d1.token);
  check('corrida concluída', (await call('GET', `/rides/${ride.id}`, pas.token)).ride.status === 'completed');
  check('corrida terminada: já não se escreve', (await call('POST', `/rides/${ride.id}/messages`, pas.token, { text: 'Obrigado' })).s === 409);
  check('corrida terminada: a conversa ainda se lê', (await call('GET', `/rides/${ride.id}/messages`, pas.token)).open === false);
  check('avaliar o motorista', (await call('POST', `/rides/${ride.id}/rate`, pas.token, { stars: 5 })).s === 200);
  check('avaliar duas vezes é recusado', (await call('POST', `/rides/${ride.id}/rate`, pas.token, { stars: 1 })).s === 409);
  check('histórico tem a corrida', (await call('GET', '/rides/history', pas.token)).rides.length === 1);

  group('Negociação de preço');
  const d2 = await makeDriver('923000003', 'Rui Dois', 'LD-22-22-BB');
  check('preço fora dos limites é recusado', (await call('POST', '/rides', pas.token, { ...trip, category: 'economy', offeredFare: 500 })).s === 400);
  ride = (await call('POST', '/rides', pas.token, { ...trip, category: 'economy', offeredFare: 4000 })).ride;
  check('passageiro propõe 4000', ride?.fare === 4000 && ride.suggestedFare > 4000);
  check('motorista 1 propõe 5500', (await call('POST', `/rides/${ride.id}/bids`, d1.token, { amount: 5500 })).ride?.myBid === 5500);
  r = await call('POST', `/rides/${ride.id}/bids`, d2.token, { amount: 5000 });
  check('motorista 2 não vê a proposta do outro', r.ride?.bids.length === 0);
  r = await call('GET', `/rides/${ride.id}`, pas.token);
  check('passageiro vê as duas, a mais barata primeiro', r.ride.bids.length === 2 && r.ride.bids[0].amount === 5000);
  check('recusar uma proposta', (await call('POST', `/rides/${ride.id}/bids/${d1.user.id}/decline`, pas.token)).ride?.bids.length === 1);
  check('mudar o preço limpa as propostas', (await call('POST', `/rides/${ride.id}/price`, pas.token, { amount: 4500 })).ride?.bids.length === 0);
  await call('POST', `/rides/${ride.id}/bids`, d2.token, { amount: 4750 });
  r = await call('POST', `/rides/${ride.id}/bids/${d2.user.id}/accept`, pas.token);
  check('aceitar proposta: corrida ao preço combinado', r.ride?.status === 'accepted' && r.ride.fare === 4750 && r.ride.driver.id === d2.user.id);
  check('o outro motorista já não a pode aceitar', (await call('POST', `/rides/${ride.id}/accept`, d1.token)).s === 409);
  await finish(ride.id, d2.token);

  group('Conforto e Económico');
  const dc = await makeDriver('923000004', 'Carla Conforto', 'LD-33-33-CC', 'comfort', true);
  for (const d of [d1, d2]) await call('POST', '/driver/online', d.token, { online: false });
  ride = (await call('POST', '/rides', pas.token, { ...trip, category: 'economy' })).ride;
  check('Conforto recebe pedido Económico', (await call('GET', '/driver/offers', dc.token)).offers.length === 1);
  await call('POST', `/rides/${ride.id}/cancel`, pas.token);
  await call('POST', '/driver/online', dc.token, { online: false });
  await call('POST', '/driver/online', d1.token, { online: true, location: here });
  ride = (await call('POST', '/rides', pas.token, { ...trip, category: 'comfort' })).ride;
  check('Económico não recebe pedido Conforto', (await call('GET', '/driver/offers', d1.token)).offers.length === 0);
  check('cancelar corrida à procura', (await call('POST', `/rides/${ride.id}/cancel`, pas.token)).ride?.status === 'cancelled');

  group('Preferidos e locais guardados');
  const stranger = await makeDriver('923000005', 'Desconhecido', 'LD-44-44-DD');
  check('só se prefere um motorista com quem se viajou', (await call('PUT', `/favorites/${stranger.user.id}`, pas.token)).s === 403);
  check('adicionar aos preferidos', (await call('PUT', `/favorites/${d1.user.id}`, pas.token)).s === 200);
  r = await call('GET', '/favorites?lat=-8.84&lng=13.235', pas.token);
  check('lista mostra disponibilidade', r.drivers.length === 1 && r.drivers[0].available === true);
  ride = (await call('POST', '/rides', pas.token, { ...trip, category: 'economy', preferredDriverId: d1.user.id })).ride;
  check('pedido directo fica reservado ao preferido', ride?.exclusive === true);
  check('outro motorista não vê o pedido reservado', (await call('GET', '/driver/offers', stranger.token)).offers.length === 0);
  await call('POST', `/rides/${ride.id}/decline`, d1.token);
  check('se o preferido recusa, abre a todos', (await call('GET', '/driver/offers', stranger.token)).offers.length === 1);
  await call('POST', `/rides/${ride.id}/cancel`, pas.token);
  await call('POST', '/places/saved', pas.token, { kind: 'home', label: 'Casa', address: 'Kilamba', lat: -8.99, lng: 13.26 });
  r = await call('POST', '/places/saved', pas.token, { kind: 'home', label: 'Casa', address: 'Maianga', lat: -8.83, lng: 13.23 });
  check('guardar Casa outra vez substitui', r.places.length === 1 && r.places[0].address === 'Maianga');

  group('Garagem');
  await call('POST', '/driver/online', d1.token, { online: false });
  r = await call('POST', '/vehicles', d1.token, { make: 'Isuzu', carModel: 'NPR', color: 'Branco', plate: 'LD-55-55-EE', category: 'truck', insuranceExpiresAt: '2035-01-01' });
  const truck = r.user.vehicles.find((v) => v.category === 'truck').id;
  check('segunda viatura registada', r.user.vehicles.length === 2);
  check('sem documentos não se activa', (await call('POST', `/vehicles/${truck}/activate`, d1.token)).s === 400);
  await call('PUT', `/documents/vehicles/${truck}/registration`, d1.token, null, png);
  check('só com o livrete também não', (await call('POST', `/vehicles/${truck}/activate`, d1.token)).s === 400);
  await vehicleDocs(d1.token, truck);
  check('com os três documentos activa-se', (await call('POST', `/vehicles/${truck}/activate`, d1.token)).user?.vehicle.category === 'truck');
  check('a viatura activa não se remove', (await call('DELETE', `/vehicles/${truck}`, d1.token)).s === 400);
  await call('POST', '/driver/online', d1.token, { online: true, location: here });
  check('online não se troca de viatura', (await call('POST', `/vehicles/${d1.vehicleId}/activate`, d1.token)).s === 409);

  group('Painel: administrador e frotas');
  const admin = await call('POST', `${P}/login`, null, { email: 'admin@baza.ao', password: 'baza-admin' });
  check('conta de administrador por defeito', admin.s === 200 && admin.mustChangePassword === true);
  check('token do app não serve no painel', (await call('GET', `${P}/admin/resumo`, pas.token)).s === 401);
  check('token do painel não serve no app', (await call('GET', '/me', admin.token)).s === 401);
  r = await call('GET', `${P}/admin/resumo`, admin.token);
  check('resumo conta motoristas, passageiros e SOS', r.drivers === 7 && r.passengers === 2 && r.sosToday === 1, JSON.stringify({ d: r.drivers, p: r.passengers, sos: r.sosToday }));
  check('resumo soma as corridas concluídas', r.today.rides === 2 && r.today.revenue > 0);
  await call('POST', `${P}/frotas/registo`, null, { name: 'Frota Teste', nif: '5417000001', email: 'frota@teste.dev', phone: '923000111', password: 'frota-teste-1' });
  check('frota não entra antes de aprovada', (await call('POST', `${P}/login`, null, { email: 'frota@teste.dev', password: 'frota-teste-1' })).s === 403);
  // Locais registados e utilizadores estrela
  {
    const soyo = { lat: -6.1349, lng: 12.3689 };
    r = await call('POST', `${P}/admin/locais`, admin.token, { name: 'Mercado do Kikudo', zone: 'Soyo', province: 'Zaire', ...soyo });
    check('o administrador regista um local', r.s === 201);
    check('o mesmo local não se regista duas vezes', (await call('POST', `${P}/admin/locais`, admin.token, { name: 'mercado do kikudo', zone: 'Soyo', province: 'Zaire', ...soyo })).s === 409);
    r = await call('GET', `/places/search?q=kikud&lat=${soyo.lat}&lng=${soyo.lng}`, pas.token);
    check('o local registado aparece primeiro na pesquisa do app', r.places?.[0]?.title === 'Mercado do Kikudo' && r.places[0].subtitle === 'Soyo, Zaire');
    check('quem não é estrela não regista locais', (await call('POST', '/places/contributions', pas.token, { name: 'Paragem do Teste', ...soyo })).s === 403);
    const me = (await call('GET', '/me', pas.token)).user;
    const pid = me.id;
    check('o administrador marca um utilizador como estrela', (await call('POST', `${P}/admin/passageiros/${pid}/estrela`, admin.token, { star: true })).s === 200);
    check('o app sabe que o utilizador é estrela', (await call('GET', '/me', pas.token)).user.star === true);
    r = await call('POST', '/places/contributions', pas.token, { name: 'Paragem do Teste', zone: 'Soyo', lat: -6.14, lng: 12.37 });
    check('o utilizador estrela regista um local onde está', r.s === 201 && r.place?.name === 'Paragem do Teste');
    r = await call('GET', '/places/near?south=-6.2&north=-6.1&west=12.3&east=12.4', pas.token);
    check('o mapa recebe os locais registados da zona que mostra', r.places?.some((p) => p.name === 'Paragem do Teste' && p.lat === -6.14));
    check('fora da zona não vêm locais', (await call('GET', '/places/near?south=-9&north=-8.9&west=13.2&east=13.3', pas.token)).places?.every((p) => p.name !== 'Paragem do Teste'));
    check('mapa muito afastado não pede locais', (await call('GET', '/places/near?south=-12&north=-6&west=12&east=20', pas.token)).places?.length === 0);
    check('o mesmo local no mesmo sítio é recusado', (await call('POST', '/places/contributions', pas.token, { name: 'Paragem do Teste', zone: 'Soyo', lat: -6.1401, lng: 12.3701 })).s === 409);
    r = await call('GET', `${P}/admin/locais?provincia=`, admin.token);
    check('o painel mostra quem registou cada local', r.locais?.some((l) => l.name === 'Paragem do Teste' && l.addedBy === me.name));
    const mine = await call('GET', '/places/contributions', pas.token);
    check('o utilizador vê e remove os seus locais', mine.total === 1 && (await call('DELETE', `/places/contributions/${mine.places[0].id}`, pas.token)).s === 200);
  }

  // Comissões: dívida do motorista, pagamento registado no painel e percentagem
  {
    r = await call('GET', '/driver/commission', d1.token);
    const due = r.due;
    check('corrida em dinheiro deixa a comissão em dívida', due > 0 && r.entries.some((e) => e.type === 'charge') && r.rate === 0.15 && r.enforced === false);
    r = await call('GET', `${P}/admin/comissoes`, admin.token);
    check('o painel mostra quem deve comissões', r.totalDue >= due && r.drivers.some((d) => d.id === d1.user.id && d.due === due));
    check('não se regista um pagamento acima da dívida', (await call('POST', `${P}/admin/comissoes/${d1.user.id}/pagamento`, admin.token, { amount: due + 1 })).s === 400);
    r = await call('POST', `${P}/admin/comissoes/${d1.user.id}/pagamento`, admin.token, { amount: due, note: 'Dinheiro, no escritório' });
    check('pagamento da comissão registado', r.s === 200 && r.due === 0);
    r = await call('GET', '/driver/commission', d1.token);
    check('o motorista vê o pagamento no extracto', r.due === 0 && r.entries[0].type === 'payment' && r.entries[0].note === 'Dinheiro, no escritório');
    check('percentagem acima do máximo é recusada', (await call('POST', `${P}/admin/comissoes/percentagem`, admin.token, { percent: 80 })).s === 400);
    check('o administrador altera a percentagem', (await call('POST', `${P}/admin/comissoes/percentagem`, admin.token, { percent: 12.5 })).rate === 0.125);
    check('a nova percentagem chega ao motorista', (await call('GET', '/driver/commission', d1.token)).rate === 0.125);
    await call('POST', `${P}/admin/comissoes/percentagem`, admin.token, { percent: 15 });
  }

  // Suporte
  {
    check('pedido de suporte sem descrição é recusado', (await call('POST', '/support/tickets', pas.token, { category: 'lost_item', message: 'ajuda' })).s === 400);
    r = await call('POST', '/support/tickets', pas.token, { category: 'lost_item', message: 'Deixei o telemóvel no banco de trás.', rideId: ride.id });
    check('pedido de suporte criado', r.s === 201 && r.ticket.status === 'open');
    check('não se associa a corrida de outra pessoa', (await call('POST', '/support/tickets', other.token, { category: 'ride', message: 'Problema com esta corrida.', rideId: ride.id })).s === 404);
    const list = await call('GET', `${P}/admin/suporte`, admin.token);
    check('o painel vê o pedido e a corrida', list.open === 1 && list.tickets[0].ride?.to && list.tickets[0].category === 'lost_item');
    check('responder resolve o pedido', (await call('POST', `${P}/admin/suporte/${list.tickets[0].id}/resposta`, admin.token, { reply: 'O motorista tem o telemóvel; ligue-lhe.' })).s === 200);
    r = await call('GET', '/support/tickets', pas.token);
    check('o utilizador vê a resposta', r.tickets[0].status === 'resolved' && r.tickets[0].reply.includes('telemóvel'));
    check('contactos e regras de cancelamento para o app', (await call('GET', '/support/info', pas.token)).cancellation?.maxLate === 3);
  }

  // Viaturas de preço combinado (camião, carrinha, triciclos, XL) e mensalidade
  {
    const cam = await makeDriver('923000091', 'Tino Camião', 'LD-91-91-CM', 'truck');
    const cli = await otp('923000092', 'passenger');
    await call('PATCH', '/me', cli.token, { name: 'Cliente Carga' });
    r = await call('POST', '/rides/estimate', cli.token, { pickup: here, dropoff: there });
    const opt = r.options.find((o) => o.category === 'truck');
    check('camião não tem preço calculado', opt.negotiated === true && opt.fare === null && r.options.find((o) => o.category === 'economy').fare > 0);
    const base = { pickup: { ...here, address: 'Mutamba' }, category: 'truck', paymentMethod: 'cash' };
    check('preço combinado exige a descrição do serviço', (await call('POST', '/rides', cli.token, base)).s === 400);
    check('corrida de tarifa continua a exigir destino', (await call('POST', '/rides', cli.token, { ...base, category: 'economy' })).s === 400);
    r = await call('POST', '/rides', cli.token, { ...base, cargoNote: 'Mudança de um T2, com frigorífico' });
    const job = r.ride;
    check('pedido sem destino e sem preço', r.s === 201 && job.negotiated && job.priceOpen && job.noDestination && job.fare === 0);
    check('sem preço, o motorista não aceita directamente', (await call('POST', `/rides/${job.id}/accept`, cam.token)).s === 409);
    check('o motorista propõe o preço do serviço', [200, 201].includes((await call('POST', `/rides/${job.id}/bids`, cam.token, { amount: 45000 })).s));
    r = await call('POST', `/rides/${job.id}/bids/${cam.user.id}/accept`, cli.token);
    check('o cliente aceita a proposta', r.ride?.status === 'accepted' && r.ride.fare === 45000 && r.ride.priceOpen === false);
    await finish(job.id, cam.token);
    check('preço combinado não gera comissão', (await call('GET', '/driver/commission', cam.token)).due === 0);
    r = await call('POST', '/rides', cli.token, { ...base, dropoff: { ...there, address: 'Talatona' }, cargoNote: 'Levar 20 sacos de cimento', offeredFare: 30000 });
    check('o cliente pode propor preço e destino', r.s === 201 && r.ride.fare === 30000 && !r.ride.noDestination);
    check('com preço proposto, o motorista pode aceitar', (await call('POST', `/rides/${r.ride.id}/accept`, cam.token)).ride?.status === 'accepted');
    await finish(r.ride.id, cam.token);

    // Mensalidade
    await call('POST', '/driver/online', cam.token, { online: false });
    check('sem mensalidade definida, a viatura é gratuita', (await call('GET', '/me', cam.token)).user.vehicles[0].subscription === 'free');
    r = await call('POST', `${P}/admin/mensalidades/taxas`, admin.token, { fees: { truck: 15000, pickup: 8000 } });
    check('o administrador define a mensalidade por tipo de viatura', r.fees?.truck === 15000 && r.fees.pickup === 8000 && r.fees.xl === 0);
    check('ao ficar online começa o período grátis', (await call('POST', '/driver/online', cam.token, { online: true, location: here })).user?.vehicles[0].subscription === 'active');
    await call('POST', '/driver/online', cam.token, { online: false });
    await mongoose.connection.collection('motoristas').updateOne({ phone: '+244923000091' }, { $set: { 'vehicles.0.paidUntil': new Date(Date.now() - 86_400_000) } });
    r = await call('POST', '/driver/online', cam.token, { online: true, location: here });
    check('mensalidade em atraso: não fica online', r.s === 402 && /mensalidade/.test(r.error ?? ''));
    r = await call('GET', `${P}/admin/mensalidades`, admin.token);
    const row = r.vehicles.find((v) => v.plate === 'LD-91-91-CM');
    check('o painel mostra a mensalidade em atraso', row?.state === 'expired' && row.fee === 15000);
    r = await call('POST', `${P}/admin/mensalidades/${row.driverId}/${row.vehicleId}/pagamento`, admin.token, { months: 2, note: 'Transferência' });
    check('pagamento de 2 meses registado', r.s === 200 && new Date(r.paidUntil) > new Date(Date.now() + 50 * 86_400_000));
    check('com a mensalidade paga volta a ficar online', (await call('POST', '/driver/online', cam.token, { online: true, location: here })).s === 200);
    // Pagamentos comunicados pelo motorista no app, por viatura
    r = await call('GET', '/driver/account', cam.token);
    check('a conta do motorista lista as viaturas com mensalidade', r.vehicles?.[0]?.plate === 'LD-91-91-CM' && r.vehicles[0].fee === 15000 && r.vehicles[0].state === 'active');
    r = await call('POST', '/driver/payments', cam.token, { kind: 'subscription', vehicleId: row.vehicleId, months: 3, method: 'transfer', reference: 'TRF 99812' });
    const before = (await call('GET', '/driver/account', cam.token)).vehicles[0].paidUntil;
    check('o motorista comunica o pagamento da mensalidade de uma viatura', r.s === 201 && r.request.amount === 45000 && r.request.status === 'pending');
    check('não se repete um pagamento ainda por confirmar', (await call('POST', '/driver/payments', cam.token, { kind: 'subscription', vehicleId: row.vehicleId, months: 1, method: 'cash' })).s === 409);
    check('comissão: não se paga mais do que se deve', (await call('POST', '/driver/payments', cam.token, { kind: 'commission', amount: 500, method: 'cash' })).s === 400);
    const pend = await call('GET', `${P}/admin/pagamentos`, admin.token);
    check('o painel vê o pagamento por confirmar', pend.pending === 1 && pend.requests[0].plate === 'LD-91-91-CM' && pend.requests[0].reference === 'TRF 99812');
    check('rejeitar exige motivo', (await call('POST', `${P}/admin/pagamentos/${pend.requests[0].id}`, admin.token, { approve: false })).s === 400);
    check('confirmar o pagamento', (await call('POST', `${P}/admin/pagamentos/${pend.requests[0].id}`, admin.token, { approve: true })).s === 200);
    r = await call('GET', '/driver/account', cam.token);
    check('a mensalidade da viatura é prolongada 3 meses', new Date(r.vehicles[0].paidUntil) - new Date(before) > 85 * 86_400_000 && r.requests[0].status === 'confirmed');
    check('o painel soma o que recebeu', (await call('GET', `${P}/admin/mensalidades`, admin.token)).receivedThisMonth === 75000);
    await call('POST', `${P}/admin/mensalidades/taxas`, admin.token, { fees: { truck: 0, pickup: 0 } });
    await call('POST', '/driver/online', cam.token, { online: false });
    await call('DELETE', '/me', cam.token);
    await call('DELETE', '/me', cli.token);
  }

  // Cancelamentos tardios: três em 24 horas suspendem a conta
  {
    const dx = await makeDriver('923000090', 'Tó Teste', 'LD-90-90-ZZ');
    const late = await otp('923000088', 'passenger');
    await call('PATCH', '/me', late.token, { name: 'Luís Atrasado' });
    for (let i = 0; i < 3; i++) {
      const x = (await call('POST', '/rides', late.token, { pickup: { ...here, address: 'Mutamba' }, dropoff: { ...there, address: 'Talatona' }, category: 'economy', paymentMethod: 'cash' })).ride;
      const dbg = [await call('POST', `/rides/${x?.id}/accept`, dx.token), await call('POST', `/rides/${x?.id}/status`, dx.token, { status: 'arrived' }), await call('POST', `/rides/${x?.id}/cancel`, late.token)];
      if (process.env.DBG) console.log('DBG', dbg.map((d) => `${d.s} ${d.error ?? d.ride?.status}`));
    }
    r = await call('POST', '/rides', late.token, { pickup: { ...here, address: 'Mutamba' }, dropoff: { ...there, address: 'Talatona' }, category: 'economy', paymentMethod: 'cash' });
    check('três cancelamentos tardios suspendem o passageiro', r.s === 403 && /suspensa/.test(r.error ?? ''));
    check('o app sabe até quando dura a suspensão', !!(await call('GET', '/me', late.token)).user.suspendedUntil);
    const early = await otp('923000089', 'passenger');
    const y = (await call('POST', '/rides', early.token, { pickup: { ...here, address: 'Mutamba' }, dropoff: { ...there, address: 'Talatona' }, category: 'economy', paymentMethod: 'cash' })).ride;
    await call('POST', `/rides/${y.id}/cancel`, early.token);
    check('cancelar antes de haver motorista não penaliza', (await call('GET', '/me', early.token)).user.suspendedUntil === null);
    await call('POST', '/driver/online', dx.token, { online: false });
    await call('DELETE', '/me', dx.token);
    await call('DELETE', '/me', late.token);
    await call('DELETE', '/me', early.token);
  }

  const fid = (await call('GET', `${P}/admin/frotas`, admin.token)).fleets[0].id;
  await call('POST', `${P}/admin/frotas/${fid}/estado`, admin.token, { status: 'active' });
  const fleet = await call('POST', `${P}/login`, null, { email: 'frota@teste.dev', password: 'frota-teste-1' });
  check('frota aprovada entra', fleet.role === 'fleet');
  check('frota não acede às rotas de administrador', (await call('GET', `${P}/admin/motoristas`, fleet.token)).s === 401);
  check('frota regista motorista', (await call('POST', `${P}/frota/motoristas`, fleet.token, { name: 'Paulo Frota', phone: '923000006' })).s === 201);
  const code = (await call('GET', `${P}/frota/resumo`, fleet.token)).fleet.joinCode;
  check('motorista junta-se por código', (await call('POST', '/driver/fleet', d2.token, { code })).user?.fleet?.name === 'Frota Teste');
  check('frota vê os seus 2 motoristas', (await call('GET', `${P}/frota/motoristas`, fleet.token)).drivers.length === 2);
  r = await call('GET', `${P}/admin/motoristas/${d1.user.id}`, admin.token);
  check('a ficha do motorista junta dados, documentos e historial', r.s === 200 && r.name === 'Zé Económico' && r.license?.photos.length === 2 && r.vehicles.length >= 1 && r.stats.rides >= 1 && Array.isArray(r.recent) && r.blocked === false);
  check('suspender exige um motivo', (await call('POST', `${P}/admin/motoristas/${d1.user.id}/bloqueio`, admin.token, { blocked: true })).s === 400);
  check('suspende com o motivo', (await call('POST', `${P}/admin/motoristas/${d1.user.id}/bloqueio`, admin.token, { blocked: true, reason: 'Seguro da viatura caducado.' })).s === 200);
  r = await call('POST', '/driver/online', d1.token, { online: true, location: here });
  check('motorista suspenso não fica online e lê o motivo', r.s === 403 && r.error.includes('Seguro da viatura caducado.'));
  r = await call('GET', `${P}/admin/motoristas/${d1.user.id}`, admin.token);
  check('a ficha mostra o motivo e quem suspendeu', r.blocked === true && r.blockedReason === 'Seguro da viatura caducado.' && Boolean(r.blockedBy) && Boolean(r.blockedAt));
  check('administrador vê a foto de um documento', (await call('GET', `${P}/admin/documentos/${d1.user.id}/carta-frente`, admin.token)).type === 'image/png');
  check('rejeitar exige motivo', (await call('POST', `${P}/admin/revisoes/${d2.user.id}`, admin.token, { target: 'carta', approve: false })).s === 400);
  await call('POST', `${P}/admin/revisoes/${d2.user.id}`, admin.token, { target: 'carta', approve: false, note: 'Foto desfocada' });
  r = await call('GET', '/me', d2.token);
  check('documento rejeitado: motorista vê o motivo', r.user.verification === 'rejected' && r.user.license.reviewNote === 'Foto desfocada');
  check('trocar a palavra-passe por defeito', (await call('POST', `${P}/admin/palavra-passe`, admin.token, { current: 'baza-admin', next: 'nova-palavra-9' })).s === 200);
  check('a antiga deixa de funcionar', (await call('POST', `${P}/login`, null, { email: 'admin@baza.ao', password: 'baza-admin' })).s === 401);

  group('Instituições e os seus utilizadores');
  {
    const E = `${P}/equipa`;
    let r = await call('GET', `${E}/utilizadores`, fleet.token);
    check('quem regista a frota é o seu primeiro gestor', fleet.role === 'fleet' && fleet.userRole === 'manager' && fleet.institution === 'Frota Teste' && r.users.length === 1 && r.users[0].you === true && r.canManage === true);
    check('o gestor regista um operador', (await call('POST', `${E}/utilizadores`, fleet.token, { name: 'Operadora Ana', email: 'ana@frota.dev', password: 'operadora-1', role: 'operator' })).s === 201);
    check('o mesmo e-mail não serve para duas contas', (await call('POST', `${E}/utilizadores`, fleet.token, { name: 'Outra', email: 'admin@baza.ao', password: 'operadora-1' })).s === 409);
    const op = await call('POST', `${P}/login`, null, { email: 'ana@frota.dev', password: 'operadora-1' });
    check('o operador entra e é convidado a trocar a palavra-passe', op.role === 'fleet' && op.userRole === 'operator' && op.mustChangePassword === true && op.name === 'Operadora Ana');
    check('o operador vê os motoristas da frota', (await call('GET', `${P}/frota/motoristas`, op.token)).drivers.length === 2);
    check('mas não gere utilizadores', (await call('POST', `${E}/utilizadores`, op.token, { name: 'X Y', email: 'x@frota.dev', password: 'operadora-1' })).s === 403);
    check('o operador troca a sua palavra-passe', (await call('POST', `${E}/palavra-passe`, op.token, { current: 'operadora-1', next: 'operadora-2' })).s === 200 && (await call('POST', `${P}/login`, null, { email: 'ana@frota.dev', password: 'operadora-2' })).mustChangePassword === false);
    r = await call('GET', `${E}/utilizadores`, fleet.token);
    const opId = r.users.find((u) => u.email === 'ana@frota.dev').id, meId = r.users.find((u) => u.you).id;
    check('tem de ficar sempre um gestor activo', (await call('POST', `${E}/utilizadores/${meId}`, fleet.token, { role: 'operator' })).s === 409);
    check('o gestor desactiva o operador, que deixa de entrar', (await call('POST', `${E}/utilizadores/${opId}`, fleet.token, { active: false })).s === 200 && (await call('GET', `${P}/frota/motoristas`, op.token)).s === 401 && (await call('POST', `${P}/login`, null, { email: 'ana@frota.dev', password: 'operadora-2' })).s === 403);
    check('o gestor remove o operador', (await call('DELETE', `${E}/utilizadores/${opId}`, fleet.token)).s === 200);

    // Funcionalidades da frota
    r = await call('GET', `${P}/frota/motoristas/${d2.user.id}`, fleet.token);
    check('a frota vê a ficha dos seus motoristas', r.s === 200 && r.name === 'Rui Dois' && Array.isArray(r.vehicles));
    const outsider = await makeDriver('923000071', 'Fora da Frota', 'LD-71-71-ZZ');
    check('mas não a de motoristas de fora', (await call('GET', `${P}/frota/motoristas/${outsider.user.id}`, fleet.token)).s === 404);
    r = await call('POST', `${P}/frota/avisos`, fleet.token, { title: 'Reunião', message: 'Reunião de motoristas amanhã às 8h, na sede.' });
    check('a frota avisa todos os seus motoristas', r.s === 201 && r.sent === 2 && (await call('GET', '/notices', d2.token)).notices[0].title === 'Reunião' && (await call('GET', '/notices', outsider.token)).notices.every((n) => n.title !== 'Reunião'));
    r = await call('GET', `${P}/frota/contas?dias=30`, fleet.token);
    check('contas da frota por motorista', r.s === 200 && r.drivers.length === 2 && typeof r.totals.revenue === 'number' && r.totals.rides >= 1);
    check('a frota consulta os alertas SOS dos seus motoristas', Array.isArray((await call('GET', `${P}/frota/sos`, fleet.token)).alerts));
    check('o gestor corrige os dados da empresa', (await call('POST', `${P}/frota/empresa`, fleet.token, { name: 'Frota Teste Lda', phone: '923000112' })).s === 200 && (await call('GET', `${P}/frota/resumo`, fleet.token)).fleet.name === 'Frota Teste Lda');
  }

  group('Gestão da frota: acertos, viaturas e turnos');
  {
    const F = `${P}/frota`;
    // Acerto de contas: percentagem do facturado, ou valor fixo por dia trabalhado.
    let r = await call('GET', `${F}/acertos`, fleet.token);
    const row = r.drivers.find((d) => d.id === d2.user.id);
    check('sem regra, o motorista não deve nada à frota', row.term === null && row.owed === 0 && row.balance === 0);
    check('a percentagem não passa de 100', (await call('POST', `${F}/acertos/${d2.user.id}`, fleet.token, { mode: 'percent', value: 120 })).s === 400);
    await call('POST', `${F}/acertos/${d2.user.id}`, fleet.token, { mode: 'percent', value: 30, startAt: '2020-01-01' });
    r = (await call('GET', `${F}/acertos`, fleet.token)).drivers.find((d) => d.id === d2.user.id);
    check('com 30 %, deve 30 % do que facturou', r.term.mode === 'percent' && r.owed === Math.round(r.revenue * 0.3) && r.balance === r.owed);
    const owed = r.owed;
    check('a frota regista o dinheiro entregue', (await call('POST', `${F}/acertos/${d2.user.id}/entrega`, fleet.token, { amount: 1000, note: 'Em mão' })).s === 201);
    r = await call('GET', `${F}/acertos`, fleet.token);
    check('o saldo desce com a entrega', r.drivers.find((d) => d.id === d2.user.id).balance === owed - 1000 && r.handovers[0].amount === 1000 && r.handovers[0].driver === 'Rui Dois');
    await call('POST', `${F}/acertos/${d2.user.id}`, fleet.token, { mode: 'daily', value: 5000, startAt: '2020-01-01' });
    r = (await call('GET', `${F}/acertos`, fleet.token)).drivers.find((d) => d.id === d2.user.id);
    check('com conta diária, deve o valor por cada dia trabalhado', r.term.mode === 'daily' && r.owed === r.days * 5000);
    check('não se mexe no acerto de um motorista de fora', (await call('POST', `${F}/acertos/${pas.user.id}`, fleet.token, { mode: 'daily', value: 1 })).s === 404);

    // Viaturas da empresa, com datas e despesas.
    r = await call('POST', `${F}/viaturas`, fleet.token, { plate: 'ld-90-90-fr', label: 'Toyota Hiace branca', driver: d2.user.id, insuranceDue: '2020-01-01', inspectionDue: '', serviceDue: '2035-01-01' });
    check('a frota regista uma viatura e entrega-a a um motorista', r.s === 201);
    const vid = r.id;
    check('a mesma matrícula não entra duas vezes', (await call('POST', `${F}/viaturas`, fleet.token, { plate: 'LD-90-90-FR', label: 'Outra' })).s === 409);
    check('regista uma despesa', (await call('POST', `${F}/viaturas/${vid}/despesas`, fleet.token, { kind: 'fuel', amount: 12000, date: new Date().toISOString(), note: 'Gasóleo' })).s === 201);
    r = await call('GET', `${F}/viaturas`, fleet.token);
    const v = r.vehicles[0];
    check('a lista mostra o motorista, as datas e o gasto do mês', v.plate === 'LD-90-90-FR' && v.driver === 'Rui Dois' && v.spentMonth === 12000 && v.inspectionDue === null && r.spentMonth === 12000 && r.expenses[0].kind === 'fuel');
    check('editar a viatura retira o motorista e as datas vazias', (await call('POST', `${F}/viaturas/${vid}`, fleet.token, { plate: 'LD-90-90-FR', label: 'Toyota Hiace', driver: '', insuranceDue: '', inspectionDue: '', serviceDue: '' })).s === 200 && (await call('GET', `${F}/viaturas`, fleet.token)).vehicles[0].driver === null);

    // Turnos
    const allDay = { days: [0, 1, 2, 3, 4, 5, 6], start: '00:00', end: '23:59' };
    check('hora inválida é recusada', (await call('POST', `${F}/turnos/${d2.user.id}`, fleet.token, { ...allDay, start: '25:00' })).s === 400);
    await call('POST', `${F}/turnos/${d2.user.id}`, fleet.token, allDay);
    r = await call('GET', `${F}/turnos`, fleet.token);
    const sh = r.drivers.find((d) => d.id === d2.user.id);
    check('quem está de turno e não está online aparece em falta', sh.expected === true && sh.online === false && sh.missing === true && r.missing >= 1);
    await call('POST', `${F}/turnos/${d2.user.id}`, fleet.token, { days: [], start: '00:00', end: '00:00' });
    check('sem dias, o turno é retirado', (await call('GET', `${F}/turnos`, fleet.token)).drivers.find((d) => d.id === d2.user.id).shift === null);
  }

  group('Empresas clientes');
  {
    let r = await call('POST', `${P}/admin/empresas`, admin.token, { name: 'Hotel Kianda', nif: '5417999001', contactName: 'Dra. Luísa', phone: '923000700', email: '', monthlyLimit: 6000 });
    check('o administrador regista uma empresa cliente', r.s === 201);
    const cid = r.id;
    const emp = await otp('923000701', 'passenger'); await call('PATCH', '/me', emp.token, { name: 'Colaborador Rui' });
    const trip2 = { pickup: { lat: -8.8383, lng: 13.2344, address: 'Mutamba' }, dropoff: { lat: -8.85, lng: 13.24, address: 'Maianga' } };
    check('quem não é colaborador não vê a opção', !(await call('POST', '/rides/estimate', emp.token, trip2)).paymentMethods.includes('corporate'));
    check('nem pode pedir por conta de uma empresa', (await call('POST', '/rides', emp.token, { ...trip2, category: 'economy', paymentMethod: 'corporate' })).s === 403);
    check('autoriza o colaborador pelo telefone', (await call('POST', `${P}/admin/empresas/${cid}/colaboradores`, admin.token, { name: 'Rui', phone: '923000701' })).s === 201);
    check('o mesmo número não fica em duas empresas', (await call('POST', `${P}/admin/empresas/${cid}/colaboradores`, admin.token, { phone: '923 000 701' })).s === 409);
    r = await call('POST', '/rides/estimate', emp.token, trip2);
    check('o colaborador passa a poder escolher "conta da empresa"', r.paymentMethods[0] === 'corporate' && r.company.name === 'Hotel Kianda' && r.company.remaining === 6000);
    const cd = await makeDriver('923000702', 'Motorista Empresa', 'LD-70-70-EE');
    await call('POST', '/driver/online', cd.token, { online: true, location: { lat: -8.8383, lng: 13.2344 } });
    const before = (await call('GET', '/driver/account', cd.token)).commission.due;
    r = await call('POST', '/rides', emp.token, { ...trip2, category: 'economy', paymentMethod: 'corporate' });
    check('a corrida fica por conta da empresa', r.s === 201 && r.ride.paymentMethod === 'corporate' && r.ride.companyName === 'Hotel Kianda');
    const cr = r.ride;
    await call('POST', `/rides/${cr.id}/accept`, cd.token);
    for (const status of ['arrived', 'in_progress', 'completed']) await call('POST', `/rides/${cr.id}/status`, cd.token, { status });
    const acc = await call('GET', '/driver/account', cd.token);
    const net = cr.fare - Math.round(cr.fare * 0.15);
    check('o motorista não cobra: fica com o valor a receber do Bazá', acc.commission.due === before - net && acc.entries[0].type === 'credit' && acc.entries[0].amount === net);
    r = await call('GET', `${P}/admin/comissoes`, admin.token);
    const owe = r.toPay.find((d) => d.name === 'Motorista Empresa');
    check('o painel mostra o que o Bazá deve ao motorista', owe?.amount === net && r.totalToPay >= net && r.drivers.every((d) => d.name !== 'Motorista Empresa'));
    check('não se paga mais do que se deve', (await call('POST', `${P}/admin/comissoes/${cd.user.id}/pagar-motorista`, admin.token, { amount: net + 1 })).s === 400);
    check('o Bazá paga ao motorista e o saldo fica a zero', (await call('POST', `${P}/admin/comissoes/${cd.user.id}/pagar-motorista`, admin.token, { amount: net, note: 'Transferência' })).due === 0);
    check('acima do limite do mês, a empresa deixa de pagar', (await call('POST', '/rides', emp.token, { ...trip2, dropoff: { lat: -8.9147, lng: 13.1869, address: 'Talatona' }, category: 'comfort', paymentMethod: 'corporate' })).s === 402);
    const month = new Date().toISOString().slice(0, 7);
    r = await call('GET', `${P}/admin/empresas/${cid}/conta?mes=${month}`, admin.token);
    check('a conta do mês lista as corridas da empresa', r.total === cr.fare && r.rides.length === 1 && r.rides[0].passenger === 'Colaborador Rui' && r.balance === cr.fare);
    check('regista o pagamento da empresa', (await call('POST', `${P}/admin/empresas/${cid}/pagamento`, admin.token, { month, amount: cr.fare, note: 'TRF 1' })).s === 201 && (await call('GET', `${P}/admin/empresas/${cid}/conta?mes=${month}`, admin.token)).balance === 0);
    r = await call('GET', `${P}/admin/empresas`, admin.token);
    check('o painel lista as empresas com o gasto do mês', r.companies[0].name === 'Hotel Kianda' && r.companies[0].current.total === cr.fare && r.companies[0].members.length === 1);
    await call('DELETE', `${P}/admin/empresas/${cid}/colaboradores/${r.companies[0].members[0].id}`, admin.token);
    check('retirado o colaborador, a opção desaparece', !(await call('POST', '/rides/estimate', emp.token, trip2)).paymentMethods.includes('corporate'));
  }

  group('Postos policiais e agentes');
  {
    const A = '/agent';
    // O administrador regista os postos e os agentes de cada um.
    let r = await call('POST', `${P}/admin/postos`, admin.token, { name: 'Esquadra da Mutamba', province: 'Luanda', municipality: 'Luanda', phone: '923000600', lat: -8.8383, lng: 13.2344 });
    check('o administrador regista um posto policial', r.s === 201);
    const near = r.id;
    await call('POST', `${P}/admin/postos`, admin.token, { name: 'Posto de Viana', province: 'Luanda', municipality: 'Viana', lat: -8.905, lng: 13.375 });
    await call('POST', `${P}/admin/postos`, admin.token, { name: 'Comando Provincial de Luanda', province: 'Luanda', municipality: 'Luanda', lat: -8.8147, lng: 13.2302, command: true });
    check('o número de um passageiro não serve para agente', (await call('POST', `${P}/admin/postos/${near}/agentes`, admin.token, { name: 'Ana', phone: '923000001' })).s === 409);
    check('regista um agente no posto', (await call('POST', `${P}/admin/postos/${near}/agentes`, admin.token, { name: 'Paulo Domingos', rank: 'Subinspector', phone: '923000601' })).s === 201);
    check('o mesmo número não serve para dois agentes', (await call('POST', `${P}/admin/postos/${near}/agentes`, admin.token, { name: 'Outro', phone: '923 000 601' })).s === 409);
    r = await call('GET', `${P}/admin/postos`, admin.token);
    const st = r.stations.find((x) => x.id === near);
    const agentId = st.agents[0].id;
    check('o painel lista os postos com os seus agentes', r.stations.length === 3 && st.agents.length === 1 && st.agents[0].name === 'Paulo Domingos' && st.agents[0].onDuty === false);

    // Entrada oculta: o agente usa o ecrã normal; o servidor reconhece o número.
    r = await call('POST', '/auth/start', null, { phone: '923000601', role: 'passenger' });
    check('o número do agente recebe o código como qualquer outro', r.method === 'otp' && /^\d{6}$/.test(r.devCode));
    r = await call('POST', '/auth/otp/verify', null, { phone: '923000601', role: 'passenger', code: r.devCode });
    check('o código dá um bilhete de agente, não uma conta de passageiro', Boolean(r.agentTicket) && r.agentHasPassword === false && !r.token && !r.user);
    const ticket = r.agentTicket;
    check('o bilhete sozinho não abre nada', (await call('GET', `${A}/alerts`, ticket)).s === 401);
    r = await call('POST', `${A}/session`, null, { ticket, password: 'agente-123', deviceId: 'telemovel-do-paulo' });
    check('na primeira entrada o agente define a senha e abre a sessão', r.s === 200 && Boolean(r.token) && r.agent.station.name === 'Esquadra da Mutamba' && r.agent.rank === 'Subinspector');
    const ag = r.token;
    check('a sessão do agente não serve nas rotas de passageiros e motoristas', (await call('GET', '/me', ag)).s === 401 && (await call('GET', `${P}/admin/motoristas`, ag)).s === 401);
    check('ninguém cria conta de passageiro com o número de um agente', (await call('POST', '/auth/otp/request', null, { phone: '923000601', role: 'passenger' })).s === 409);
    const again = async (password, deviceId) => {
      const s1 = await call('POST', '/auth/start', null, { phone: '923000601', role: 'driver' });
      const v = await call('POST', '/auth/otp/verify', null, { phone: '923000601', role: 'driver', code: s1.devCode });
      return call('POST', `${A}/session`, null, { ticket: v.agentTicket, password, deviceId });
    };
    check('senha errada não entra', (await again('errada-999', 'telemovel-do-paulo')).s === 401);
    check('outro telemóvel fica à espera de autorização', (await again('agente-123', 'outro-telemovel')).s === 403);
    await call('POST', `${P}/admin/agentes/${agentId}`, admin.token, { resetDevice: true });
    check('depois de o administrador autorizar, o telemóvel novo entra', (await again('agente-123', 'outro-telemovel')).s === 200);
    check('o agente fica de serviço', (await call('POST', `${A}/duty`, ag, { on: true })).agent.onDuty === true);

    // Só um alerta de perigo, accionado por quem vai na corrida, dá acesso à corrida.
    const sp = await otp('923000081', 'passenger'); await call('PATCH', '/me', sp.token, { name: 'Sara Perigo' }); await call('PUT', '/me/password', sp.token, { password: 'sara-1234' });
    const gf = await otp('923000083', 'passenger'); await call('PATCH', '/me', gf.token, { name: 'Irmã da Sara' });
    await call('PATCH', '/me', sp.token, { emergencyContact: { name: 'Irmã', phone: '923000083' } });
    const sd = await makeDriver('923000082', 'Tomás Alerta', 'LD-82-82-SS');
    await call('POST', '/driver/online', sd.token, { online: true, location: { lat: -8.84, lng: 13.23 } });
    const sr = (await call('POST', '/rides', sp.token, { pickup: { lat: -8.84, lng: 13.23, address: 'Mutamba' }, dropoff: { lat: -8.9147, lng: 13.1869, address: 'Talatona' }, category: 'economy', paymentMethod: 'cash' })).ride;
    await call('POST', `/rides/${sr.id}/accept`, sd.token);
    check('sem alerta, o agente não vê nada', (await call('GET', `${A}/alerts`, ag)).alerts.length === 0);
    r = await call('POST', `/rides/${sr.id}/sos`, sp.token, { lat: -8.85, lng: 13.22 });
    const twice = await call('POST', `/rides/${sr.id}/sos`, sp.token, { lat: -8.86, lng: 13.21 });
    check('o alerta vai para os postos a menos de 10 km (e não para os distantes)', r.s === 201 && r.open === true && r.stations.some((x) => x.name === 'Esquadra da Mutamba' && x.distanceM < 10000) && r.stations.every((x) => x.name !== 'Posto de Viana'));
    check('repetir o toque não cria outro alerta', twice.id === r.id);
    const list = await call('GET', `${A}/alerts`, ag);
    const al = list.alerts[0];
    check('o agente de serviço recebe o alerta, com a distância', list.open === 1 && al.open === true && al.name === 'Sara Perigo' && al.lat === -8.86 && al.distanceM > 0 && al.assignedName === null);
    r = await call('GET', `${A}/alerts/${al.id}`, ag);
    check('com o alerta aberto vê a corrida, as pessoas, a viatura e a posição actual', r.ride?.passenger.name === 'Sara Perigo' && r.ride.driver.name === 'Tomás Alerta' && r.ride.vehicle.plate === 'LD-82-82-SS' && r.ride.from.address === 'Mutamba' && r.ride.live?.lat === -8.84 && r.by.phone === '+244923000081');
    // Som da viagem: quem pediu ajuda partilha; o agente ouve enquanto o alerta está aberto.
    const wav = Buffer.concat([Buffer.from('RIFF'), Buffer.alloc(4), Buffer.from('WAVEfmt '), Buffer.alloc(60)]);
    const sendAudio = (token, body) => fetch(`${B}/rides/${sr.id}/sos/audio`, { method: 'PUT', headers: { authorization: `Bearer ${token}`, 'content-type': 'audio/wav' }, body }).then(async (x) => ({ s: x.status, ...(await x.json().catch(() => ({}))) }));
    check('quem pediu ajuda envia o som em blocos', (await sendAudio(sp.token, wav)).seq === 1 && (await sendAudio(sp.token, wav)).seq === 2);
    check('só se aceita som verdadeiro', (await sendAudio(sp.token, Buffer.from('isto não é som, é texto a fingir que é um ficheiro'))).s === 400);
    check('o motorista da corrida não envia som para o alerta do passageiro', (await sendAudio(sd.token, wav)).s === 409);
    check('o agente vê que há som', (await call('GET', `${A}/alerts/${al.id}`, ag)).audioLast === 2);
    r = await fetch(`${B}${A}/alerts/${al.id}/audio/2`, { headers: { authorization: `Bearer ${ag}` } });
    check('e ouve cada bloco', r.status === 200 && r.headers.get('content-type') === 'audio/wav' && (await r.arrayBuffer()).byteLength === wav.length);
    check('sem sessão de agente não se ouve nada', (await fetch(`${B}${A}/alerts/${al.id}/audio/1`, { headers: { authorization: `Bearer ${sp.token}` } })).status === 401);
    // Pessoa de confiança: o contacto de emergência, se tiver o Bazá, acompanha no app.
    r = await call('GET', '/guardian/alerts', gf.token);
    check('a pessoa de confiança é avisada e vê o alerta do amigo', r.alerts.length === 1 && r.alerts[0].name === 'Sara Perigo' && r.alerts[0].ride.vehicle.plate === 'LD-82-82-SS' && r.alerts[0].audioLast === 2);
    r = await fetch(`${B}/guardian/alerts/${al.id}/audio/1`, { headers: { authorization: `Bearer ${gf.token}` } });
    check('e ouve o som que o amigo partilha', r.status === 200 && r.headers.get('content-type') === 'audio/wav');
    check('quem não é a pessoa de confiança não vê nada', (await call('GET', '/guardian/alerts', other.token)).alerts.length === 0 && (await call('GET', `/guardian/alerts/${al.id}`, other.token)).s === 404);
    check('o agente assume o alerta', (await call('POST', `${A}/alerts/${al.id}/assume`, ag)).s === 200 && (await call('POST', `${A}/alerts/${al.id}/assume`, ag)).s === 409);
    r = await call('GET', `/rides/${sr.id}/sos`, sp.token);
    check('quem pediu ajuda vê que posto foi avisado e quem assumiu', r.alert.open === true && r.alert.assignedName.includes('Paulo Domingos') && r.alert.assignedName.includes('Esquadra da Mutamba'));
    check('cancelar o alerta exige a senha de quem o accionou', (await call('POST', `/rides/${sr.id}/sos/cancel`, sp.token, { password: 'errada' })).s === 401);
    check('fechar o alerta exige dizer o que foi feito', (await call('POST', `${A}/alerts/${al.id}/close`, ag, { note: '' })).s === 400);
    check('o agente fecha o alerta', (await call('POST', `${A}/alerts/${al.id}/close`, ag, { note: 'Patrulha no local. Passageira em segurança.' })).s === 200);
    r = await call('GET', `${A}/alerts/${al.id}`, ag);
    check('depois de fechado, nem som novo nem som antigo', (await sendAudio(sp.token, wav)).s === 409 && (await fetch(`${B}${A}/alerts/${al.id}/audio/1`, { headers: { authorization: `Bearer ${ag}` } })).status === 404);
    check('fechado o alerta, a pessoa de confiança também deixa de ver', (await call('GET', '/guardian/alerts', gf.token)).alerts.length === 0);
    check('depois de fechado deixa de ver a corrida', r.open === false && r.ride === null && r.closeNote.startsWith('Patrulha'));
    // Engano: o passageiro acciona de novo e cancela com a senha.
    await call('POST', `/rides/${sr.id}/sos`, sp.token, { lat: -8.85, lng: 13.22 });
    check('quem accionou cancela com a senha, e o agente fica a saber', (await call('POST', `/rides/${sr.id}/sos/cancel`, sp.token, { password: 'sara-1234' })).s === 200 && (await call('GET', `${A}/alerts`, ag)).alerts[0].cancelledByUser === true);
    r = await call('GET', `${P}/admin/postos`, admin.token);
    check('cada acesso fica registado, com o agente e o posto', r.queries.length >= 3 && r.queries.every((q) => q.authority === 'Esquadra da Mutamba' && q.user === 'Subinspector Paulo Domingos') && r.queries.some((q) => q.kind === 'assume') && r.queries.some((q) => q.kind === 'close'));
    check('o administrador desactiva o agente, que perde o acesso na hora', (await call('POST', `${P}/admin/agentes/${agentId}`, admin.token, { active: false })).s === 200 && (await call('GET', `${A}/alerts`, ag)).s === 401);
    check('e o número volta a ser um número qualquer', (await call('POST', '/auth/start', null, { phone: '923000601', role: 'passenger' })).method === 'otp');
  }

  group('Avisos da equipa');
  {
    let r = await call('POST', `${P}/admin/avisos`, admin.token, { kind: 'passageiros', id: pas.user.id, title: 'Objecto encontrado', message: 'O motorista encontrou o seu telemóvel. Ligue para o suporte.' });
    check('o administrador envia um aviso a um passageiro', r.s === 201 && r.sent === 1);
    check('aviso sem mensagem é recusado', (await call('POST', `${P}/admin/avisos`, admin.token, { kind: 'passageiros', id: pas.user.id, title: 'Olá', message: '' })).s === 400);
    r = await call('GET', '/notices', pas.token);
    check('o passageiro recebe o aviso por ler', r.unread === 1 && r.notices[0].title === 'Objecto encontrado' && r.notices[0].read === false);
    check('outro passageiro não o vê', (await call('GET', '/notices', other.token)).notices.length === 0);
    check('não se marca como lido o aviso de outra pessoa', (await call('POST', `/notices/${r.notices[0].id}/read`, other.token)).s === 200 && (await call('GET', '/notices', pas.token)).unread === 1);
    await call('POST', `/notices/${r.notices[0].id}/read`, pas.token);
    check('depois de "Entendi" fica lido', (await call('GET', '/notices', pas.token)).unread === 0);
    r = await call('POST', `${P}/admin/avisos`, admin.token, { kind: 'motoristas', title: 'Manutenção', message: 'O Bazá estará em manutenção esta noite, das 2h às 3h.' });
    check('aviso a todos os motoristas', r.s === 201 && r.sent >= 2);
    check('cada motorista recebe-o', (await call('GET', '/notices', d1.token)).notices[0]?.title === 'Manutenção' && (await call('GET', '/notices', pas.token)).notices.length === 1);
    r = await call('GET', `${P}/admin/avisos`, admin.token);
    const all = r.notices.find((n) => n.title === 'Manutenção');
    check('o painel lista os avisos e quantos foram lidos', all?.to === 'Todos os motoristas' && all.sent >= 2 && all.read === 0 && r.notices.some((n) => n.title === 'Objecto encontrado' && n.read === 1 && n.to === 'Ana Teste'));
  }

  group('Táxi intermunicipal');
  {
    const I = '/intercity';
    const drv = await makeDriver('923000061', 'Paulo Intermunicipal', 'ZR-61-61-AA');
    const p1 = await otp('923000062', 'passenger'); await call('PATCH', '/me', p1.token, { name: 'Marta Soyo' });
    const p2 = await otp('923000063', 'passenger'); await call('PATCH', '/me', p2.token, { name: 'Nelo Mbanza' });
    let r = await call('POST', `${P}/admin/intermunicipal/rotas`, admin.token, { from: 'Mbanza Kongo', to: 'Soyo', price: 8000, maxPrice: 10000, distanceKm: 330 });
    check('o administrador cria uma rota com preço por passageiro', r.s === 201);
    check('a mesma rota no sentido contrário é recusada', (await call('POST', `${P}/admin/intermunicipal/rotas`, admin.token, { from: 'soyo', to: 'mbanza kongo', price: 9000 })).s === 409);
    r = await call('GET', `${I}/routes`, drv.token);
    const route = r.routes?.find((x) => x.from === 'Mbanza Kongo');
    check('o app recebe as rotas e os limites de preço', route?.price === 8000 && route.min === 4000 && route.max === 10000 && r.places.includes('Soyo'));
    const tomorrow = new Date(Date.now() + 26 * 3600_000).toISOString();
    check('o passageiro não publica viagens', (await call('POST', `${I}/trips`, p1.token, { routeId: route.id, departAt: tomorrow, seats: 4 })).s === 403);
    check('preço acima do máximo da rota é recusado', (await call('POST', `${I}/trips`, drv.token, { routeId: route.id, departAt: tomorrow, seats: 4, price: 12000 })).s === 400);
    check('partida no passado é recusada', (await call('POST', `${I}/trips`, drv.token, { routeId: route.id, departAt: new Date(Date.now() - 3600_000).toISOString(), seats: 4 })).s === 400);
    r = await call('POST', `${I}/trips`, drv.token, { routeId: route.id, reverse: true, departAt: tomorrow, seats: 4, price: 9000, meetingPoint: 'Paragem do Kikudo', note: 'Mala grande: 1 000 Kz.' });
    const trip = r.trip;
    check('o motorista publica a viagem no sentido que quer', r.s === 201 && trip.from === 'Soyo' && trip.to === 'Mbanza Kongo' && trip.seatsLeft === 4 && trip.price === 9000);
    r = await call('GET', `${I}/trips?from=Soyo`, p1.token);
    const seen = r.trips?.find((t) => t.id === trip.id);
    check('o passageiro encontra a viagem, sem o telefone do motorista', seen?.note === 'Mala grande: 1 000 Kz.' && seen.driver.phone === null && seen.driver.name === 'Paulo Intermunicipal');
    check('o filtro por origem funciona', (await call('GET', `${I}/trips?from=Luanda`, p1.token)).trips.every((t) => t.id !== trip.id));
    check('não se reservam mais lugares do que há', (await call('POST', `${I}/trips/${trip.id}/bookings`, p1.token, { seats: 5 })).s === 409);
    r = await call('POST', `${I}/trips/${trip.id}/bookings`, p1.token, { seats: 3, note: 'Levo duas malas.' });
    check('o passageiro reserva lugares; ficam por confirmar', r.s === 201 && r.trip.myBooking.status === 'pending' && r.trip.seatsLeft === 4);
    check('não se reserva duas vezes a mesma viagem', (await call('POST', `${I}/trips/${trip.id}/bookings`, p1.token, { seats: 1 })).s === 409);
    r = await call('POST', `${I}/trips/${trip.id}/bookings`, p2.token, { seats: 2 });
    check('outro passageiro também pede lugares', r.s === 201);
    r = await call('GET', `${I}/trips/mine`, drv.token);
    const mine = r.trips.find((t) => t.id === trip.id);
    check('o motorista vê as reservas com os contactos', mine?.pending === 2 && mine.bookings.some((b) => b.name === 'Marta Soyo' && b.phone === '+244923000062' && b.note === 'Levo duas malas.'));
    const b1 = mine.bookings.find((b) => b.name === 'Marta Soyo').id, b2 = mine.bookings.find((b) => b.name === 'Nelo Mbanza').id;
    check('outro motorista não mexe nesta viagem', (await call('POST', `${I}/trips/${trip.id}/bookings/${b1}`, d1.token, { action: 'confirm' })).s === 404);
    r = await call('POST', `${I}/trips/${trip.id}/bookings/${b1}`, drv.token, { action: 'confirm' });
    check('ao confirmar, os lugares livres diminuem', r.s === 200 && r.trip.seatsLeft === 1);
    check('não se confirma além dos lugares', (await call('POST', `${I}/trips/${trip.id}/bookings/${b2}`, drv.token, { action: 'confirm' })).s === 409);
    r = await call('GET', `${I}/trips/mine`, p1.token);
    check('com a reserva confirmada, o passageiro vê o telefone do motorista', r.trips[0]?.myBooking?.status === 'confirmed' && r.trips[0].driver.phone === '+244923000061');
    check('não se reduzem os lugares abaixo dos confirmados', (await call('PATCH', `${I}/trips/${trip.id}`, drv.token, { seats: 2 })).s === 409);
    r = await call('PATCH', `${I}/trips/${trip.id}`, drv.token, { seats: 5 });
    check('o motorista acerta os lugares', r.trip.seats === 5 && r.trip.seatsLeft === 2);
    r = await call('POST', `${I}/trips/${trip.id}/bookings/${b2}`, drv.token, { action: 'confirm' });
    check('com mais lugares, a segunda reserva é confirmada', r.trip.seatsLeft === 0);
    r = await call('POST', `${I}/trips/${trip.id}/bookings/mine/cancel`, p2.token);
    check('o passageiro desiste e o lugar fica livre', r.s === 200 && r.trip.seatsLeft === 2 && !r.trip.myBooking);
    check('não se conclui uma viagem que ainda não partiu', (await call('POST', `${I}/trips/${trip.id}/status`, drv.token, { status: 'completed' })).s === 409);
    check('o motorista parte', (await call('POST', `${I}/trips/${trip.id}/status`, drv.token, { status: 'departed' })).trip.status === 'departed');
    check('depois de partir já não se reserva', (await call('POST', `${I}/trips/${trip.id}/bookings`, p2.token, { seats: 1 })).s === 409);
    const due = (await call('GET', '/driver/account', drv.token)).commission.due;
    r = await call('POST', `${I}/trips/${trip.id}/status`, drv.token, { status: 'completed' });
    // 3 lugares confirmados × 9 000 Kz × 10 %
    check('ao concluir, a comissão dos lugares confirmados vai para a conta do motorista', r.trip.status === 'completed' && r.trip.commission === 2700 && (await call('GET', '/driver/account', drv.token)).commission.due === due + 2700);
    check('o administrador muda a comissão intermunicipal', (await call('POST', `${P}/admin/intermunicipal/comissao`, admin.token, { percent: 5 })).rate === 0.05);
    r = await call('GET', `${P}/admin/intermunicipal`, admin.token);
    check('o painel lista rotas e viagens', r.routes.length === 1 && r.trips[0].status === 'completed' && r.trips[0].seatsTaken === 3 && r.commissionRate === 0.05);
    const rid = r.routes[0].id;
    check('o administrador altera o preço e desactiva a rota', (await call('POST', `${P}/admin/intermunicipal/rotas/${rid}`, admin.token, { price: 8500, maxPrice: '', distanceKm: 330, active: false })).s === 200);
    check('rota desactivada deixa de aparecer no app', (await call('GET', `${I}/routes`, drv.token)).routes.length === 0);
    check('e já não aceita viagens novas', (await call('POST', `${I}/trips`, drv.token, { routeId: rid, departAt: tomorrow, seats: 4 })).s === 404);
  }

  group('Entrar com senha');
  {
    check('o app sabe que o código SMS está ligado', (await call('GET', '/auth/options')).otp === true);
    const u = await otp('923000777', 'passenger');
    check('conta nova por SMS ainda não tem senha', u.user.hasPassword === false);
    check('senha curta é recusada', (await call('PUT', '/me/password', u.token, { password: '123' })).s === 400);
    let r = await call('PUT', '/me/password', u.token, { password: 'segredo1' });
    check('a conta nova define a senha', r.s === 200 && r.user.hasPassword === true);
    r = await call('POST', '/auth/password/login', null, { phone: '923 000 777', role: 'passenger', password: 'segredo1' });
    check('entra com o número e a senha', r.s === 200 && Boolean(r.token) && r.user.phone === '+244923000777');
    check('senha errada não entra', (await call('POST', '/auth/password/login', null, { phone: '923000777', role: 'passenger', password: 'errada99' })).s === 401);
    check('número sem conta dá a mesma resposta', (await call('POST', '/auth/password/login', null, { phone: '923000778', role: 'passenger', password: 'segredo1' })).s === 401);
    check('a senha é por tipo de conta', (await call('POST', '/auth/password/login', null, { phone: '923000777', role: 'driver', password: 'segredo1' })).s === 401);
    check('mudar a senha exige a actual', (await call('PUT', '/me/password', u.token, { password: 'outra123' })).s === 400);
    check('muda a senha com a actual', (await call('PUT', '/me/password', u.token, { password: 'outra123', current: 'segredo1' })).s === 200);
    check('não se cria conta sem confirmar o número', (await call('POST', '/auth/password/register', null, { phone: '923000779', role: 'passenger', password: 'segredo1' })).s === 410);
    r = await call('POST', '/auth/password/forgot', null, { phone: '923000777', role: 'passenger' });
    check('senha esquecida: envia código', r.s === 200 && /^\d{6}$/.test(r.devCode));
    check('código errado não repõe a senha', (await call('POST', '/auth/password/reset', null, { phone: '923000777', role: 'passenger', code: r.devCode === '000000' ? '111111' : '000000', password: 'nova1234' })).s === 400);
    r = await call('POST', '/auth/password/reset', null, { phone: '923000777', role: 'passenger', code: r.devCode, password: 'nova1234' });
    check('repõe a senha com o código e entra', r.s === 200 && Boolean(r.token));
    check('a senha antiga deixa de servir', (await call('POST', '/auth/password/login', null, { phone: '923000777', role: 'passenger', password: 'outra123' })).s === 401);

    const adm = admin;
    r = await call('GET', `${P}/admin/acesso`, adm.token);
    check('o painel mostra quantas contas têm senha', r.otp === true && r.passengers.withPassword >= 1 && r.passengers.total > r.passengers.withPassword);
    check('o administrador desliga o código SMS', (await call('POST', `${P}/admin/acesso`, adm.token, { otp: false })).otp === false);
    check('o app fica a saber', (await call('GET', '/auth/options')).otp === false);
    check('com o código desligado, quem tem senha não recebe códigos', (await call('POST', '/auth/otp/request', null, { phone: '923000777', role: 'passenger' })).s === 403);
    check('nem se repõe a senha por SMS', (await call('POST', '/auth/password/forgot', null, { phone: '923000777', role: 'passenger' })).s === 403);
    check('continua a não haver conta sem confirmar o número', (await call('POST', '/auth/password/register', null, { phone: '923000779', role: 'passenger', password: 'segredo1' })).s === 410);
    r = await otp('923000779', 'passenger');
    check('conta nova: o número é sempre confirmado por SMS', Boolean(r.token) && r.isNew === true && r.user.hasPassword === false);
    check('e a seguir define a senha', (await call('PUT', '/me/password', r.token, { password: 'segredo1' })).user?.hasPassword === true);
    check('depois de ter senha, entra só com ela', (await call('POST', '/auth/otp/request', null, { phone: '923000779', role: 'passenger' })).s === 403 && (await call('POST', '/auth/password/login', null, { phone: '923000779', role: 'passenger', password: 'segredo1' })).s === 200);
    check('quem já tinha senha continua a entrar', (await call('POST', '/auth/password/login', null, { phone: '923000777', role: 'passenger', password: 'nova1234' })).s === 200);
    r = await call('POST', `${P}/admin/passageiros/${u.user.id}/senha`, adm.token);
    check('o administrador repõe a senha de uma conta', r.s === 200 && /^\d{8}$/.test(r.password));
    check('a senha provisória entra', (await call('POST', '/auth/password/login', null, { phone: '923000777', role: 'passenger', password: r.password })).s === 200);
    // O app não escolhe: pergunta ao servidor como entrar.
    r = await call('POST', '/auth/start', null, { phone: '923000777', role: 'passenger' });
    check('código desligado: a quem tem senha pede-se a senha', r.method === 'password' && r.reason === 'otp_off' && !r.devCode);
    r = await call('POST', '/auth/start', null, { phone: '923000780', role: 'passenger' });
    check('código desligado: número novo recebe o código para criar conta', r.method === 'otp' && /^\d{6}$/.test(r.devCode) && r.canUsePassword === false);
    await call('POST', `${P}/admin/acesso`, adm.token, { otp: true });
    r = await call('POST', '/auth/start', null, { phone: '923000777', role: 'passenger' });
    check('código ligado: entra-se com o código SMS, e quem tem senha pode usá-la', r.method === 'otp' && /^\d{6}$/.test(r.devCode) && r.canUsePassword === true);
    check('se o código não chega, quem tem senha pode usá-la', (await call('POST', '/auth/start', null, { phone: '923000777', role: 'passenger', noCode: true })).method === 'password');
    check('quem não tem senha continua à espera do código', (await call('POST', '/auth/start', null, { phone: '923000780', role: 'passenger', noCode: true })).method === 'otp');
    check('o código SMS volta a funcionar', (await call('POST', '/auth/otp/request', null, { phone: '923000779', role: 'passenger' })).s === 200);
  }

  group('Criar conta quando o SMS falha');
  {
    let r = await call('POST', '/auth/start', null, { phone: '923000790', role: 'passenger' });
    check('o SMS falha: a conta nova avança na mesma', r.method === 'signup' && r.reason === 'sms_failed' && typeof r.signupTicket === 'string' && !r.devCode);
    const ticket = r.signupTicket;
    check('bilhete inválido não cria conta', (await call('POST', '/auth/signup', null, { ticket: 'x'.repeat(40), password: 'segredo1' })).s === 400);
    check('a senha continua obrigatória', (await call('POST', '/auth/signup', null, { ticket, password: '12' })).s === 400);
    r = await call('POST', '/auth/signup', null, { ticket, password: 'segredo1' });
    check('cria a conta com a senha e o número por confirmar', r.s === 200 && r.isNew === true && r.user.hasPassword === true && r.user.phoneVerified === false);
    const u = r;
    check('o mesmo bilhete não cria outra conta', (await call('POST', '/auth/signup', null, { ticket, password: 'segredo1' })).s === 409);
    check('o bilhete não serve de sessão', (await call('GET', '/me', ticket)).s === 401);
    r = await call('GET', '/me/phone-confirmation', u.token);
    check('com o SMS em baixo, o app ainda não pede o código', r.verified === false && r.canAskNow === false && r.reason === 'sms_down');
    await otp('923000791', 'passenger'); // um SMS sai bem: o envio voltou a funcionar
    r = await call('GET', '/me/phone-confirmation', u.token);
    check('com o SMS a funcionar, é boa altura para pedir', r.canAskNow === true && r.phone === '+244923000790');
    const ride = (await call('POST', '/rides', u.token, { ...trip, category: 'economy' })).ride;
    r = await call('GET', '/me/phone-confirmation', u.token);
    check('numa corrida, não se pede', r.canAskNow === false && r.reason === 'in_ride');
    check('nem se envia o código', (await call('POST', '/me/phone-confirmation/request', u.token)).s === 409);
    await call('POST', `/rides/${ride?.id}/cancel`, u.token);
    r = await call('POST', '/me/phone-confirmation/request', u.token);
    check('fora da corrida, envia o código para o próprio número', r.s === 200 && r.phone === '+244923000790' && /^\d{6}$/.test(r.devCode));
    check('código errado não confirma', (await call('POST', '/me/phone-confirmation/verify', u.token, { code: r.devCode === '000000' ? '111111' : '000000' })).s === 400);
    r = await call('POST', '/me/phone-confirmation/verify', u.token, { code: r.devCode });
    check('o número fica confirmado', r.s === 200 && r.user.phoneVerified === true);
    check('e o app deixa de perguntar', (await call('GET', '/me/phone-confirmation', u.token)).verified === true);
    check('a senha continua a servir', (await call('POST', '/auth/password/login', null, { phone: '923000790', role: 'passenger', password: 'segredo1' })).s === 200);

    // Alguém cria conta com o número de outra pessoa enquanto o SMS falha; o dono recupera-a.
    r = await call('POST', '/auth/start', null, { phone: '923000792', role: 'passenger' });
    const intruso = await call('POST', '/auth/signup', null, { ticket: r.signupTicket, password: 'intruso1' });
    check('conta criada com o número por confirmar', intruso.user?.phoneVerified === false);
    const a = await call('GET', `${P}/admin/acesso`, admin.token);
    check('o painel conta os números por confirmar', a.passengers.unverified >= 1);
    const lista = await call('GET', `${P}/admin/passageiros?q=923000792`, admin.token);
    check('e marca-os na lista de passageiros', lista.passengers[0]?.phoneVerified === false);
    r = await call('POST', '/auth/start', null, { phone: '923000792', role: 'passenger' });
    check('com o SMS a funcionar, o número recebe o código', r.method === 'otp' && /^\d{6}$/.test(r.devCode));
    r = await call('POST', '/auth/otp/verify', null, { phone: '923000792', role: 'passenger', code: r.devCode });
    check('quem recebe o código recupera a conta e escolhe nova senha', r.s === 200 && r.phoneRecovered === true && r.user.phoneVerified === true && r.user.hasPassword === false);
    check('a sessão de quem a criou cai', (await call('GET', '/me', intruso.token)).s === 401);
    check('e a senha dele deixa de servir', (await call('POST', '/auth/password/login', null, { phone: '923000792', role: 'passenger', password: 'intruso1' })).s === 401);
    check('a sessão do dono funciona', (await call('GET', '/me', r.token)).s === 200);

    // Número por confirmar não viaja por conta da empresa (o número pode não ser dele).
    const cid = (await call('POST', `${P}/admin/empresas`, admin.token, { name: 'Banco Mussulo', nif: '5417999002', contactName: 'Sr. Paulo', phone: '923000795', email: '', monthlyLimit: 0 })).id;
    await call('POST', `${P}/admin/empresas/${cid}/colaboradores`, admin.token, { name: 'Ana', phone: '923000794' });
    r = await call('POST', '/auth/start', null, { phone: '923000794', role: 'passenger' });
    const col = await call('POST', '/auth/signup', null, { ticket: r.signupTicket, password: 'segredo1' });
    r = await call('POST', '/rides/estimate', col.token, trip);
    check('o colaborador por confirmar não vê a conta da empresa', !r.paymentMethods.includes('corporate') && r.company === null && r.companyLocked === true);
    check('nem pode pedir por conta dela', (await call('POST', '/rides', col.token, { ...trip, category: 'economy', paymentMethod: 'corporate' })).s === 403);
  }

  group('Um número, um só tipo de conta');
  {
    const p1 = await otp('923000801', 'passenger');
    const d1 = await otp('923000802', 'driver');
    let r = await call('POST', '/auth/start', null, { phone: '923000801', role: 'driver' });
    check('número de passageiro não entra como motorista, e o app sabe qual é', r.s === 409 && r.otherRole === 'passenger' && /passageiro/.test(r.error));
    r = await call('POST', '/auth/start', null, { phone: '923000802', role: 'passenger' });
    check('número de motorista não entra como passageiro', r.s === 409 && r.otherRole === 'driver' && !r.devCode);
    check('com o tipo certo, entra', (await call('POST', '/auth/start', null, { phone: '923000802', role: 'driver' })).method === 'otp');
    check('mudar para um número que é de outro tipo de conta é recusado', (await call('POST', '/me/phone/request', d1.token, { phone: '923000801' })).s === 409);
    r = await call('POST', `${P}/frota/motoristas`, fleet.token, { name: 'Motorista Repetido', phone: '923000801' });
    check('a frota não regista como motorista um número de passageiro', r.s === 409 && /passageiro/.test(r.error));

    // Duplas antigas (de antes da regra): o script desactiva o lado passageiro, sem apagar.
    const { insertedId } = await mongoose.connection.db.collection('passageiros').insertOne({ name: 'Dupla Antiga', phone: '+244923000802', walletBalance: 0, ratingSum: 0, ratingCount: 0, pushTokens: [], sessionVersion: 0, createdAt: new Date() });
    const legacyToken = (await import('jsonwebtoken')).default.sign({ sub: String(insertedId), role: 'passenger' }, TEST_JWT_SECRET, { expiresIn: '1h' });
    const before = await call('GET', '/me', legacyToken);
    const script = (args) => new Promise((resolve) => {
      const child = spawn('npx', ['tsx', 'scripts/desactivar-passageiros-com-numero-de-motorista.ts', ...args], { env: { ...process.env, MONGODB_URI: DB } });
      let out = '';
      child.stdout.on('data', (d) => (out += d));
      child.stderr.on('data', (d) => (out += d));
      child.on('close', () => resolve(out));
    });
    let out = await script([]);
    check('o script, sem --aplicar, só mostra', /1 passageiro\(s\) com número de motorista/.test(out) && (await mongoose.connection.db.collection('passageiros').findOne({ _id: insertedId })).phone === '+244923000802', out.trim());
    out = await script(['--aplicar']);
    const after = await mongoose.connection.db.collection('passageiros').findOne({ _id: insertedId });
    check('com --aplicar, desactiva o passageiro e guarda o número antigo', /1 conta\(s\) desactivada\(s\)/.test(out) && !after.phone && after.formerPhone === '+244923000802' && after.deactivatedAt && after.name === 'Dupla Antiga', out.trim());
    check('antes, a dupla antiga entrava; depois, a sessão dela cai', before.s === 200 && (await call('GET', '/me', legacyToken)).s === 401);
    check('o número fica só do motorista', (await call('POST', '/auth/start', null, { phone: '923000802', role: 'passenger' })).otherRole === 'driver' && (await call('GET', '/me', d1.token)).s === 200);
    const lista = await call('GET', `${P}/admin/passageiros?q=Dupla`, admin.token);
    check('o painel mostra a conta como desactivada', lista.passengers[0]?.deactivated === true && lista.passengers[0].phone === '+244923000802');
    check('correr o script outra vez não muda nada', /0 passageiro\(s\)/.test(await script(['--aplicar'])));
    void p1;
  }

  group('Páginas servidas');
  for (const [path, type] of [['/painel/', 'text/html'], ['/painel/painel.js', 'text/javascript'], ['/painel/fundo.svg', 'image/svg+xml'], [`/acompanhar/${token}`, 'text/html']]) {
    const page = await fetch(B + path);
    check(`${path.replace(token, '<link>')} responde`, page.status === 200 && (page.headers.get('content-type') ?? '').startsWith(type));
  }
  check('carteira desligada responde 403', (await call('GET', '/wallet', pas.token)).s === 403);
}

// ── Arranque e limpeza ──────────────────────────────────────────────────────
if (await fetch(`${B}/health`).then(() => true).catch(() => false)) {
  console.error(`A porta ${PORT} já está ocupada (um teste anterior ficou a correr?). Termine esse processo e repita.`);
  process.exit(1);
}
await mongoose.connect(DB);
await mongoose.connection.dropDatabase();
const server = spawn('npx', ['tsx', 'src/index.ts'], {
  env: { ...process.env, PORT: String(PORT), MONGODB_URI: DB, JWT_SECRET: TEST_JWT_SECRET, NODE_ENV: 'development', ADMIN_EMAIL: '', ADMIN_PASSWORD: '', WALLET_ENABLED: 'false', AUTO_APPROVE_DOCUMENTS: 'true', SMS_PROVIDER: 'console', SMS_FAIL_NUMBERS: '+244923000790,+244923000792,+244923000794', TELCOSMS_API_KEY: '', MAIL_TRANSPORT: 'console', TILE_UPSTREAM: '', FIREBASE_KEY_FILE: '' },
  stdio: ['ignore', 'pipe', 'pipe'],
  // Grupo de processos próprio: no fim mata-se o grupo todo (o npx lança o
  // servidor noutro processo, que sobrevivia e era apanhado pela corrida seguinte).
  detached: true,
});
let log = '';
server.stdout.on('data', (d) => (log += d));
server.stderr.on('data', (d) => (log += d));
try {
  for (let i = 0; i < 60; i++) {
    if (await fetch(`${B}/health`).then((r) => r.ok).catch(() => false)) break;
    if (i === 59) throw new Error(`o servidor de teste não arrancou:\n${log}`);
    await new Promise((r) => setTimeout(r, 500));
  }
  await run();
} catch (err) {
  failures.push(`erro inesperado: ${err.stack ?? err}\n--- registo do servidor ---\n${log.slice(-3000)}`);
} finally {
  try {
    process.kill(-server.pid, 'SIGTERM');
  } catch {
    server.kill();
  }
  await mongoose.connection.dropDatabase();
  await mongoose.disconnect();
}
console.log(`\n${passed} verificações passaram, ${failures.length} falharam.`);
for (const f of failures) console.log(`  ✗ ${f}`);
process.exit(failures.length ? 1 : 0);

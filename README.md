# Bazá Tranquilo

> **Bazá com Segurança.** No dia-a-dia, o nome é simplesmente **Bazá**.

Aplicativo de táxi: um único app Flutter para contas de passageiro e de motorista e uma API em Node.js + TypeScript com MongoDB.

```
backend/   API REST + tempo real (Express, Mongoose, Socket.IO)
app/       App Flutter (Android e iOS)
```

> **Pôr em produção:** ver [`PRODUCAO.md`](PRODUCAO.md) — servidor, mapas próprios, HTTPS, push, lojas e iPhone.

## Correr o backend

Requisitos: Node.js 20+ e MongoDB a correr localmente.

```bash
cd backend
npm install
cp .env.example .env   # já existe um .env de desenvolvimento
npm run dev            # http://localhost:4000
```

Em desenvolvimento (`NODE_ENV=development`):

- o código SMS aparece no log do servidor e no ecrã de login do app;
- os pagamentos electrónicos são simulados (`PAYMENT_PROVIDER=mock`) e aprovados de imediato.

## Correr o app

```bash
cd app
flutter pub get
flutter run                                             # emulador
flutter run --dart-define=API_URL=http://192.168.1.10:4000   # telemóvel real (IP do computador)
flutter test
```

Sem `API_URL`, o app usa `http://10.0.2.2:4000` no emulador Android e `http://localhost:4000` no simulador iOS.

Para testar uma corrida completa são precisas duas contas (dois dispositivos ou emuladores): uma pede a corrida, a outra é criada como **Motorista**, regista a viatura, fica online perto do ponto de recolha e aceita.

## Como funciona

- **Contas**: passageiros e motoristas ficam em colecções separadas (`passageiros` e `motoristas`). Cada número de telefone só pode ter um tipo de conta (regra de 2026-11-24): o servidor recusa o número no outro tipo com `409` e `otherRole`, e o app oferece entrar no tipo certo. No ecrã de entrada entra-se por defeito como passageiro; o botão "Sou motorista" / "Sou passageiro" no cartão do topo troca, e o app lembra-se da escolha neste aparelho. O tipo fica sempre à vista num cartão amarelo (passageiro) ou escuro (motorista). As duplas de antes da regra desactivam-se com `backend/scripts/desactivar-passageiros-com-numero-de-motorista.ts`. Cada conta tem carteira, avaliação e foto próprias.
- **Login**: o utilizador escreve só o número e toca em "Continuar"; o servidor decide o passo seguinte (`POST /auth/start`), conforme o painel › Definições — não há botão para escolher. Com o código SMS ligado, pede o código; no ecrã do código, quem já tem senha vê "Não tem o telefone consigo? Entrar com a senha"; a senha é ainda pedida automaticamente se o envio do SMS falhar ou se o código não for introduzido ao fim de 1 minuto. Ao criar a conta, o número é confirmado por SMS e a seguir escolhe-se a senha; se o envio do SMS falhar, a conta cria-se na mesma só com a senha (`POST /auth/signup`, com o bilhete que `/auth/start` devolve) e o número fica por confirmar — o app pede o código mais tarde (`GET/POST /me/phone-confirmation…`), quando o SMS estiver a funcionar e a pessoa não estiver numa corrida, e quem confirmar o número no ecrã de entrada recupera a conta; as contas antigas sem senha são convidadas a criá-la ao abrir o app. A senha muda-se em "Os meus dados". O login por email continua descontinuado. O painel web entra com email e palavra-passe.
- **Código SMS desligado** (painel › Definições): a quem já tem conta com senha o app pede a senha, sem enviar SMS. Criar conta continua a pedir a confirmação do número por SMS (e quem ainda não tem senha também recebe o código, para a criar). A senha esquecida repõe-se no painel (botão "Repor senha" em Motoristas / Passageiros, que mostra uma senha provisória uma única vez). Tentativas de senha limitadas a 10 por número em cada 15 minutos.
- **Registo de motorista**: carta de condução (número, categoria, validade) e viatura. Com a carta caducada não pode ficar online.
- **Os meus dados**: no menu, pelo botão de editar junto ao nome, o utilizador edita nome, email de contacto, telefone (o número novo é confirmado por SMS) e contacto de emergência.
- **Foto de perfil**: no menu, tocando no avatar. Fica guardada no MongoDB (GridFS).
- **Motoristas preferidos**: no fim de uma corrida o passageiro pode adicionar o motorista aos preferidos. Ao pedir, pode chamar um preferido que esteja disponível: o pedido fica reservado a esse motorista durante 30 segundos e, se ele recusar ou não responder, passa para os motoristas próximos.
- **Carteira**: o motorista recebe os ganhos na carteira, pode pedir levantamento para um IBAN (mínimo 1 000 Kz) e deixa de poder ficar online se dever mais de 5 000 Kz em comissões.
- **Serviços**: viagens (Moto, Triciclo, Económico, Conforto, XL) e carga/entregas (Entrega de moto, Triciclo de carga, Carrinha, Camião). Nos serviços de carga o cliente descreve o que vai transportar e pode pedir até 3 ajudantes. O catálogo e as tarifas estão em `backend/src/config.ts`.
- **Passageiro**: escolhe recolha e destino, vê o preço de cada serviço, escolhe o pagamento e pede. Acompanha o motorista no mapa e avalia no fim.
- **Motorista**: fica online, recebe ofertas da categoria da viatura activa num raio de 6 km, aceita e avança os estados (Cheguei → Iniciar → Terminar).
- **Viaturas**: o motorista pode registar até 5 viaturas de categorias diferentes em "As minhas viaturas" e escolhe com qual conduz; só troca estando offline.
- **Identidade visual**: logótipo em `app/assets/brand/mark.svg`, do qual foram gerados os ícones Android, iOS e web. No ecrã principal o logótipo fica no canto superior esquerdo e o menu no direito.
- **Negociação de preço**: o passageiro pode propor um preço diferente do da tarifa (entre 50 % e 300 %, em passos de 50 Kz). Cada motorista aceita esse preço ou responde com outro; o passageiro aceita uma proposta, recusa-a ou muda o seu preço, até haver acordo. A comissão incide sobre o preço combinado.
- **Documentos do motorista** (todos obrigatórios para conduzir): foto de perfil; carta de condução (dados e fotos da frente e do verso); e, por cada viatura, livrete, título de propriedade e seguro (com validade). Ficam no MongoDB (GridFS, `fs.files`), são privados e passam por revisão: em desenvolvimento são aprovados automaticamente; em produção um administrador revê-os no painel web. Com a carta ou o seguro caducados o motorista não fica online.
- **Conforto**: uma viatura com ar condicionado pode ser Conforto e recebe pedidos Conforto e Económico; um Económico só recebe Económico.
- **Locais guardados**: Casa, Trabalho e outros, guardados a partir do ponto onde o passageiro está (ou procurando um endereço).
- **Colecções** (em português): `passageiros`, `motoristas`, `corridas`, `codigos_otp`, `movimentos_carteira`, `pagamentos`, `levantamentos`.
- **Pagamento**: dinheiro, carteira Bazá ou Multicaixa Express. A plataforma fica com 15 % de comissão: em corridas a dinheiro a comissão é debitada da carteira do motorista; nas restantes o motorista recebe o valor líquido na carteira.
- **Comissão**: 15 %, em `backend/src/config.ts`.

## SMS (códigos de confirmação)

- Com `TELCOSMS_API_KEY` no `backend/.env`, os códigos de entrada e de mudança de telefone são enviados por SMS pela TelcoSMS e deixam de aparecer no ecrã do app. `SMS_PROVIDER=console` volta ao modo simulado (o código aparece no ecrã e no log).
- Só são aceites telemóveis angolanos (9 dígitos começados por 9).
- Cada número pode pedir um código por minuto e no máximo 5 por hora, para proteger o saldo.
- O saldo de SMS aparece no resumo do painel do administrador.
- Os testes automáticos (`npm run test:e2e`) correm sempre em modo simulado e não gastam SMS.

## E-mail

- Com `SMTP_USER` no `backend/.env`, os e-mails saem por SMTP (Hostinger), com um Web App do Google Apps Script como reserva se o SMTP falhar. `MAIL_TRANSPORT=console` volta ao modo simulado.
- Usos: aviso à frota quando é aprovada e aviso ao motorista (se tiver email na conta) quando um documento é rejeitado.
- O remetente tem de ser do domínio da conta SMTP. O serviço está em `backend/src/services/email.ts`.

## Versão para computador

Na web, em ecrãs com 900 px ou mais, o app aparece numa janela centrada com as medidas de um telemóvel grande, sobre um fundo com a marca (`app/lib/widgets/desktop_frame.dart`). Os ecrãs são os mesmos do telemóvel. As janelas e os painéis inferiores não fecham ao tocar fora: fecham pelos botões ou pela pega.

## Testes

```bash
cd backend && npm run test:e2e    # API de ponta a ponta, numa base de dados só de teste (baza_teste)
cd backend && npm run typecheck
cd app && flutter test            # ecrãs e componentes do app
```

O teste da API arranca um servidor próprio na porta 4100 e apaga a base de dados de teste no início e no fim; não toca nos dados reais.

## Painel web (administrador e frotas)

Com o backend a correr, o painel abre em **http://localhost:4000/painel**. É HTML, CSS e JavaScript simples, em `backend/panel/`.

- **Ficha do motorista** (Motoristas › "Ver ficha"): dados, sinais de alerta (carta ou seguro caducados, avaliações baixas, cancelamentos tardios, alertas SOS), números, documentos com fotografias, últimas corridas e pedidos de suporte. É a partir dela que se suspende ou reactiva; suspender exige um motivo, que fica registado (com data e autor) e que o motorista lê no app ao tentar ficar online.
- **Avisos** (Atendimento › Avisos, e botão "Avisar" nas listas de Motoristas e Passageiros): a equipa envia um aviso a uma pessoa, a todos os motoristas ou a todos os passageiros. No app aparece numa janela que só sai com "Entendi", chega por notificação (evento `notice:new`) e fica em Menu › Avisos do Bazá. O painel mostra quem já leu. Colecção `avisos`.
- **Frotas com utilizadores próprios:** cada frota tem os seus utilizadores no painel (`utilizadores_painel`): os gestores registam, desactivam e removem os colegas; os operadores só usam o painel. Quem regista a frota é o seu primeiro gestor.
- **Postos policiais e agentes** (Instituições › Postos policiais): o administrador regista os postos por província e município, com a posição no mapa, e os agentes de cada posto (nome, patente, telefone). Não há painel para a polícia: **o agente usa a mesma aplicação**. Ao entrar com o seu número, o servidor reconhece-o (`/auth/start` e `/auth/otp/verify` respondem como para qualquer número; depois do código vem um "bilhete" e, com a senha, abre-se a sessão em `/agent/session`). Nada no app mostra que essa área existe.
  - O número de um agente é exclusivo: não pode ter conta de passageiro nem de motorista, nem ser usado para criar uma.
  - A conta fica associada ao primeiro telemóvel; noutro aparelho só entra depois de o administrador autorizar. O administrador pode ainda repor a senha, desactivar ou remover o agente.
  - **Alerta de perigo:** no app, SOS › "Perigo: avisar as autoridades". O alerta vai para os postos a menos de 10 km do local (ou os dois mais próximos); os agentes de serviço recebem uma notificação com sirene, mesmo com o app fechado. Sem agentes de serviço, o posto recebe um SMS (só em produção). Se ninguém assumir em 2 minutos, sobe para o comando provincial.
  - **O agente** vê a corrida só enquanto o alerta está aberto: mapa com a viatura em movimento, matrícula, percurso, motorista e passageiro (com botão para ligar), "Assumo este alerta", navegar até à viatura e fechar com o relato do que foi feito. Não há pesquisa livre de pessoas, viaturas ou corridas.
  - **Quem pediu ajuda** vê a que postos foi o alerta e quem o assumiu; para o cancelar (engano) tem de escrever a senha.
  - **Som da viagem:** com o alerta aberto, quem pediu ajuda pode ligar "Partilhar o som da viagem". O telemóvel grava em blocos de 8 segundos (WAV mono a 8 kHz, cerca de 1 MB por minuto) e envia-os (`PUT /rides/:id/sos/audio`); o agente ouve em directo ou desde o início. O som é apagado 30 dias depois de o alerta ser fechado. No Android, um serviço em primeiro plano do tipo microfone (`AlertAudioService.kt`, ligado por `alert_audio.dart`) mantém a gravação com o ecrã bloqueado ou com outra app aberta, com uma notificação permanente "A partilhar o som da viagem". Na versão web só grava com a página aberta.
  - **Pessoa de confiança:** se o contacto de emergência de quem pediu ajuda tiver conta de passageiro no Bazá, é avisado e acompanha no app o mesmo que a polícia (mapa, viatura, som), enquanto o alerta estiver aberto (`/guardian/alerts`). Não assume nem fecha o alerta.
  - Cada acesso fica em `consultas_entidades` e aparece no painel, em Postos policiais. Código: `backend/src/routes/agent.ts`, `backend/src/models/police.ts`, `app/lib/screens/agent_screen.dart`.
- **Frotas:** além do resumo, mapa e corridas, têm a ficha de cada motorista (só leitura), avisos aos seus motoristas, alertas SOS dos seus motoristas, contas por motorista e por período (com exportação para Excel), dados da empresa e utilizadores.
  - **Acertos** (Finanças): a regra combinada com cada motorista — percentagem do que facturou, ou valor fixo por dia trabalhado (a "conta" diária) —, o que tem de entregar, o que já entregou e o saldo. Mudar a regra recomeça a contagem.
  - **Viaturas** (Operação): as viaturas da empresa, a quem estão entregues, as datas do seguro, da inspecção e da próxima revisão (a vermelho se vencidas, a amarelo se faltam menos de 15 dias) e as despesas por viatura (combustível, oficina, multas, seguro).
  - **Turnos** (Operação): o horário semanal de cada motorista; a página mostra quem está de turno e não está online. Os turnos podem passar da meia-noite.
  - Colecções: `frota_acertos`, `frota_entregas`, `frota_viaturas`, `frota_despesas`, `frota_turnos`. É um registo interno da frota: não altera as viaturas que o motorista regista no app.
- **Organização:** menu por grupos (Operação, Pessoas, Finanças, Atendimento, Sistema), com ícones desenhados em linha no próprio `painel.js`. Tudo o que se configura (comissões, mensalidades, código SMS) está numa só página, **Definições**; as páginas de Comissões e Mensalidades mostram só as contas. Criar e editar faz-se em janelas (função `modal()` em `painel.js`). Tema claro ou escuro, pelo botão no fundo do menu (`tema.js`; a escolha fica guardada no navegador).

- **Administrador**: em desenvolvimento há uma conta por defeito — `admin@baza.ao` / `baza-admin` — e o painel pede para trocar a palavra-passe. Em produção essa conta não é criada: o primeiro administrador vem de `ADMIN_EMAIL` / `ADMIN_PASSWORD` no `.env`. Na secção **Administradores** criam-se e removem-se outras contas de administrador. O painel tem ainda o resumo da plataforma, a revisão de documentos (carta e livrete, com as fotos), motoristas (pesquisar, suspender), frotas (aprovar, suspender), passageiros, corridas, mapa ao vivo e alertas SOS.
- **Frota**: a empresa regista-se no próprio painel e fica à espera de aprovação. Depois regista motoristas (que entram no app com esse telefone), acompanha-os no mapa, vê as corridas e a facturação, e tem um código para motoristas já registados se juntarem (no app, menu **Frota**).

## Mapas próprios

Em desenvolvimento, o Bazá usa os serviços públicos do OpenStreetMap, que não permitem uso comercial. Para produção, a pasta `mapas/` corre os mesmos serviços na nossa máquina, com dados de Angola:

| Serviço | Programa | Porta local |
|---|---|---|
| Imagens do mapa | TileServer GL + extracto Protomaps (`angola.pmtiles`) | 8080 |
| Rotas e tempos | OSRM | 5000 |
| Pesquisa de locais e moradas | Photon | 2322 |

```sh
cd mapas
./preparar.sh          # 1.ª vez e para actualizar os dados (10–30 min)
docker compose up -d
```

Depois, em `backend/.env`:

```
OSRM_URL=http://127.0.0.1:5000
PHOTON_URL=http://127.0.0.1:2322
NOMINATIM_URL=
TILE_UPSTREAM=http://127.0.0.1:8080/styles/baza/256/{z}/{x}/{y}@2x.png
```

O app pergunta à API (`GET /map/config`) se há mapas próprios e, havendo, carrega as imagens por `GET /map/tiles/{z}/{x}/{y}.png`; o telemóvel só fala com a API. O estilo do mapa está em `mapas/tiles/styles/baza.json` (gerado por `mapas/tiles/gerar-estilo.mjs`). Não há trânsito em tempo real.

## Dois modelos de serviço

| | Corridas com tarifa | Serviços de preço combinado |
|---|---|---|
| Viaturas | Moto, Económico, Conforto | Triciclo, XL, Entrega, Triciclo de carga, Carrinha, Camião |
| Preço | Calculado pela tarifa; pode ser negociado dentro de limites | Combinado entre cliente e motorista: o cliente descreve o serviço, os motoristas propõem o preço |
| Destino | Obrigatório | Opcional ("destino a combinar") |
| O que o motorista paga ao Bazá | Comissão por corrida (percentagem definida no painel › Comissões) | Mensalidade por viatura registada (valor por tipo, definido no painel › Mensalidades) |

- No app, o passageiro pede os serviços de preço combinado em "Triciclo, XL, carrinha ou camião · preço a combinar".
- A marca `negotiated` no catálogo (`backend/src/config.ts`) é o que distingue os dois modelos.
- **Comissões:** nas corridas em dinheiro ficam em dívida na conta do motorista (colecção `comissoes`). Por omissão a dívida só é registada; `COMMISSION_ENFORCED=true` bloqueia quem passar o limite.
- **Mensalidades:** uma viatura nova tem `SUBSCRIPTION_TRIAL_DAYS` dias grátis a contar da primeira vez que fica online; depois, com a mensalidade em atraso, não fica online. Com a mensalidade a 0, o tipo é gratuito.
- **Pagamentos:** o motorista paga fora do app (transferência, dinheiro) e comunica o pagamento em "Pagamentos e mensalidades", por viatura; a equipa confirma no painel › Pagamentos, e só então a mensalidade é prolongada ou a dívida abatida. O painel também permite registar um pagamento directamente.

## Suporte, cancelamentos e recibos

- **Suporte:** "Ajuda e suporte" no menu do app e "Reportar problema" em cada corrida do histórico; os pedidos são respondidos no painel › Suporte e a resposta aparece no app.
- **Cancelamentos tardios:** o passageiro cancela sem penalização até `CANCEL_GRACE_SECONDS` depois de o motorista aceitar; depois disso, ou com o motorista no local, conta como tardio. Para o motorista, desistir de uma corrida aceite conta sempre. `CANCEL_MAX_LATE` em 24 h suspendem a conta por `CANCEL_SUSPEND_MINUTES`.
- **Recibo:** enviado por e-mail no fim da corrida (se o passageiro tiver e-mail) e disponível no histórico do app, com partilha.
- **Limite de pedidos:** 600 por minuto por conta (ou por IP sem sessão); as imagens do mapa têm um limite próprio.

## Locais registados e utilizadores estrela

Os dados do OpenStreetMap são pobres fora de Luanda (ex.: ~430 locais no Zaire contra ~19 000 em Luanda). Para compensar, o Bazá tem um registo próprio de locais (colecção `locais`), que aparecem primeiro na pesquisa do app:

- **No mapa do app:** os locais registados aparecem com um ponto amarelo e o nome, a partir de uma certa ampliação, e actualizam-se quando o mapa se move (`GET /places/near`).
- **Painel › Locais:** o administrador escolhe a província, clica no mapa e dá o nome ao local.
- **Utilizadores estrela:** no painel (Motoristas / Passageiros), o botão "Tornar estrela" dá a essa pessoa o menu **Registar locais** no app: grava o ponto onde ela está, com o nome por que o sítio é conhecido (`POST /places/contributions`, máx. 60 por dia). O painel mostra quem registou cada local, marca os que estão por rever e permite aprová-los ou removê-los (`STAR_PLACES_NEED_APPROVAL=true` esconde-os da pesquisa até serem aprovados).
- A pesquisa mostra primeiro os resultados a menos de 80 km de quem pesquisa.

## Empresas clientes

- **O que é:** uma empresa (hotel, banco, ONG) cujos colaboradores viajam "por conta da empresa". O passageiro não paga ao motorista; a empresa recebe a conta no fim do mês.
- **Painel › Instituições › Empresas clientes:** o administrador regista a empresa (com limite mensal opcional) e os colaboradores autorizados, pelo telefone com que entram no app como passageiros. "Conta do mês" lista as corridas, o que foi pago e o que falta, e regista os pagamentos da empresa.
- **No app:** o colaborador vê "Conta da empresa" como forma de pagamento (a primeira da lista). Só serve para corridas com tarifa; acima do limite do mês a opção é recusada. O limite é verificado ao pedir a corrida.
- **O motorista** é avisado de que não deve cobrar. O valor da corrida, menos a comissão, fica a crédito na sua conta com o Bazá: abate às comissões que deva e o resto fica "a receber" (saldo negativo em `commissionDue`). O Bazá paga por fora e regista em Finanças › Comissões › "A pagar aos motoristas".
- Código: `backend/src/services/corporate.ts`, rotas `/admin/empresas` em `panel.ts`. Colecções `empresas_clientes` e `pagamentos_empresas`; movimentos `credit` e `payout` em `comissoes`.

## Táxi intermunicipal

- **Rotas e preços:** a equipa define no painel › Intermunicipal as rotas entre municípios (cada uma serve nos dois sentidos) e o preço por passageiro. Com "Preço máximo", o motorista pode pedir entre metade do preço e esse máximo; sem ele, o preço é fixo.
- **Motorista** (menu › Viagens entre municípios): publica a viagem — rota e sentido, dia e hora, lugares a preencher pelo app, preço por passageiro, ponto de encontro e uma nota (ex.: quanto cobra pela carga extra). Vê as reservas com o contacto de cada passageiro, confirma ou recusa, acerta os lugares (ex.: vendeu um fora do app) e marca "Partir" e "Concluir". Só motoristas com documentos aprovados e viatura activa; até 6 viagens em aberto, até 30 dias à frente.
- **Passageiro** (ecrã inicial › Viagens entre municípios): procura por origem e destino, reserva um ou mais lugares e deixa um recado (bagagem). O lugar só fica garantido quando o motorista confirma — é aí que os lugares livres diminuem. Com a reserva confirmada vê o telefone do motorista. Paga em dinheiro ao motorista.
- **Avisos:** nova reserva, confirmação, recusa, desistência, cancelamento e partida chegam por notificação (evento `intercity:update`).
- **Comissão:** percentagem do valor dos lugares confirmados no app (painel › Intermunicipal, 10 % por omissão, pode ser 0), somada às comissões do motorista quando conclui a viagem.
- Código: `backend/src/routes/intercity.ts`, `backend/src/models/intercity.ts`, `app/lib/screens/intercity_screen.dart`. Colecções `rotas_intermunicipais` e `viagens_intermunicipais`.

## Notificações e segundo plano

- **Avisos por voz ao passageiro** : um toque e uma frase gravada quando o motorista aceita ("O seu motorista aceitou a corrida e já está a caminho"), quando chega ("…já chegou e está à sua espera"), quando a viagem começa ("Bem-vindo ao Bazá Tranquilo. Bazá com segurança. Ponha o cinto e boa viagem!") e quando termina. As gravações estão em `app/assets/sounds/voz_*.wav` (voz pt-PT gerada no Mac com `say -v Joana`); com o app em segundo plano ou fechado, a mesma gravação toca como som da notificação push (cópias em `app/android/app/src/main/res/raw/`, um canal de notificação por frase, `baza_voz_*`). Para mudar uma frase, substituir o ficheiro nas duas pastas; como o som de um canal Android não muda depois de criado, uma gravação nova só se ouve nas notificações após reinstalar o app ou mudar o nome do canal.

- **Localização em segundo plano (Android):** com o motorista online, um serviço com notificação permanente mantém o envio da posição com o Bazá em segundo plano ou com o ecrã bloqueado.
- **Notificações locais (Android):** nova corrida, chamada, mensagem e mudanças de estado da corrida aparecem na barra de notificações quando o app não está no ecrã. Funcionam enquanto o app está vivo em segundo plano.
- **Notificações push (Firebase, Android):** o servidor envia-as a quem não tem o app ligado (nova corrida, estado da corrida, mensagem, chamada perdida). Precisa de `app/android/app/google-services.json` e da chave da conta de serviço em `backend/firebase-chave.json` (fora do git).

## Termos, privacidade e eliminação de conta

- Páginas públicas `GET /termos` e `GET /privacidade` (texto em `backend/src/routes/legal.ts`; nome da empresa e contactos em `LEGAL_ENTITY`, `SUPPORT_EMAIL`, `SUPPORT_PHONE`). O texto é um rascunho: deve ser revisto por um advogado.
- `DELETE /me` elimina a conta: apaga dados pessoais, fotos, documentos e mensagens; as corridas ficam sem ligação à pessoa. No app: Os meus dados › Eliminar conta.

## Acompanhamento em tempo real

- A posição do motorista é enviada sempre que ele se desloca (de 10 em 10 metros) e o marcador desliza no mapa do passageiro.
- Durante a corrida o mapa acompanha o carro; se o utilizador arrastar o mapa, deixa de o seguir até tocar em "recentrar".
- De 15 em 15 segundos o servidor recalcula o percurso e o tempo que faltam (`GET /rides/:id/eta`): até ao ponto de recolha enquanto o motorista vai a caminho, e até ao destino durante a viagem.
- O motorista tem o botão **Navegar**, que abre a aplicação de mapas do telemóvel com as indicações até ao passageiro ou ao destino.

## Chat e chamadas

Com motorista atribuído, passageiro e motorista têm os botões **Mensagem** e **Ligar**.

- **Chat**: guardado por corrida (colecção `mensagens`), chega em tempo real, tem respostas rápidas e fecha quando a corrida termina.
- **Chamada no app**: voz pela internet (WebRTC), sem mostrar o número. O áudio vai directamente de um telemóvel ao outro; o servidor só encaminha a sinalização (`call:signal`) pelo mesmo canal do chat. Só toca se a outra pessoa tiver o app aberto.
- **Chamada pelo telefone**: o ícone do teclado ao lado de "Ligar" abre o telefone com o número da outra pessoa, como alternativa.
- **Redes móveis**: por omissão usa-se só STUN público. Para as chamadas ligarem em todas as redes é preciso um servidor TURN — definir `TURN_URL`, `TURN_USERNAME` e `TURN_PASSWORD` no `.env`.

## Segurança na viagem

- **Partilhar viagem**: durante a corrida, gera um link (`/acompanhar/<segredo>`) que qualquer pessoa abre no browser para seguir a viagem no mapa, sem a app. Para funcionar fora desta máquina, definir `PUBLIC_URL` com o endereço público do servidor.
- **SOS**: liga para o número de emergência (`EMERGENCY_NUMBER`, 111 por omissão), regista o alerta (colecção `alertas_sos`, visível no painel) e permite enviar a viagem por SMS ao contacto de emergência definido em "Os meus dados".

## O que falta para produção

| Área | Estado | Onde ligar |
| --- | --- | --- |
| SMS | Ligado à TelcoSMS quando há `TELCOSMS_API_KEY` no `.env`; o fornecedor indica o plano como expirado — confirmar que os envios estão activos | `backend/src/services/sms.ts` |
| Multicaixa Express | Não implementado (exige contrato e credenciais EMIS) | `emisProvider` em `backend/src/services/payments.ts` |
| Mapas | Servidores públicos do OpenStreetMap, OSRM e Nominatim, que não permitem uso comercial intensivo | `OSRM_URL`, `NOMINATIM_URL` no `.env` e `urlTemplate` em `app/lib/widgets/baza_map.dart` |
| Motoristas | A carta e a viatura são apenas declaradas; não há envio de documentos nem aprovação | — |
| Carteira | Desligada (`WALLET_ENABLED=false`): sem saldo, sem pagamento por carteira, sem comissões debitadas | `.env` |
| Segredos | Definir `JWT_SECRET` e `NODE_ENV=production` | `.env` |

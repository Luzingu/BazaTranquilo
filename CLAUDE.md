# Bazá — instruções do projecto

App de táxi para Angola (nome completo "Bazá Tranquilo", lema "Bazá com Segurança"). Responder ao utilizador em português.

- `backend/` — API Node.js + TypeScript + Express + MongoDB (também serve o painel web, as páginas legais e a partilha de viagem)
- `app/` — app Flutter (Android, web; iPhone ainda não compilado)
- `mapas/` — mapas próprios em Docker (imagens do mapa, rotas, pesquisa de locais)
- `site/` — página inicial pública (`https://bazatranquilo.com/`), um só `index.html` estático; é a que os motores de busca lêem. Só afirmar nela o que o app faz de facto (sem preços, contactos ou cidades inventados)
- `README.md` — o que cada parte faz e como correr em desenvolvimento
- `PRODUCAO.md` — guia completo para pôr em produção (**fonte de verdade; manter actualizado**)

## Modelo de negócio (decidido pelo utilizador)

- Moto, Económico e Conforto: preço pela tarifa, comissão por corrida (percentagem alterável no painel).
- Triciclo, XL e todos os serviços de carga: preço combinado entre cliente e motorista, destino opcional, sem comissão; pagam mensalidade por viatura registada (valor por tipo, alterável no painel).

- Empresas clientes: colaboradores autorizados no painel viajam "por conta da empresa"; o motorista não cobra e fica com o valor (menos a comissão) a receber do Bazá; a empresa paga a conta do mês ao Bazá.
- Táxi intermunicipal: rotas e preço por passageiro definidos no painel; o motorista publica viagens (dia, hora, lugares, nota sobre carga) e os passageiros reservam lugares, que diminuem a cada confirmação do motorista. Comissão própria sobre os lugares confirmados (percentagem no painel).

## Polícia e frotas (decidido pelo utilizador)

- As frotas usam o painel web, cada uma com os seus utilizadores (gestor e operador).
- A polícia NÃO tem painel nem app própria: o administrador regista os postos policiais (por província e município) e os seus agentes, e o agente usa a mesma aplicação. Ao entrar com o número registado, abre-se a área do agente. Essa área fica oculta: não criar nenhum botão, opção ou texto que a revele a passageiros e motoristas.
- O número de um agente é exclusivo: não pode ser usado por passageiros nem motoristas.
- Os agentes só têm acesso a uma corrida quando o passageiro ou o motorista acciona o alerta de perigo, e só enquanto o alerta estiver aberto. Não criar pesquisas livres de pessoas, viaturas ou corridas para a polícia.

## Entrada no app (decidido pelo utilizador)

- Entrar: o utilizador escreve só o número; o servidor decide se pede o código SMS ou a senha, conforme o painel (Definições). No primeiro ecrã NÃO há botão "entrar com senha"; no ecrã do código, quem tem senha pode optar por ela ("Não tem o telefone consigo?"), e a senha é pedida automaticamente quando o código está desligado, o envio do SMS falha ou o código não chega. Criar conta: o número é confirmado por SMS e só depois se define a senha (obrigatória). O login por email continua descontinuado.
- **Se o SMS falhar ao criar a conta, a pessoa avança na mesma** (decidido pelo utilizador, 2026-11-24): o servidor dá um bilhete de 15 min (`/auth/start` → `method: signup`), a pessoa escolhe a senha (`POST /auth/signup`) e a conta fica com `phoneVerified: false`. O app pede a confirmação mais tarde (`app/lib/widgets/phone_confirm.dart`), **só quando o SMS está a funcionar** (`smsLooksHealthy()`: sem falha nos últimos 10 min e com saldo na TelcoSMS) **e a pessoa não está numa corrida** (nem, sendo motorista, online); "Agora não" adia 2 h, 12 h e depois 1 dia; há também um aviso "Número por confirmar" no menu e em "Os meus dados". Só conta como falha um erro do servidor ou da operadora (5xx), não o limite de envios nem um número não angolano.
- Até confirmar, a conta **não viaja por conta de empresa**. Quem confirmar depois o número por SMS no ecrã de entrada é o dono: a conta passa a confirmada, as sessões antigas caem (`sessionVersion`) e a senha volta a ser definida.

## Um número, um só tipo de conta (decidido pelo utilizador, 2026-11-24)

- O mesmo telefone **não pode** ser de um passageiro e de um motorista. O servidor verifica em todos os sítios onde se cria conta ou se muda de número (`assertPhoneFreeForRole` em `backend/src/models/accounts.ts`: `/auth/start`, `/auth/otp/*`, `/auth/signup`, mudar telefone, frota a registar motorista) e responde `409` com `otherRole`.
- No ecrã de entrada **entra-se por defeito como passageiro** (decidido pelo utilizador, 2026-11-24); o cartão do topo (amarelo para passageiro, escuro para motorista) tem o botão "Sou motorista" / "Sou passageiro" numa linha própria, que troca de uma vez, e o app lembra-se da escolha neste aparelho (`lastRole`). Os Termos ficam num rodapé que se ajusta ao ecrã (no fundo em ecrãs altos; a seguir ao botão em ecrãs pequenos ou com o teclado aberto). Se o número for do outro tipo, o app pergunta "Este número é de motorista — Entrar como motorista?" antes de enviar qualquer SMS.
- Duplas antigas: fica a conta de motorista; a de passageiro é **desactivada, sem apagar** (`deactivatedAt`, telefone em `formerPhone`), com `backend/scripts/desactivar-passageiros-com-numero-de-motorista.ts --aplicar` (ver `PRODUCAO.md`). Conta desactivada não entra (sessões e ligações em tempo real caem).

## Regras

- Sempre que alguém define ou muda uma senha (app ou painel), o formulário pede-a duas vezes (campo de confirmação).
- Segredos só em `backend/.env` e `backend/firebase-chave.json`. Nunca em código, git, registos ou mensagens.
- O servidor de desenvolvimento envia SMS e e-mails reais: para testar, usar `cd backend && npm run test:e2e` (modo simulado, base de dados própria).
- Nunca apagar em massa colecções da base `baza`: tem dados reais.
- Sempre que mudar algo que afecte a instalação (variável de ambiente nova, serviço novo, passo de compilação, permissão do app), actualizar `PRODUCAO.md` e o resumo abaixo na mesma alteração.

## Pôr em produção — resumo dos passos

Detalhes, comandos e tabelas em `PRODUCAO.md`. A instalação num servidor real ainda não foi feita: validar cada passo na primeira vez.

1. **Servidor:** Linux com 4 GB de memória, Node.js 22+, Docker, MongoDB, `curl` e `zstd`; um domínio a apontar para ele. Copiar o projecto sem `node_modules`, `app/build` e `mapas/dados`.
2. **Mapas próprios:** em `mapas/`, correr `./preparar.sh` (descarrega e prepara Angola) e depois `docker compose up -d`. Portas locais: mapa 8080, rotas 5000, pesquisa 2322. Com o Docker parado não há mapa nem pesquisa. Actualizar os dados mensalmente com os mesmos dois comandos (`--force-recreate` no segundo).
3. **API:** em `backend/`, `npm ci && npm run build`, criar `.env` a partir de `.env.example` e arrancar com `node dist/index.js` a partir dessa pasta (serviço systemd). Em produção definir, no mínimo:
   - `NODE_ENV=production`, `JWT_SECRET` novo (o servidor recusa arrancar sem ele), `PUBLIC_URL`
   - `ADMIN_EMAIL` e `ADMIN_PASSWORD` (a conta por defeito do painel não existe em produção)
   - `AUTO_APPROVE_DOCUMENTS=false`
   - `OSRM_URL=http://127.0.0.1:5000`, `PHOTON_URL=http://127.0.0.1:2322`, `NOMINATIM_URL=` (vazio), `TILE_UPSTREAM=http://127.0.0.1:8080/styles/baza/256/{z}/{x}/{y}@2x.png`
   - SMS (`TELCOSMS_API_KEY`), e-mail (`SMTP_*`), contactos legais (`LEGAL_ENTITY`, `SUPPORT_EMAIL`, `SUPPORT_PHONE`)
   - `COMMISSION_PAY_INFO` (como os motoristas pagam comissões e mensalidades)
4. **HTTPS:** proxy (Caddy ou Nginx) à frente da porta 4000, com WebSocket; fechar as restantes portas. Sem HTTPS o app não liga.
5. **Push:** `app/android/app/google-services.json` no projecto e a chave da conta de serviço do Firebase em `backend/firebase-chave.json`.
6. **App:** `flutter build appbundle --release --dart-define=API_URL=https://<domínio>`. A versão *release* já é assinada com a chave de loja do Bazá (`app/android/key.properties`). Antes da Play Store: subir a versão, indicar os endereços `/termos` e `/privacidade`.
7. **Painel:** em Definições, a percentagem de comissão das corridas, a comissão intermunicipal e a mensalidade por tipo de viatura; em Intermunicipal, as rotas com o preço por passageiro. Em "Definições" liga-se ou desliga-se o código SMS para entrar (criar conta pede sempre o código; se o SMS falhar, a conta cria-se com o número por confirmar).
8. **Verificar:** `GET /health`, `GET /map/config` deve dar `{"ownTiles":true}`, entrar no painel em `/painel`.
9. **Manutenção:** cópia diária com `mongodump`, guardada fora do servidor.

## Desenho do app (decidido pelo utilizador, 2026-11-22 — os mesmos padrões da app AngoSchool)

- **Computador:** em ecrãs com 900 px ou mais, o app inteiro aparece numa janela centrada de 460 px (`app/lib/widgets/desktop_frame.dart`, ligada em `MaterialApp.builder`), com o painel da marca à esquerda a partir de 1100 px. Os ecrãs continuam a ser os do telemóvel: não desenhar variantes largas ecrã a ecrã.
- **Nenhuma janela fecha ao tocar fora dela:** `showDialog(barrierDismissible: false)` e `showModalBottomSheet(isDismissible: false, showDragHandle: true)`. Toda a janela tem de ter forma de fechar (botão; nos painéis inferiores, também a pega).
- **Enter submete sempre o formulário** (`onSubmitted` → acção principal).
- **Selo de autoria** (decidido pelo utilizador, 2026-11-24): "Criado por Luzingu Tech" em todas as telas, discreto no canto de baixo (`app/lib/widgets/made_by.dart`, ligado em `MaterialApp.builder`, por isso as telas novas já o têm; não recebe toques e esconde-se com o teclado aberto). No computador aparece também no painel da marca. O texto está na constante `madeBy`.
- **Pensar em quem tem pouca prática com o telemóvel** (decidido pelo utilizador, 2026-11-24): ícones grandes e com cor ao lado do texto, ajudas que dizem o que falta. Campos de número de telefone: usar **sempre** `PhoneField` (`app/lib/widgets/common.dart`) — ícone de telefone num quadrado amarelo, +244 em destaque, algarismos grandes e ajuda ao vivo («Faltam 3 números», verde com visto quando completo, aviso se não começar por 9).
- Depois de mudar o app, recompilar a versão web e ver capturas em telemóvel e em computador antes de entregar.

## Instalação actual (2026-11-22)

A correr em `https://bazatranquilo.com`, no servidor Serve1 da Luzingu, em `/var/www/BazaTranquilo`. Detalhe e comandos em `PRODUCAO.md` › "Instalação em bazatranquilo.com".

- API: serviço `baza` (systemd, `127.0.0.1:4000`); depois de mudar o código, `npm run build && systemctl restart baza`.
- Página inicial na raiz (`site/`); app web em `/app/`, servida pelo Nginx a partir de `app/build/web`; depois de mudar o app, `flutter build web --release --base-href /app/ --dart-define=API_URL=https://bazatranquilo.com`.
- Flutter em `/opt/flutter/bin` (fora do PATH), JDK em `/opt/jdk-17.0.2`, Android SDK em `/opt/android-sdk`.
- Base de dados: MongoDB do AngoSchool (27019), base `baza`. Os testes usam `baza_teste` e precisam de `MONGODB_TEST_URI` (está no `.env`).
- Mapas em Docker com o mapa na porta 8088 (`mapas/.env`).
- TURN das chamadas: coturn em Docker (`turn/`, contentor `baza-turn`), portas 3479, 5350 e 41000–41100/udp; a configuração com a senha está em `/etc/coturn-baza/` (fora do git). Detalhe em `PRODUCAO.md`.

## Pontos em aberto antes de lançar

- Testar uma chamada real entre dois telemóveis em dados móveis (o TURN próprio está instalado desde 2026-11-26).
- Manter o crédito do OpenStreetMap (ícone "ⓘ" no mapa e secção "Mapas" nos Termos): é exigido pela licença.
- Pagamentos electrónicos por contratar (comissões e mensalidades pagam-se fora do app, por transferência para a Luzingu, e confirmam-se no painel). O texto legal é definitivo (dono, 2026-11-26: sem advogado).
- Guardar cópia da chave de assinatura do app (`app/android/app/baza-upload.jks` e `app/android/key.properties`, fora do git): sem ela não há actualizações na loja.
- iPhone: fica para depois (dono, 2026-11-26) — quem tem iPhone usa a versão web em `/app/` (pergunta frequente na página inicial). Para a App Store faltaria Mac com Xcode, conta Apple Developer e activar push, avisos e localização em segundo plano para iOS.

## Empresa e loja (decidido pelo utilizador, 2026-11-26)

- **Som da viagem no alerta de perigo DESLIGADO** (o SOS continua): `ALERT_AUDIO_ENABLED` (por omissão desligado) esconde o botão no app, faz o servidor responder 403 e tira o som dos Termos e da Política; o serviço `AlertAudioService` e a permissão `FOREGROUND_SERVICE_MICROPHONE` estão comentados no `AndroidManifest.xml`. Para ligar, seguir `PRODUCAO.md` › Permissões Android.

- O Bazá é gerido pela equipa Luzingu do AngoSchool: `LEGAL_ENTITY`, `SUPPORT_*` e `COMMISSION_PAY_INFO` no `.env` usam os dados da Luzingu (os mesmos de `angoschool/backend/app/Data/ContactosLuzingu.php`; se lá mudarem, mudar aqui). `SUPPORT_PHONE` leva **um só** número: o app liga para ele (`tel:`).
- Textos da Google Play (ficha, serviços em primeiro plano, segurança dos dados): `PLAY_STORE.md`. Mudar o uso da localização, do microfone ou dos dados obriga a actualizar esse ficheiro e a Política de Privacidade.

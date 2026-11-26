# Bazá — guia para pôr em produção

Este guia descreve como passar o Bazá do computador de desenvolvimento para um servidor na internet. Complementa o `README.md`, que explica o que cada parte faz.

> **Estado deste guia.** Os comandos do servidor (compilar, arrancar em modo de produção) e dos mapas foram testados no computador de desenvolvimento. A instalação num servidor Linux real, o HTTPS e a publicação nas lojas ainda **não** foram feitos: trate esses passos como um plano a validar na primeira instalação.

## 1. O que vai correr no servidor

| Peça | O que é | Porta (só local) |
|---|---|---|
| API do Bazá | Node.js (`backend/`) — também serve o painel, as páginas legais e a partilha de viagem | 4000 |
| MongoDB | Base de dados `baza` (inclui os ficheiros dos documentos) | 27017 |
| Mapa | TileServer GL, em Docker (`mapas/`) | 8080 |
| Rotas | OSRM, em Docker (`mapas/`) | 5000 |
| Pesquisa de locais | Photon, em Docker (`mapas/`) | 2322 |
| Proxy HTTPS | Caddy ou Nginx — a única peça aberta à internet (portas 80 e 443) | — |

O telemóvel só fala com a API, por HTTPS. As restantes portas ficam fechadas para fora.

**Servidor recomendado para começar:** Linux (Ubuntu 22.04 ou mais recente), 4 GB de memória, 2 CPU, 40 GB de disco. A preparação das rotas usa cerca de 1,8 GB de memória durante uns minutos; a pesquisa (Photon) fica com cerca de 1 GB.

**Também é preciso:** um domínio (ex.: `api.baza.ao`) a apontar para o servidor.

## 2. Instalar o que falta no servidor

```sh
# Node.js 22 ou mais recente, Docker (com "docker compose"), MongoDB 7+, e:
sudo apt install -y curl zstd
```

Copie a pasta do projecto para o servidor (por exemplo para `/opt/baza`), **sem** as pastas `node_modules`, `app/build` e `mapas/dados`.

## 3. Mapas próprios

```sh
cd /opt/baza/mapas
./preparar.sh            # 10–30 min: descarrega cerca de 800 MB e prepara Angola inteira
docker compose up -d
docker compose ps        # os três serviços devem estar "Up"
```

Testes rápidos:

```sh
curl -s "http://127.0.0.1:5000/route/v1/driving/13.2344,-8.8383;13.1869,-8.9147?overview=false" | head -c 120
curl -s "http://127.0.0.1:2322/api?q=talatona&limit=1" | head -c 200
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:8080/styles/baza/256/15/17587/17190.png"
```

**A saber:**

- Os serviços arrancam sozinhos quando o servidor reinicia (`restart: unless-stopped`), desde que o Docker arranque com o sistema (`sudo systemctl enable docker`).
- **Com o Docker parado não há mapa nem pesquisa de locais.** O app não volta sozinho aos serviços públicos. As rotas degradam para uma estimativa em linha recta.
- **Actualizar os dados** (sugestão: uma vez por mês): `./preparar.sh && docker compose up -d --force-recreate`.
- Não há trânsito em tempo real: os tempos de viagem são estimados sem engarrafamentos.

## 4. Configurar a API

```sh
cd /opt/baza/backend
npm ci
npm run build
cp .env.example .env     # e editar
chmod 600 .env
```

Valores a definir em `backend/.env` para produção:

| Variável | Valor em produção |
|---|---|
| `NODE_ENV` | `production` |
| `PORT` | `4000` |
| `MONGODB_URI` | `mongodb://127.0.0.1:27017/baza` (com utilizador e palavra-passe, se o MongoDB os tiver) |
| `JWT_SECRET` | Um segredo novo e comprido — gerar com `openssl rand -hex 48`. O servidor recusa arrancar sem ele. |
| `PUBLIC_URL` | `https://api.baza.ao` — usado nas ligações de partilha de viagem |
| `ADMIN_EMAIL`, `ADMIN_PASSWORD` | Primeiro administrador do painel. Em produção **não** existe a conta por defeito `admin@baza.ao`. |
| `AUTO_APPROVE_DOCUMENTS` | `false` — os documentos dos motoristas passam a ser revistos no painel |
| `OSRM_URL` | `http://127.0.0.1:5000` |
| `PHOTON_URL` | `http://127.0.0.1:2322` |
| `NOMINATIM_URL` | (vazio) |
| `TILE_UPSTREAM` | `http://127.0.0.1:8080/styles/baza/256/{z}/{x}/{y}@2x.png` |
| `SMS_PROVIDER`, `TELCOSMS_API_KEY` | Conta de SMS. Hoje a chave é partilhada com outro sistema; convém uma conta própria do Bazá. |
| `SMTP_*`, `SMTP_REMETENTE` | E-mail de avisos. Hoje sai de um endereço de outro domínio; convém uma caixa do Bazá. |
| `LEGAL_ENTITY`, `SUPPORT_EMAIL`, `SUPPORT_PHONE` | Nome da empresa e contactos mostrados em `/termos` e `/privacidade` |
| `EMERGENCY_NUMBER` | Número do botão SOS (por omissão `111`) |
| `FIREBASE_KEY_FILE` | `firebase-chave.json` (ver secção 6) |
| `TURN_URL`, `TURN_USERNAME`, `TURN_PASSWORD` | Servidor TURN para as chamadas (ver secção 8) |
| `WALLET_ENABLED` | `false` enquanto a carteira estiver desligada |
| `COMMISSION_PAY_INFO` | Como os motoristas pagam comissões e mensalidades (conta bancária, local, contacto). Aparece no app. |
| `COMMISSION_ENFORCED`, `COMMISSION_DEBT_LIMIT` | `true` para bloquear quem deve comissões acima do limite; por omissão só se regista a dívida |
| `SUBSCRIPTION_TRIAL_DAYS` | Dias grátis de uma viatura de preço combinado (por omissão 30) |
| `STAR_PLACES_NEED_APPROVAL` | `true` para os locais dos utilizadores estrela só aparecerem depois de aprovados |

**Segredos:** `.env` e `firebase-chave.json` nunca vão para o git nem para mensagens. Ambos já estão no `.gitignore`.

Arrancar e manter a API a correr (exemplo com systemd, ficheiro `/etc/systemd/system/baza.service`):

```ini
[Unit]
Description=API do Bazá
After=network.target mongod.service docker.service

[Service]
WorkingDirectory=/opt/baza/backend
ExecStart=/usr/bin/node dist/index.js
Restart=always
User=baza

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl enable --now baza
curl -s http://127.0.0.1:4000/health          # {"ok":true,...}
curl -s http://127.0.0.1:4000/map/config      # {"ownTiles":true}
```

A API tem de arrancar a partir da pasta `backend/` (é lá que lê o `.env`, a chave do Firebase e o painel).

## 5. HTTPS

A API precisa de HTTPS: sem ele, o Android e o iPhone recusam a ligação e o navegador não dá localização nem microfone. Exemplo com Caddy (`/etc/caddy/Caddyfile`), que trata dos certificados sozinho:

```
api.baza.ao {
    reverse_proxy 127.0.0.1:4000
}
```

O proxy tem de deixar passar WebSocket (o Caddy fá-lo por omissão; no Nginx é preciso `proxy_set_header Upgrade` e `Connection "upgrade"`). Feche na firewall todas as portas excepto 22, 80 e 443.

Endereços que ficam disponíveis:

- Painel: `https://api.baza.ao/painel`
- Termos e privacidade (para as lojas): `https://api.baza.ao/termos` e `/privacidade`
- Partilha de viagem: `https://api.baza.ao/acompanhar/<código>`

## 6. Notificações push (Firebase)

1. `app/android/app/google-services.json` já está no projecto (projecto Firebase do Bazá).
2. A chave da conta de serviço (Firebase › Definições do projecto › Contas de serviço › Gerar nova chave privada) vai para `backend/firebase-chave.json` no servidor, com `chmod 600`.
3. Ao arrancar, a API passa a enviar push a quem não tem o app ligado.

Sem a chave, tudo funciona excepto os avisos com o app fechado.

## 7. Compilar o app para produção

```sh
cd app
flutter build appbundle --release --dart-define=API_URL=https://api.baza.ao
```

Antes da primeira publicação na Play Store:

- **Assinatura:** a chave de loja já existe: `app/android/app/baza-upload.jks`, com a palavra-passe em `app/android/key.properties`. Os dois ficheiros estão fora do git e **só existem no computador de desenvolvimento**: guardar uma cópia de ambos em local seguro (por exemplo, um gestor de palavras-passe e um disco externo). Sem eles não se publicam actualizações do app. Na Play Console, activar o "Play App Signing" para a Google guardar a chave final.
- **Versão:** subir `version:` no `pubspec.yaml` a cada publicação.
- **Ficha da loja:** textos prontos em `PLAY_STORE.md` (ficha, endereços dos Termos e da Política de Privacidade, declarações dos serviços em primeiro plano de localização e microfone, segurança dos dados). O app não pede `ACCESS_BACKGROUND_LOCATION`, por isso não há declaração de localização em segundo plano.
- A versão web, se for usada: `flutter build web --release --dart-define=API_URL=https://api.baza.ao` e servir `app/build/web` por HTTPS.

### Definições a fazer no painel depois de instalar

- **Definições › Comissão das corridas** (por omissão 15 %) e **Comissão intermunicipal** (por omissão 10 %).
- **Saldos dos motoristas** (desde 2026-11-26, Finanças): saldo de cada motorista, carregar à mão (dinheiro recebido), devolver saldo, viagens grátis por motorista, referências geradas. **Definições › Viagens grátis para motoristas novos** (`DRIVER_FREE_RIDES`, por omissão 10; contas antigas sem o campo usam o valor do painel).
- **Referências de pagamento (carregar o saldo):** `REFERENCE_PROVIDER` (hoje só `simulado`), `PAYMENT_SIMULATION` = `off` (omissão em produção: os motoristas comunicam transferências) | `testers` (só os números em `PAYMENT_SIM_PHONES`, separados por vírgulas) | `all`; `PAYMENT_SIM_DELAY_S` (segundos até a referência simulada se dar por paga, 20); `REFERENCE_TTL_HOURS` (48). ⛔ A simulação não move dinheiro real: em produção, só `testers` com contas da equipa. Fornecedor real: escrever o adaptador em `backend/src/services/gateway.ts` e dar-lhe o endereço `POST https://bazatranquilo.com/payments/webhook/<nome>`.
- **Canal do código de entrada:** `OTP_CHANNEL_LABEL` (por omissão `SMS`) é o que o app escreve em «enviámos por …».
- **Finanças › Tarifas e procura** (desde 2026-11-26): tarifas de Moto, Económico e Conforto (base, por km, por minuto, mínimo — por omissão as de `config.ts`), preço por paragem (200 Kz), procura automática (desligada por omissão; escalões ×1,2 com 2 pedidos por motorista livre e ×1,5 com 3, raio de 3 km, últimos 10 min), horários com multiplicador e tecto (×2). Ficam na colecção `definicoes` (chaves `tariffs`, `stopFee`, `surge`).
- **Definições › Mensalidade por tipo de viatura** (por omissão 0 = gratuito).
- **Instituições › Postos policiais:** registar os postos (com a posição no mapa e o telefone do posto) e os agentes de cada um, indicados pela Polícia. Marcar o comando provincial de cada província, que recebe os alertas sem resposta.
- **Intermunicipal:** criar as rotas entre municípios com o preço por passageiro.
- **Definições › Código por SMS para entrar:** o código por SMS para entrar fica ligado por omissão. Desligado, quem já tem conta entra só com o número e a senha; criar conta pede o código por SMS; se o envio falhar, a conta cria-se na mesma, só com a senha, e fica com o número por confirmar (o app pede o código quando o SMS voltar a funcionar e a pessoa não estiver numa corrida). Em Definições aparece quantas contas estão nessa situação, e nas listas de Motoristas / Passageiros cada uma vem marcada "número por confirmar". Senha esquecida nesse modo: Motoristas / Passageiros › "Repor senha".
- **Locais:** registar os pontos principais de cada província onde o Bazá opera e nomear utilizadores estrela.

### Permissões Android do app

Além da localização, notificações e microfone (chamadas), o app pode declarar `FOREGROUND_SERVICE_MICROPHONE` e o serviço `AlertAudioService`, usados só para partilhar o som da viagem durante um alerta de perigo. **Desligado desde 2026-11-26 (decisão do dono):** os dois estão comentados no `AndroidManifest.xml`, o app esconde o botão e o servidor responde 403 (`ALERT_AUDIO_ENABLED`, por omissão desligado; os Termos e a Política só falam do som com ele ligado). O SOS continua. Para ligar: `ALERT_AUDIO_ENABLED=true` no `.env` e reiniciar a API, repor as duas linhas no manifesto, publicar nova versão do app e, na Play Store, justificar o uso ("gravação de áudio iniciada pelo utilizador numa emergência", texto em `PLAY_STORE.md` › 2.2) com um vídeo curto.

## 8. Pontos em aberto antes de lançar

| Ponto | Situação | O que fazer |
|---|---|---|
| Chamadas no app em dados móveis | ✅ TURN próprio (coturn) desde 2026-11-26 — ver «Instalação em bazatranquilo.com» | Testar uma chamada real entre dois telemóveis em dados móveis |
| Crédito do mapa | A licença do OpenStreetMap obriga a indicá-lo | Manter o ícone "ⓘ" no mapa e a secção "Mapas" nos Termos |
| Texto legal | Definitivo (dono, 2026-11-26, sem advogado) | Empresa: Luzingu (`LEGAL_ENTITY`) |
| Cobrança de comissões e mensalidades | Registadas e pagas fora do app; o motorista comunica o pagamento e a equipa confirma no painel | `COMMISSION_PAY_INFO` definido (IBAN da Luzingu, 2026-11-26); mais tarde, ligar um pagamento electrónico que confirme sozinho |
| Pagamentos electrónicos | Simulados | Contratos com Multicaixa Express / Unitel Money / Afrimoney |
| Locais fora de Luanda | Poucos pontos no mapa aberto | Registar no painel › Locais e nomear utilizadores estrela |
| iPhone | Fica para depois (dono, 2026-11-26): usa-se a versão web | Ver secção 10 |

## 9. Manutenção

- **Cópias de segurança:** `mongodump --db baza --archive=baza-$(date +%F).gz --gzip`, todos os dias, guardadas fora do servidor. A base inclui as fotos e os documentos dos motoristas.
- **Actualizar a API:** copiar o código novo, `npm ci && npm run build`, `sudo systemctl restart baza`.
- **Ver o que se passa:** `journalctl -u baza -f` (API) e `docker compose logs -f` na pasta `mapas/`.
- **Testes antes de publicar:** `cd backend && npm run test:e2e` (não envia SMS nem e-mails reais) e `cd app && flutter test`.
- **Saldo de SMS:** aparece no resumo do painel.

## 10. iPhone (iOS)

O código do app é o mesmo para Android e iPhone, e os ecrãs, o mapa, as corridas, o chat e as chamadas devem funcionar. Mas a versão iPhone **nunca foi compilada nem testada**, e há trabalho por fazer:

| O que falta | Detalhe |
|---|---|
| Mac com Xcode completo | O computador actual não tem o Xcode instalado |
| Conta Apple Developer | 99 USD por ano; necessária para instalar em iPhones e publicar na App Store |
| Push no iPhone | Adicionar o app iOS ao projecto Firebase (`GoogleService-Info.plist`), criar a chave APNs na conta Apple e activar o código de push para iOS (hoje só corre no Android) |
| Avisos locais no iPhone | O serviço de notificações do app está activo só no Android; é preciso activá-lo e pedir a permissão no iOS |
| Localização em segundo plano | Acrescentar ao `Info.plist` a permissão "sempre" e o modo de fundo `location`, e configurar o envio de posição para iOS |
| Botão "Navegar" | Abre o Google Maps por ligação web; no iPhone convém abrir o Apple Maps quando o Google Maps não estiver instalado |
| Revisão da Apple | Exige eliminação de conta no app (já existe) e justificação do uso de localização e microfone |

Já está preparado no projecto iOS: nome do app, permissões de localização durante o uso, microfone, câmara e fotografias.


## iPhone — estado em 2026-11-22

Preparado sem Xcode (por isso nunca compilado): textos de permissão e modos em segundo plano (`location`, `audio`, `remote-notification`) em `app/ios/Runner/Info.plist`; posição do motorista em segundo plano (`AppleSettings` em `driver_state.dart`). Identificador da app: `ao.baza.baza`.

Falta, por esta ordem:
1. Libertar espaço no Mac (o Xcode precisa de cerca de 40 GB; havia 10 GB livres) e instalar o Xcode pela App Store. Depois: `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`, `sudo xcodebuild -runFirstLaunch`, e instalar o CocoaPods (`brew install cocoapods`).
2. Conta Apple Developer (99 USD por ano), necessária para instalar em iPhones reais, para as notificações e para a App Store.
3. No Firebase, registar a app iOS `ao.baza.baza`, pôr o `GoogleService-Info.plist` em `app/ios/Runner/` e carregar a chave APNs da conta Apple.
4. No código: activar as notificações no iPhone (`notifier.dart` e `push.dart` estão limitados ao Android), juntar ao projecto Xcode os sons das notificações (vozes e sirene) e activar "Push Notifications" e "Background Modes" no alvo Runner.
5. `cd app && flutter build ios --release --dart-define=API_URL=https://<domínio>`, testar num iPhone e enviar pelo Xcode para o TestFlight.

No iPhone, a partilha do som num alerta usa o modo `audio` (não há serviço como no Android); tem de ser testada num aparelho real.


## Instalação em bazatranquilo.com — estado em 2026-11-22

Primeira instalação real, no servidor Serve1 da Luzingu (o mesmo do AngoSchool). O que ficou diferente do plano acima:

| Peça | Como ficou |
|---|---|
| Pasta | `/var/www/BazaTranquilo` (clone do git; não `/opt/baza`) |
| Endereço | `https://bazatranquilo.com` — o `www` e o HTTP redireccionam para lá |
| Proxy HTTPS | Nginx: `/etc/nginx/sites-available/bazatranquilo`. Na raiz serve a página inicial (`site/`), em `/app/` a app web (`app/build/web`) e passa tudo o resto (API, `/painel`, `/termos`, `/acompanhar`, socket.io) para `127.0.0.1:4000` |
| Certificado | Let's Encrypt por *webroot* (`/var/www/letsencrypt-baza`); renova sozinho e recarrega o Nginx (`/etc/letsencrypt/renewal-hooks/deploy/nginx-recarregar.sh`) |
| API | serviço `baza` (systemd), utilizador `baza`, `HOST=127.0.0.1` no `.env` para não escutar para fora |
| Base de dados | **MongoDB do AngoSchool** (porta 27019, replicado para o Serve2), base `baza`, utilizador `baza` próprio (decisão do dono). A base de teste é `baza_teste`, com o mesmo utilizador |
| Mapas | `mapas/.env` com `MAPA_PORT=8088` (a 8080 é do Nginx neste servidor); `TILE_UPSTREAM` aponta para a 8088 |
| TURN (chamadas) | coturn em Docker (`turn/docker-compose.yml`, contentor `baza-turn`, rede do anfitrião). Portas **3479** udp/tcp, **5350** TLS e relay **41000–41100/udp**, abertas na UFW — as habituais (3478, 5349, 40000+) são do LiveKit do AngoSchool. Configuração com a senha fora do git: `/etc/coturn-baza/turnserver.conf` (= `TURN_PASSWORD` no `.env`; mudar as duas). Certificado copiado para `/etc/coturn-baza/certs` pelo gancho `/etc/letsencrypt/renewal-hooks/deploy/baza-turn-certificado.sh`, que reinicia o contentor. Recusa reencaminhar para redes internas e para o próprio servidor (`denied-peer-ip`). Sem `user-quota`: todos os telemóveis usam o mesmo utilizador `baza`. Instalado em Docker porque o `apt` do servidor tem dependências partidas (o `--fix-broken` actualizaria 138 pacotes, incluindo o `systemd`) |
| Administrador do painel | `admin@bazatranquilo.com`; a senha inicial está em `ADMIN_PASSWORD` no `backend/.env` — trocar no painel |
| Cópia do `.env` original | `/root/baza-env-original-20261122.bak` (o que veio do computador de desenvolvimento) |

Comandos do dia-a-dia neste servidor:

```sh
export JAVA_HOME=/opt/jdk-17.0.2 ANDROID_HOME=/opt/android-sdk PATH=/opt/flutter/bin:$PATH

# API: depois de mudar o código
cd /var/www/BazaTranquilo/backend && npm run build && systemctl restart baza
journalctl -u baza -f

# App web (fica em /app/): basta compilar, o Nginx lê os ficheiros do disco
cd /var/www/BazaTranquilo/app && flutter build web --release --base-href /app/ --dart-define=API_URL=https://bazatranquilo.com

# APK assinado com a chave de loja
flutter build apk --release --dart-define=API_URL=https://bazatranquilo.com

# Testes da API (o MongoDB daqui pede senha)
cd /var/www/BazaTranquilo/backend && MONGODB_TEST_URI="$(grep '^MONGODB_TEST_URI=' .env | cut -d= -f2-)" npm run test:e2e
```

Página inicial: `site/index.html` é um ficheiro só (HTML, CSS e JavaScript), sem compilação — edita-se e fica no ar (o Nginx pode demorar até 1 minuto a largar a versão antiga). É a página que os motores de busca lêem: `site/robots.txt`, `site/sitemap.xml`, imagem de partilha `site/og.png` e dados estruturados (organização, aplicação e perguntas frequentes) no próprio HTML. As perguntas frequentes estão escritas duas vezes (no texto e nos dados estruturados): mudar nos dois sítios.

Por fazer nesta instalação:

- ✅ **Feito a 2026-11-24 (6 contas desactivadas).** Fica a nota para uma reinstalação. **Regra "um número, um só tipo de conta" (2026-11-24):** logo **depois** de reiniciar a API com esta versão (nunca antes — o servidor antigo criaria uma conta nova ao passageiro desactivado), desactivar o lado passageiro das duplas antigas. Primeiro ver, depois aplicar:
  `cd /var/www/BazaTranquilo/backend && npx tsx scripts/desactivar-passageiros-com-numero-de-motorista.ts` e depois o mesmo com `--aplicar`. A 24/11 eram 6 (todos os motoristas). Nada se apaga: o número passa para `formerPhone`, as corridas ficam, e o painel mostra a conta como "Desactivada · número de motorista". Correr de novo não faz mal (salta quem já está tratado e quem estiver numa corrida).
- Registar o domínio na Google Search Console e enviar o `sitemap.xml`.

- ✅ 2026-11-26: cópia de segurança diária da base `baza` → Mega (`/backup/baza/AAAA/MM/`), com o mesmo `/root/backup_mega.sh` das bases do AngoSchool, no cron às 03:30. Primeira cópia feita e confirmada no Mega.
- Conta de SMS e caixa de e-mail próprias (ver secções 4 e 8).
- ✅ 2026-11-26: servidor TURN (coturn) — testado com `turnutils_uclient` por UDP, TCP e TLS. Testar o TURN: `docker run --rm --network host --entrypoint turnutils_uclient coturn/coturn:4.6 -v -p 3479 -u baza -w <senha> -e 8.8.8.8 -n 1 -m 1 213.136.68.153` (deve dar «Received relay addr» e «success»). Registo: `docker logs baza-turn`.
- ✅ 2026-11-26: `LEGAL_ENTITY`, `SUPPORT_EMAIL`, `SUPPORT_PHONE` e `COMMISSION_PAY_INFO` com os dados da Luzingu (o Bazá é gerido pela equipa do AngoSchool). Cópia do `.env` anterior: `/root/baza-env-antes-dados-empresa-20261126.bak`.
- Textos para a Google Play Console (ficha, serviços em primeiro plano, segurança dos dados): `PLAY_STORE.md`.
- O *lint* das versões release está desligado em `app/android/build.gradle.kts` porque rebenta com o JDK 17; com JDK 21 pode voltar a ligar-se.

## Actualizações do app — versão mínima e correcções sem loja (2026-11-26)

O mesmo desenho das apps AngoSchool (detalhe e regras: `/var/www/angoschool_front_flutter/docs/PUBLICAR_LOJAS.md` § «Actualizações»).

- **Versão mínima / aviso:** o app lê `https://bazatranquilo.com/app-versao.json` — o ficheiro `site/app-versao.json`, servido pelo Nginx sem cache (não é preciso compilar nem reiniciar a API). Abaixo de `minima` → ecrã a bloquear com «Actualizar agora»; abaixo de `actual` → aviso que se fecha. Cada uma pode ser `"X.Y.Z"` ou `{"android": …, "ios": …}`. Pergunta ao abrir e quando o app volta ao ecrã (≤ 30 min); falha de rede nunca bloqueia; na web nunca bloqueia. Código: `app/lib/widgets/porteiro_versao.dart` (no `builder` do `MaterialApp`). ⛔ Nunca subir a `minima` antes de a versão nova estar disponível na loja.
- **Correcções sem loja (Shorebird):** app registado na conta Shorebird da Luzingu (`app/shorebird.yaml`, `app_id` `f1a6454e-e05c-4ce1-a5a5-d5eb38a39b3d`, vai dentro do app pelos `assets`). Chave da conta em `/root/my_secrets/apps_flutter/shorebird_token`; ferramenta em `/root/.shorebird/bin/shorebird` (o mesmo Flutter, 3.50.1).
  - Versão para a loja: `bash app/tools/compilar_loja.sh appbundle [commit]` — compila de um commit fixo (o trabalho por commitar não entra), com `shorebird release android`, `API_URL=https://bazatranquilo.com` e `APP_VERSAO` tirado do `pubspec.yaml`; o ficheiro fica em `app/build/loja/`. ⛔ Uma versão compilada com `flutter build` não recebe correcções.
  - Correcção: `bash app/tools/publicar_correcao.sh [percentagem] [commit]` (só código Dart; permissões, plugins, ícone, `AndroidManifest.xml` e versão do Flutter vão à loja). ⛔ Não subir o `version:` para uma correcção.
  - ✅ 2026-11-26: a Shorebird está nos «Prestadores de serviços» da Política de Privacidade e no formulário de segurança dos dados (`PLAY_STORE.md`) — recebe só dados técnicos (app, versão, sistema, identificador aleatório da instalação).

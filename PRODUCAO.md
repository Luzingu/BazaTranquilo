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
- **Ficha da loja:** endereços dos Termos e da Política de Privacidade (secção 5), e a declaração de uso de localização em segundo plano (motoristas).
- A versão web, se for usada: `flutter build web --release --dart-define=API_URL=https://api.baza.ao` e servir `app/build/web` por HTTPS.

### Definições a fazer no painel depois de instalar

- **Definições › Comissão das corridas** (por omissão 15 %) e **Comissão intermunicipal** (por omissão 10 %).
- **Definições › Mensalidade por tipo de viatura** (por omissão 0 = gratuito).
- **Instituições › Postos policiais:** registar os postos (com a posição no mapa e o telefone do posto) e os agentes de cada um, indicados pela Polícia. Marcar o comando provincial de cada província, que recebe os alertas sem resposta.
- **Intermunicipal:** criar as rotas entre municípios com o preço por passageiro.
- **Definições › Código por SMS para entrar:** o código por SMS para entrar fica ligado por omissão. Desligado, quem já tem conta entra só com o número e a senha; criar conta pede o código por SMS; se o envio falhar, a conta cria-se na mesma, só com a senha, e fica com o número por confirmar (o app pede o código quando o SMS voltar a funcionar e a pessoa não estiver numa corrida). Em Definições aparece quantas contas estão nessa situação, e nas listas de Motoristas / Passageiros cada uma vem marcada "número por confirmar". Senha esquecida nesse modo: Motoristas / Passageiros › "Repor senha".
- **Locais:** registar os pontos principais de cada província onde o Bazá opera e nomear utilizadores estrela.

### Permissões Android do app

Além da localização, notificações e microfone (chamadas), o app declara `FOREGROUND_SERVICE_MICROPHONE` e o serviço `AlertAudioService`, usados só para partilhar o som da viagem durante um alerta de perigo. Na ficha da Play Store é preciso justificar este uso ("gravação de áudio iniciada pelo utilizador numa emergência") e mostrar um vídeo curto da função.

## 8. Pontos em aberto antes de lançar

| Ponto | Situação | O que fazer |
|---|---|---|
| Chamadas no app em dados móveis | Só há STUN público; em muitas redes a chamada não liga | Instalar um servidor TURN (ex.: coturn) e preencher `TURN_*` |
| Crédito do mapa | A licença do OpenStreetMap obriga a indicá-lo | Manter o ícone "ⓘ" no mapa e a secção "Mapas" nos Termos |
| Texto legal | Rascunho | Revisão por um advogado |
| Cobrança de comissões e mensalidades | Registadas e pagas fora do app; o motorista comunica o pagamento e a equipa confirma no painel | Definir `COMMISSION_PAY_INFO`; mais tarde, ligar um pagamento electrónico que confirme sozinho |
| Pagamentos electrónicos | Simulados | Contratos com Multicaixa Express / Unitel Money / Afrimoney |
| Locais fora de Luanda | Poucos pontos no mapa aberto | Registar no painel › Locais e nomear utilizadores estrela |
| iPhone | Nunca compilado | Ver secção 10 |

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

- **Regra "um número, um só tipo de conta" (2026-11-24):** logo **depois** de reiniciar a API com esta versão (nunca antes — o servidor antigo criaria uma conta nova ao passageiro desactivado), desactivar o lado passageiro das duplas antigas. Primeiro ver, depois aplicar:
  `cd /var/www/BazaTranquilo/backend && npx tsx scripts/desactivar-passageiros-com-numero-de-motorista.ts` e depois o mesmo com `--aplicar`. A 24/11 eram 6 (todos os motoristas). Nada se apaga: o número passa para `formerPhone`, as corridas ficam, e o painel mostra a conta como "Desactivada · número de motorista". Correr de novo não faz mal (salta quem já está tratado e quem estiver numa corrida).
- Registar o domínio na Google Search Console e enviar o `sitemap.xml`.

- Cópia de segurança da base `baza` (o `/root/backup_mega.sh` só leva as bases do AngoSchool).
- Servidor TURN, conta de SMS e caixa de e-mail próprias, `LEGAL_ENTITY`/`SUPPORT_*` e `COMMISSION_PAY_INFO` (ver secções 4 e 8).
- O *lint* das versões release está desligado em `app/android/build.gradle.kts` porque rebenta com o JDK 17; com JDK 21 pode voltar a ligar-se.

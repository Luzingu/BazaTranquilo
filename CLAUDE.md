# Bazá — instruções do projecto

App de táxi para Angola (nome completo "Bazá Tranquilo", lema "Bazá com Segurança"). Responder ao utilizador em português.

- `backend/` — API Node.js + TypeScript + Express + MongoDB (também serve o painel web, as páginas legais e a partilha de viagem)
- `app/` — app Flutter (Android, web; iPhone ainda não compilado)
- `mapas/` — mapas próprios em Docker (imagens do mapa, rotas, pesquisa de locais)
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

- Entrar: o utilizador escreve só o número; o servidor decide se pede o código SMS ou a senha, conforme o painel (Definições). No primeiro ecrã NÃO há botão "entrar com senha"; no ecrã do código, quem tem senha pode optar por ela ("Não tem o telefone consigo?"), e a senha é pedida automaticamente quando o código está desligado, o envio do SMS falha ou o código não chega. Criar conta: o número é SEMPRE confirmado por SMS e só depois se define a senha (obrigatória). O login por email continua descontinuado.

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
7. **Painel:** em Definições, a percentagem de comissão das corridas, a comissão intermunicipal e a mensalidade por tipo de viatura; em Intermunicipal, as rotas com o preço por passageiro. Em "Definições" liga-se ou desliga-se o código SMS para entrar (criar conta pede sempre o código).
8. **Verificar:** `GET /health`, `GET /map/config` deve dar `{"ownTiles":true}`, entrar no painel em `/painel`.
9. **Manutenção:** cópia diária com `mongodump`, guardada fora do servidor.

## Pontos em aberto antes de lançar

- Servidor TURN para as chamadas no app ligarem em dados móveis (`TURN_*`).
- Manter o crédito do OpenStreetMap (ícone "ⓘ" no mapa e secção "Mapas" nos Termos): é exigido pela licença.
- Texto legal por rever por um advogado; pagamentos electrónicos por contratar (comissões e mensalidades pagam-se fora do app e confirmam-se no painel).
- Guardar cópia da chave de assinatura do app (`app/android/app/baza-upload.jks` e `app/android/key.properties`, fora do git): sem ela não há actualizações na loja.
- iPhone: precisa de Mac com Xcode, conta Apple Developer, e de activar push, avisos e localização em segundo plano para iOS (hoje só Android).

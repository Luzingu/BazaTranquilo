# Bazá — textos para a Google Play Console

Textos prontos a colar na Play Console (2026-11-26). Identificador: `ao.baza.baza`.
Empresa: Luzingu Lua Kiesse Comércio Geral e Prestação de Serviços, Lda. (NIF 5001148583).
Contactos: tech@angoschool.com · +244 926 930 664.

A Google aceita as declarações em português, mas quem revê lê sobretudo inglês: em cada
declaração vai o texto nas duas línguas — colar as duas, português primeiro.

⛔ Se mudar o que o app faz com a localização, o microfone ou os dados, actualizar este ficheiro
**e** a Política de Privacidade (`backend/src/routes/legal.ts`): a Google rejeita o app quando a
declaração e a política não dizem o mesmo.

---

## 1. Ficha da loja

⛔ Enquanto não houver postos policiais registados no painel, a ficha **não** promete que a polícia
acompanha o alerta (a Google rejeita descrições que o app não cumpre). Com os postos registados,
pode voltar a dizer-se: «os postos policiais mais próximos passam a acompanhar a viagem».

**Nome do app:** Bazá Tranquilo

**Descrição curta** (máx. 80 caracteres):
> Táxi, carga e viagens entre municípios em Angola, com segurança.

**Descrição completa:**
> O Bazá liga passageiros a motoristas de confiança em Angola.
>
> PARA O PASSAGEIRO
> • Peça um carro, mota, triciclo ou viatura de carga e veja o motorista a chegar no mapa.
> • Saiba o preço antes de confirmar. Nos serviços de carga, combine o preço com o motorista.
> • Reserve um lugar nas viagens entre municípios.
> • Fale com o motorista por mensagem ou chamada dentro do app, sem dar o seu número.
> • Partilhe a viagem com a família e, em caso de perigo, use o botão SOS para ligar logo para o 111 e enviar a viagem às pessoas de confiança.
>
> PARA O MOTORISTA
> • Fique online e receba pedidos perto de si.
> • Navegue até ao passageiro e ao destino.
> • Veja os seus ganhos, comissões e mensalidades.
> • Trabalhe por conta própria ou numa frota parceira.
>
> Feito para quem tem pouca prática com o telemóvel: letras e ícones grandes, ajudas a dizer o que falta.
>
> Os documentos dos motoristas são verificados pela equipa antes de poderem trabalhar.
>
> Suporte: tech@angoschool.com · 926 930 664

**Categoria:** Mapas e navegação (alternativa: Viagens e local).
**E-mail de contacto:** tech@angoschool.com · **Telefone:** +244 926 930 664
**Site:** https://bazatranquilo.com
**Política de Privacidade:** https://bazatranquilo.com/privacidade
**Termos:** https://bazatranquilo.com/termos

---

## 2. Permissões de serviço em primeiro plano (Foreground service)

Na Play Console: *Conteúdo do app › Permissões de serviço em primeiro plano*. **Nesta versão o app declara
um só tipo** (localização, 2.1): a partilha do som num alerta (2.2) está desligada desde 2026-11-26 e o
serviço de microfone saiu do `AndroidManifest.xml`. O 2.2 fica aqui para quando se ligar.
Cada tipo pede um **vídeo curto** (YouTube, pode ser «não listado") a mostrar a função.

### 2.1 `FOREGROUND_SERVICE_LOCATION` — motorista online

**Tipo de tarefa:** Navegação / partilha de localização iniciada pelo utilizador.

**PT:**
> Só os motoristas usam este serviço. Ao tocar em «Ficar online», o app inicia um serviço em primeiro
> plano com uma notificação permanente («Bazá · está online — A sua posição está a ser partilhada para
> receber corridas»). Enquanto o motorista está online, a sua posição é enviada ao servidor a cada
> poucos segundos, para o sistema lhe entregar pedidos de passageiros perto dele e para o passageiro
> ver o carro a chegar. Tem de continuar com o ecrã bloqueado ou com outra app aberta (por exemplo, o
> Google Maps a navegar até ao passageiro). O serviço pára quando o motorista toca em «Ficar offline».
> Os passageiros nunca usam este serviço.

**EN:**
> Only drivers use this service. When the driver taps "Go online", the app starts a foreground service
> with a persistent notification ("Bazá · online — Your position is being shared to receive rides").
> While online, the driver's location is sent to our server every few seconds so the system can offer
> nearby ride requests and the passenger can watch the car arrive. It must keep working with the
> screen locked or while another app is in front (e.g. Google Maps navigating to the passenger). The
> service stops when the driver taps "Go offline". Passengers never use this service.

**Vídeo:** entrar como motorista › «Ficar online» › mostrar a notificação › bloquear o ecrã › noutro
telemóvel, o passageiro vê o carro a mexer-se › «Ficar offline» e a notificação desaparece.

### 2.2 `FOREGROUND_SERVICE_MICROPHONE` — som da viagem num alerta de perigo (⛔ DESLIGADO — não declarar)

**Tipo de tarefa:** Gravação de áudio iniciada pelo utilizador numa emergência.

**PT:**
> Funcionalidade de segurança. Durante uma corrida, o passageiro ou o motorista pode accionar o alerta
> de perigo (botão SOS) e, dentro desse alerta, escolher «Partilhar o som da viagem». Só nesse momento
> o app inicia um serviço em primeiro plano, com notificação permanente, que capta o som do microfone e
> o envia em blocos de poucos segundos aos agentes dos postos policiais que acompanham o alerta. Tem de
> continuar com o ecrã bloqueado, porque numa situação de perigo a pessoa não pode deixar o telemóvel
> aberto no app. O serviço pára quando o alerta é fechado ou cancelado. Nunca se grava sem esta acção
> explícita, e o som é apagado 30 dias depois de o alerta ser fechado.

**EN:**
> Safety feature. During a ride, the passenger or the driver can raise a danger alert (SOS button) and,
> inside that alert, choose "Share the sound of the ride". Only then does the app start a foreground
> service, with a persistent notification, that captures microphone audio and sends it in chunks of a
> few seconds to the police officers following the alert. It must keep running with the screen locked,
> because in a dangerous situation the person cannot keep the phone open on the app. The service stops
> when the alert is closed or cancelled. Nothing is ever recorded without this explicit action, and the
> audio is deleted 30 days after the alert is closed.

**Vídeo:** corrida em curso › SOS › «Partilhar o som da viagem» › notificação permanente › bloquear o
ecrã › na área do agente, o som chega › fechar o alerta e a notificação desaparece.

---

## 3. Localização

O app **não** pede `ACCESS_BACKGROUND_LOCATION`: a localização do motorista com o ecrã bloqueado vem
do serviço em primeiro plano (secção 2.1). Por isso **não** é preciso a declaração de «Localização em
segundo plano». Se um dia se acrescentar essa permissão, a declaração passa a ser obrigatória.

Texto do pedido de localização no próprio app (passageiro e motorista): a posição serve para mostrar
onde está no mapa, propor o ponto de partida e, no motorista, receber pedidos perto.

---

## 4. Microfone (`RECORD_AUDIO`)

Usado só nas **chamadas de voz dentro do app** entre passageiro e motorista (o número de nenhum é
revelado ao outro; o som não é gravado). O som da viagem num alerta de perigo (2.2) está desligado.

---

## 5. Segurança dos dados (*Data safety*)

Respostas gerais: os dados são **cifrados em trânsito** (HTTPS); o utilizador **pode pedir a
eliminação** (Menu › Os meus dados › Eliminar conta, e por e-mail); **não** se vendem dados; **não**
há publicidade.

| Tipo de dados (Play) | Recolhido | Partilhado | Obrigatório? | Para quê |
|---|---|---|---|---|
| Localização exacta | Sim | Sim — com o outro interveniente da corrida e, só num alerta de perigo, com a polícia | Sim | Funcionalidade do app; segurança |
| Nome | Sim | Sim — com o outro interveniente da corrida | Sim | Funcionalidade; gestão da conta |
| Número de telefone | Sim | Só num alerta de perigo, com a polícia | Sim | Conta (entrada por SMS); segurança |
| E-mail | Sim (opcional) | Não | Não | Conta; comunicações |
| Fotografias | Sim (foto de perfil; documentos e viatura do motorista) | Foto de perfil com o outro interveniente | Só motoristas | Funcionalidade; verificação |
| Gravações de áudio | **Não** (a partilha do som num alerta está desligada; se se ligar: Sim, partilhado com a polícia, opcional, segurança) | — | — | — |
| Mensagens no app (chat) | Sim | Com o outro interveniente da corrida | Não | Funcionalidade |
| Histórico de compras (corridas, preços, pagamentos) | Sim | Não | Sim | Funcionalidade; contabilidade |
| Identificadores do dispositivo (token de notificações; identificador aleatório da instalação) | Sim | Com o Google Firebase (notificações) e a Shorebird (actualizações do app) | Sim | Funcionalidade |
| Diagnóstico / análise | Não | — | — | — |

**«Partilha» que a Google não conta como partilha:** prestadores que trabalham por nossa conta
(envio de SMS, e-mail, alojamento, Firebase) — indicar «processados por prestadores de serviços».

---

## 6. Outras declarações da Play Console

- **Eliminação de conta:** sim, no app (Menu › Os meus dados › Eliminar conta) e pela página
  https://bazatranquilo.com/privacidade (secção dos direitos), por e-mail tech@angoschool.com.
- **Público-alvo:** 18 anos ou mais. O app não é dirigido a crianças.
- **Anúncios:** não contém anúncios.
- **Acesso ao app (para a revisão):** contas já criadas (2026-11-26), que entram **só com o número e a
  senha, sem SMS** (números em `REVIEW_PHONES` no `.env`; o servidor nunca lhes envia código):
  passageiro **900 000 001** e motorista aprovado **900 000 002** (Económico, LD-00-00-RV). As senhas
  estão em `/root/my_secrets/BazaTranquilo/contas_revisao_google.txt`. Instruções para a Google (colar):
  > Open the app, choose "Passenger" (or tap "I'm a driver" for the driver account), type the phone number
  > and tap continue: the app asks for the password directly (no SMS code). Driver: tap "Go online" to
  > receive requests; a test ride can be requested from the passenger account.
  Senhas novas: `cd backend && npx tsx scripts/criar-contas-revisao.ts`.
- **Classificação de conteúdo (questionário IARC):** sem violência, sem conteúdo sexual; há
  comunicação entre utilizadores (chat e chamadas) e partilha de localização.
- **App de transporte / serviços financeiros:** não. Os pagamentos no app são simulados; as comissões
  e mensalidades pagam-se por transferência fora do app.

---

## 7. iPhone

Não há versão para a App Store nesta fase (decisão do dono, 2026-11-26): quem tem iPhone usa a
**versão web** em https://bazatranquilo.com/app/ (no Safari, «Partilhar › Adicionar ao ecrã principal»
deixa-a com ícone como um app).

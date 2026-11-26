import { Router } from 'express';
import helmet from 'helmet';
import { config } from '../config.js';

// Páginas públicas de Termos de Utilização e Política de Privacidade. O app
// abre-as no navegador, e são os endereços a indicar nas lojas de aplicações.
//
// Texto definitivo (decisão do dono, 2026-11-26: não passa por advogado). A
// empresa responsável e os contactos vêm de LEGAL_ENTITY e SUPPORT_* no .env
// (a Luzingu, que gere o Bazá); os números (minutos, cancelamentos) vêm de
// config.ts, para o texto dizer sempre o que o sistema faz. Mudar o texto de
// forma importante obriga a subir UPDATED (secção "Alterações aos Termos").

const UPDATED = '26 de Novembro de 2026';
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

function contact() {
  const { email, phone } = config.legal;
  const parts = [
    email ? `e-mail <a href="mailto:${esc(email)}">${esc(email)}</a>` : '',
    phone ? `telefone ${esc(phone)}` : '',
  ].filter(Boolean);
  return parts.length ? parts.join(' ou ') : 'os contactos indicados na aplicação';
}

function page(title: string, body: string) {
  return `<!doctype html>
<html lang="pt">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} · Bazá Tranquilo</title>
<style>
  :root { color-scheme: light; }
  body { margin: 0; font: 16px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; color: #14161A; background: #F3F4F6; }
  header { background: #14161A; color: #fff; padding: 20px 16px; }
  header div, main { max-width: 760px; margin: 0 auto; }
  header b { color: #FFC400; font-size: 22px; }
  header span { display: block; color: #C7CAD1; font-size: 14px; }
  main { background: #fff; padding: 24px 20px 40px; }
  h1 { font-size: 26px; line-height: 1.25; margin: 0 0 4px; }
  h2 { font-size: 18px; margin: 28px 0 6px; }
  p, li { margin: 6px 0; }
  .muted { color: #5B6170; font-size: 14px; }
  nav { margin-top: 32px; padding-top: 16px; border-top: 1px solid #E5E7EB; font-size: 14px; }
  a { color: #14161A; }
</style>
</head>
<body>
<header><div><b>Bazá</b><span>Bazá Tranquilo · Bazá com Segurança</span></div></header>
<main>
<h1>${title}</h1>
<p class="muted">Última actualização: ${UPDATED}</p>
${body}
<nav><a href="/termos">Termos de Utilização</a> · <a href="/privacidade">Política de Privacidade</a></nav>
</main>
</body>
</html>`;
}

const terms = () => {
  const entity = esc(config.legal.entity);
  const grace = Math.round(config.cancellation.graceMs / 60_000);
  const suspend = Math.round(config.cancellation.suspendMs / 60_000);
  return page(
    'Termos de Utilização',
    `
<p>Estes Termos regulam a utilização da aplicação e dos serviços Bazá ("Bazá", "nós"), disponibilizados por ${entity}. Leia-os com atenção: ao criar conta ou ao usar a aplicação, declara que os leu e que os aceita. Se não concordar, não utilize o serviço.</p>

<h2>1. Definições</h2>
<ul>
<li><b>Aplicação:</b> a aplicação Bazá para telemóvel e a sua versão web.</li>
<li><b>Passageiro:</b> quem pede uma corrida, um serviço de transporte de carga ou um lugar numa viagem entre municípios.</li>
<li><b>Motorista:</b> quem presta o transporte com a sua viatura, por conta própria ou de uma frota.</li>
<li><b>Frota:</b> empresa parceira que regista e gere os seus motoristas no Bazá.</li>
<li><b>Corrida:</b> cada serviço de transporte pedido e aceite através da Aplicação.</li>
</ul>

<h2>2. O que é o Bazá</h2>
<p>O Bazá é uma plataforma tecnológica que põe em contacto Passageiros com Motoristas. <b>O transporte é prestado pelo Motorista, e não pelo Bazá.</b> O Bazá fornece os meios para pedir, combinar, acompanhar e registar a Corrida, e para ajudar na segurança dos dois. Os Motoristas não são trabalhadores nem representantes do Bazá.</p>
<p>O Bazá disponibiliza três tipos de serviço:</p>
<ul>
<li><b>Corridas com tarifa</b> (moto e carro): o preço é calculado pela Aplicação e mostrado antes de pedir.</li>
<li><b>Serviços de preço a combinar</b> (triciclo, viatura de vários lugares, carrinha, camião e entregas): o Passageiro descreve o que precisa e o preço é combinado com o Motorista na Aplicação.</li>
<li><b>Viagens entre municípios:</b> o Motorista publica uma viagem numa rota, com dia, hora e preço por passageiro, e o Passageiro reserva lugares.</li>
</ul>

<h2>3. Conta</h2>
<ul>
<li>Para usar o Bazá é preciso ter pelo menos 18 anos e capacidade para celebrar contratos.</li>
<li>A conta é criada com um número de telefone, que é confirmado por um código enviado por SMS (se o SMS não chegar ao criar a conta, a confirmação é pedida mais tarde), e com uma senha escolhida por si.</li>
<li>Os dados que indicar têm de ser verdadeiros e estar actualizados.</li>
<li>A conta é pessoal e não pode ser cedida. Guarde a senha e os códigos em segredo: é responsável pelo que for feito com a sua conta. Se suspeitar de uso indevido, avise-nos de imediato.</li>
<li>Cada número de telefone só pode ter um tipo de conta: Passageiro ou Motorista. Para ter as duas, é preciso usar números diferentes.</li>
</ul>

<h2>4. Pedir e fazer uma Corrida</h2>
<ul>
<li>O Passageiro indica o ponto de recolha, o destino (quando o serviço o exige) e as paragens. O tempo e o percurso apresentados são estimativas e dependem do trânsito e do estado das vias.</li>
<li>O contrato de transporte forma-se entre o Passageiro e o Motorista quando o Motorista aceita o pedido ou quando o Passageiro aceita a proposta do Motorista.</li>
<li>O Passageiro deve estar no ponto de recolha à hora combinada e <b>confirmar a matrícula e o motorista</b> antes de entrar.</li>
<li>Nas viagens entre municípios, a reserva só fica garantida quando o Motorista a confirma na Aplicação. A bagagem e a carga extra, e o respectivo preço, combinam-se com o Motorista de acordo com as condições que ele publicar.</li>
</ul>

<h2>5. Preços</h2>
<ul>
<li><b>Corridas com tarifa:</b> o preço apresentado antes de pedir resulta da distância, do tempo previsto, do tipo de serviço e das paragens. O Passageiro e o Motorista podem negociar outro valor na Aplicação; o valor aceite pelos dois é o que se paga.</li>
<li><b>Serviços de preço a combinar:</b> não há tarifa; vale o preço aceite pelos dois na Aplicação.</li>
<li><b>Viagens entre municípios:</b> o preço é por passageiro e é o indicado na viagem publicada.</li>
<li>Portagens, estacionamento e outros custos pedidos pelo Passageiro durante o serviço são combinados directamente com o Motorista.</li>
<li>O Motorista não pode cobrar mais do que o valor acordado na Aplicação.</li>
</ul>

<h2>6. Pagamento</h2>
<ul>
<li>O pagamento é feito <b>directamente ao Motorista</b>, no fim do serviço, pelos meios disponíveis na Aplicação (actualmente, em dinheiro).</li>
<li>O recibo de cada Corrida fica disponível no histórico da Aplicação.</li>
<li>O Bazá não guarda nem movimenta o dinheiro pago pelo Passageiro ao Motorista.</li>
</ul>

<h2>7. Cancelamentos</h2>
<ul>
<li>O Passageiro pode cancelar sem qualquer consequência enquanto se procura motorista e até ${grace} minutos depois de um Motorista aceitar.</li>
<li>Cancelar depois disso, ou com o Motorista já no local, conta como cancelamento tardio. ${config.cancellation.maxLate} cancelamentos tardios em 24 horas suspendem a conta durante ${suspend} minutos.</li>
<li>Para o Motorista, desistir de uma Corrida aceite conta sempre como cancelamento tardio.</li>
<li>Nas viagens entre municípios, o Passageiro pode desistir da reserva até à partida, e o Motorista pode cancelar a viagem, sendo os Passageiros avisados.</li>
<li>Cancelamentos repetidos ou abusivos podem levar à suspensão ou ao encerramento da conta.</li>
</ul>

<h2>8. Regras para Passageiros</h2>
<ul>
<li>Tratar o Motorista e a viatura com respeito e seguir as indicações de segurança, incluindo o uso do cinto de segurança e, nas motos, do capacete.</li>
<li>Não transportar bens ilegais, perigosos ou que possam danificar a viatura. Nos serviços de carga, descrever com verdade o que vai ser transportado.</li>
<li>Não pedir ao Motorista que desrespeite as regras de trânsito nem que transporte mais pessoas do que a viatura permite.</li>
<li>Pagar o preço acordado e reparar os danos que causar na viatura.</li>
<li>Os menores só podem viajar acompanhados por um adulto responsável.</li>
</ul>

<h2>9. Regras para Motoristas</h2>
<ul>
<li>Ter carta de condução válida e adequada à viatura, e manter em dia o livrete, o título de propriedade e o seguro obrigatório, bem como as licenças que a lei exigir para a actividade.</li>
<li>Enviar fotografia de perfil e documentos verdadeiros. O Bazá pode verificar os documentos e recusar, suspender ou encerrar contas com documentos inválidos, caducados ou falsos.</li>
<li>Usar apenas a viatura registada, mantê-la limpa e em boas condições de segurança, e cumprir o Código de Estrada.</li>
<li>Não conduzir sob o efeito de álcool ou de drogas, nem cansado ao ponto de pôr em risco a viagem.</li>
<li>Não discriminar Passageiros, não os assediar e não usar os seus contactos para outro fim que não a Corrida.</li>
<li>Não deixar outra pessoa conduzir com a sua conta.</li>
<li>O Motorista é o único responsável pelos impostos e pelas contribuições que resultem da sua actividade.</li>
</ul>

<h2>10. O que o Motorista paga ao Bazá</h2>
<ul>
<li><b>Saldo pré-pago:</b> o Motorista carrega o saldo na Aplicação (por referência de pagamento ou por transferência confirmada pela equipa). Os valores do Bazá descontam-se desse saldo. Sem saldo para a taxa de uma corrida, o Motorista não a recebe.</li>
<li><b>Corridas com tarifa:</b> uma taxa sobre o valor de cada corrida, na percentagem indicada na Aplicação no momento do pedido, descontada do saldo no fim da corrida. Cada conta nova de Motorista começa com o número de viagens grátis (sem taxa) indicado na Aplicação.</li>
<li><b>Viagens entre municípios:</b> uma comissão sobre o valor dos lugares confirmados, na percentagem indicada na Aplicação no momento da conclusão da viagem.</li>
<li><b>Serviços de preço a combinar:</b> em vez de comissão, uma mensalidade por cada viatura registada, no valor indicado na Aplicação para o tipo de viatura, paga com o saldo. Sem a mensalidade em dia, a viatura não pode receber pedidos.</li>
<li>O saldo, as viagens grátis e todos os movimentos constam de "O meu saldo".</li>
<li>O Bazá pode alterar as percentagens, as viagens grátis e as mensalidades, avisando os Motoristas na Aplicação. As alterações só se aplicam aos serviços pedidos e aos períodos pagos depois do aviso.</li>
</ul>

<h2>11. Segurança</h2>
<ul>
<li>A Aplicação tem um botão SOS, o alerta de perigo às autoridades (que passam a acompanhar a viagem${config.alertAudioEnabled ? ' e, se o utilizador o activar, a ouvir o som da viatura' : ''}) e a partilha da viagem com pessoas de confiança.${config.alertAudioEnabled ? ' Quem viaja com um utilizador do Bazá aceita que, num alerta de perigo, o som da viatura possa ser partilhado com a polícia.' : ''} Estas funções são uma ajuda e <b>não substituem os serviços de emergência</b>: em caso de perigo, ligue para o ${esc(config.emergencyNumber)}.</li>
<li>O chat e as chamadas entre Passageiro e Motorista servem apenas para combinar o serviço.</li>
<li>Qualquer incidente deve ser comunicado ao Bazá em "Ajuda e suporte" e, quando for caso disso, às autoridades.</li>
</ul>

<h2>12. Objectos perdidos</h2>
<p>O Passageiro é responsável pelos seus pertences. Se se esquecer de alguma coisa na viatura, pode comunicá-lo em "Ajuda e suporte" ou em "Reportar problema" na Corrida. O Bazá ajuda a contactar o Motorista, mas não garante a recuperação do objecto.</p>

<h2>13. Avaliações</h2>
<p>No fim de cada Corrida, o Passageiro e o Motorista podem avaliar-se. As avaliações devem ser honestas e respeitosas. Contas com avaliações persistentemente baixas, ou que manipulem avaliações, podem ser suspensas.</p>

<h2>14. Locais registados por utilizadores</h2>
<p>Alguns utilizadores podem registar locais no mapa do Bazá. Quem o faz garante que a informação é verdadeira e autoriza o Bazá a usá-la, mostrá-la e corrigi-la sem limite de tempo e sem pagamento. O Bazá pode remover locais errados ou impróprios.</p>

<h2>15. Condutas proibidas</h2>
<p>É proibido usar o Bazá para fins ilegais; criar contas falsas ou com dados de outra pessoa; assediar, ameaçar ou enganar outros utilizadores; combinar serviços pela Aplicação para os fazer por fora e fugir à comissão; manipular preços, pedidos ou avaliações; copiar, modificar ou tentar aceder aos sistemas do Bazá sem autorização.</p>

<h2>16. Suspensão e encerramento da conta</h2>
<ul>
<li>O Bazá pode suspender ou encerrar contas que violem estes Termos, que ponham em risco a segurança de outras pessoas ou em caso de suspeita fundada de fraude. Sempre que possível, o utilizador é avisado e pode apresentar a sua versão em "Ajuda e suporte".</li>
<li>Pode eliminar a sua conta a qualquer momento, em Menu › Os meus dados › Eliminar conta. A <a href="/privacidade">Política de Privacidade</a> explica o que é apagado e o que é conservado. Os valores em dívida ao Bazá continuam a ser devidos.</li>
</ul>

<h2>17. Responsabilidade</h2>
<ul>
<li>O Bazá esforça-se por manter o serviço disponível e seguro, mas não garante que funcione sem interrupções nem a exactidão dos mapas, das rotas e dos tempos estimados.</li>
<li>O serviço de transporte é da responsabilidade do Motorista que o presta. Na medida permitida pela lei, o Bazá não responde por actos ou omissões de Motoristas e de Passageiros, por atrasos, por objectos perdidos nem por danos na carga transportada.</li>
<li>Nada nestes Termos limita os direitos que a lei garante aos consumidores, nem a responsabilidade do Bazá em caso de dolo ou de culpa grave.</li>
</ul>

<h2>18. Propriedade intelectual</h2>
<p>A Aplicação, a marca "Bazá", o logótipo e os conteúdos pertencem a ${entity} ou são usados com autorização. É concedida ao utilizador uma licença pessoal, limitada e revogável para usar a Aplicação de acordo com estes Termos.</p>

<h2>19. Mapas</h2>
<p>Os mapas, as rotas e a pesquisa de locais usam dados © contribuidores do OpenStreetMap, disponibilizados sob a licença Open Database License (<a href="https://www.openstreetmap.org/copyright">openstreetmap.org/copyright</a>). O desenho do mapa baseia-se no projecto Protomaps.</p>

<h2>20. Alterações a estes Termos</h2>
<p>Podemos actualizar estes Termos. Quando as alterações forem importantes, avisamos na Aplicação antes de produzirem efeito. Continuar a usar o serviço depois do aviso significa que aceita os novos Termos; se não concordar, pode eliminar a conta.</p>

<h2>21. Lei aplicável, reclamações e litígios</h2>
<p>Estes Termos regem-se pela lei da República de Angola. Dúvidas e reclamações podem ser apresentadas em "Ajuda e suporte", na Aplicação, ou por ${contact()}; procuramos responder em poucos dias úteis. Os litígios que não se resolvam por acordo são decididos pelos tribunais angolanos competentes, sem prejuízo das regras legais de protecção do consumidor.</p>
`,
  );
};

const privacy = () => {
  const entity = esc(config.legal.entity);
  return page(
    'Política de Privacidade',
    `
<p>Esta Política explica que dados pessoais o Bazá recolhe, para que os usa, com quem os partilha e que direitos tem. O responsável pelo tratamento é ${entity}. O tratamento segue a Lei n.º 22/11, de 17 de Junho (Lei da Protecção de Dados Pessoais).</p>

<h2>1. Dados que recolhemos</h2>
<ul>
<li><b>Conta:</b> número de telefone, senha (guardada de forma cifrada, que não permite lê-la), nome, fotografia de perfil (opcional para passageiros, obrigatória para motoristas), e-mail e contacto de emergência, se os indicar.</li>
<li><b>Motoristas:</b> número, categoria e validade da carta de condução; fotografias da carta (frente e verso); dados das viaturas (marca, modelo, cor, matrícula, validade do seguro); fotografias do livrete, do título de propriedade e do seguro; comissões, mensalidades e pagamentos comunicados ao Bazá.</li>
<li><b>Localização:</b> a posição do passageiro quando tem a aplicação aberta, para sugerir o ponto de recolha e mostrar o mapa; a posição do motorista enquanto está online e durante as corridas, <b>incluindo com a aplicação em segundo plano ou com o ecrã bloqueado</b>, para receber pedidos e para o passageiro acompanhar a viagem. Fora desses períodos, a posição do motorista não é recolhida.</li>
<li><b>Corridas e viagens:</b> pontos de recolha e destino, paragens, percurso, horas, preço, forma de pagamento, descrição da carga, propostas de preço, reservas de lugares, avaliações, locais guardados e motoristas preferidos.</li>
<li><b>Comunicações:</b> mensagens trocadas no chat da corrida e pedidos enviados ao suporte. As chamadas de voz feitas na aplicação <b>não são gravadas</b>.</li>
<li><b>Segurança:</b> alertas de perigo (com a posição no momento), ligações de partilha de viagem que criar${config.alertAudioEnabled ? ' e, <b>só se o activar durante um alerta</b>, o som captado pelo microfone do seu telemóvel, enviado em blocos de poucos segundos' : ''}.</li>
<li><b>Locais registados:</b> se for um utilizador autorizado a registar locais no mapa, o nome e a posição desses locais, associados à sua conta.</li>
<li><b>Dados técnicos:</b> identificador do dispositivo para as notificações, endereço IP e registos de acesso necessários ao funcionamento e à segurança do serviço.</li>
</ul>
<p>Não recolhemos dados de cartões bancários: os pagamentos são feitos directamente ao motorista.</p>

<h2>2. Para que usamos os dados e com que fundamento</h2>
<ul>
<li><b>Prestar o serviço que pediu</b> (execução do contrato): criar e proteger a conta, ligar passageiros a motoristas, calcular rotas e preços, mostrar a viagem no mapa, emitir recibos, enviar avisos sobre a corrida.</li>
<li><b>Segurança</b> (interesse legítimo e protecção das pessoas): verificar a identidade e os documentos dos motoristas, responder a alertas SOS, prevenir fraude, abuso e cancelamentos abusivos.</li>
<li><b>Apoio ao cliente</b> e resolução de reclamações.</li>
<li><b>Contas com os motoristas:</b> gerir o saldo pré-pago, os carregamentos, as taxas e as mensalidades.</li>
<li><b>Obrigações legais</b>, incluindo fiscais e de resposta a pedidos das autoridades.</li>
<li><b>Melhorar o serviço:</b> estatísticas sem identificação de pessoas.</li>
</ul>
<p>A localização e as notificações dependem das permissões que der no telemóvel. Não vendemos os seus dados e não os usamos para publicidade de terceiros.</p>

<h2>3. Com quem partilhamos</h2>
<ul>
<li><b>Entre passageiro e motorista de um mesmo serviço:</b> nome, fotografia, avaliação, telefone, dados da viatura e posição durante a corrida. Nas viagens entre municípios, o motorista vê o nome e o telefone de quem reserva; o passageiro vê o telefone do motorista depois de a reserva ser confirmada.</li>
<li><b>Pessoas com quem partilhar a viagem:</b> quem receber a sua ligação de partilha vê o percurso, o motorista e a viatura dessa viagem, enquanto ela decorre.</li>
<li><b>Contacto de emergência:</b> se accionar o SOS e escolher enviar-lhe a sua viagem.</li>
<li><b>Frotas:</b> se um motorista pertencer a uma frota, o gestor da frota vê os seus dados profissionais, a sua posição quando está online e as suas corridas.</li>
<li><b>Prestadores de serviços</b> que trabalham por nossa conta: envio de SMS e de e-mail, alojamento dos servidores, envio de notificações (Google Firebase) e actualizações da aplicação (Shorebird, que recebe só dados técnicos: a aplicação, a versão, o sistema e um identificador aleatório da instalação). Só recebem o necessário para a função e não podem usar os dados para outros fins. Alguns destes prestadores têm servidores fora de Angola; nesses casos, a transferência é feita com as garantias exigidas pela lei.</li>
<li><b>Polícia, quando acciona o alerta de perigo:</b> os agentes dos postos policiais mais próximos, registados no Bazá, vêem a sua viagem enquanto o alerta estiver aberto — o seu nome e telefone, os do motorista ou passageiro que vai consigo, a viatura, o percurso e a posição actual${config.alertAudioEnabled ? ' — e ouvem o som, se o partilhar' : ''}. Deixam de ter acesso quando o alerta é fechado, e cada acesso fica registado. Fora de um alerta, a polícia não consulta dados no Bazá.</li>
<li><b>Pessoa de confiança, quando acciona o alerta de perigo:</b> se o seu contacto de emergência tiver conta no Bazá, vê e ouve o mesmo que a polícia, enquanto o alerta estiver aberto.</li>
<li><b>Outras autoridades:</b> quando a lei o exigir ou mediante pedido válido de uma autoridade competente.</li>
</ul>
<p>Os mapas, as rotas e a pesquisa de locais funcionam em servidores do próprio Bazá: a sua posição e as suas pesquisas não são enviadas a empresas de mapas.</p>

<h2>4. Durante quanto tempo guardamos</h2>
<ul>
<li>Os dados da conta são guardados enquanto a conta existir.</li>
<li>Os códigos de confirmação por SMS expiram em minutos.</li>
<li>Da posição do motorista em tempo real guarda-se apenas a mais recente, enquanto está online; de cada corrida ficam registados os pontos e o percurso.</li>
<li>O registo das corridas e das viagens (datas, percurso, preço) e as contas com os motoristas são conservados depois de a conta ser eliminada, sem ligação ao seu nome, telefone ou fotografia, pelo prazo exigido pelas obrigações legais e para a contabilidade do outro interveniente.</li>
<li>Os pedidos de suporte e os alertas de perigo são conservados pelo tempo necessário para tratar o caso e para defesa em eventuais litígios.${config.alertAudioEnabled ? ' O som partilhado num alerta é apagado 30 dias depois de o alerta ser fechado.' : ''}</li>
</ul>

<h2>5. Os seus direitos</h2>
<p>Pode aceder aos seus dados, corrigi-los, opor-se ao tratamento e pedir que sejam apagados. A maior parte pode ser feita na aplicação:</p>
<ul>
<li><b>Ver e corrigir:</b> Menu › Os meus dados.</li>
<li><b>Eliminar a conta:</b> Menu › Os meus dados › Eliminar conta. São apagados de imediato o nome, o telefone, o e-mail, a senha, a fotografia, os documentos, os locais guardados, os motoristas preferidos e as mensagens que escreveu.</li>
<li><b>Localização e notificações:</b> pode retirar as permissões nas definições do telemóvel; sem localização, não é possível receber corridas como motorista, e o passageiro terá de escolher o ponto de recolha à mão.</li>
</ul>
<p>Para outros pedidos, contacte-nos por ${contact()}. Respondemos no prazo previsto na lei. Tem também o direito de apresentar queixa à Agência de Protecção de Dados (APD).</p>

<h2>6. Segurança dos dados</h2>
<p>As ligações à aplicação são cifradas; as senhas são guardadas de forma que não permite lê-las; os documentos dos motoristas só são acessíveis ao próprio e à equipa que os verifica; e o acesso interno é limitado a quem precisa. Nenhum sistema é totalmente seguro: se houver um incidente que afecte os seus dados, avisaremos os utilizadores afectados e as autoridades, nos termos da lei.</p>

<h2>7. Menores</h2>
<p>O Bazá destina-se a maiores de 18 anos. Não recolhemos conscientemente dados de menores; se soubermos que uma conta pertence a um menor, eliminamo-la.</p>

<h2>8. Alterações</h2>
<p>Se alterarmos esta Política de forma relevante, avisaremos na aplicação antes de as alterações produzirem efeito.</p>
`,
  );
};

const csp = helmet.contentSecurityPolicy({
  useDefaults: false,
  directives: { defaultSrc: ["'none'"], styleSrc: ["'unsafe-inline'"], baseUri: ["'none'"], frameAncestors: ["'none'"] },
});

export const legalRouter = Router();
legalRouter.get('/termos', csp, (_req, res) => {
  res.type('html').send(terms());
});
legalRouter.get('/privacidade', csp, (_req, res) => {
  res.type('html').send(privacy());
});

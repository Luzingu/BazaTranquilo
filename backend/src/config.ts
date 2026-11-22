import 'dotenv/config';

const env = process.env;
const isDev = (env.NODE_ENV ?? 'development') !== 'production';

if (!isDev && (!env.JWT_SECRET || env.JWT_SECRET === 'troque-este-segredo')) {
  throw new Error('JWT_SECRET tem de ser definido em produção');
}

export const config = {
  isDev,
  port: Number(env.PORT ?? 4000),
  mongoUri: env.MONGODB_URI ?? 'mongodb://127.0.0.1:27017/baza',
  jwtSecret: env.JWT_SECRET ?? 'troque-este-segredo',
  osrmUrl: env.OSRM_URL ?? 'https://router.project-osrm.org',
  /** Vazio = não usar o Nominatim (com mapas próprios, o Photon faz tudo). */
  nominatimUrl: env.NOMINATIM_URL ?? 'https://nominatim.openstreetmap.org',
  /**
   * Modelo do endereço das imagens do mapa no nosso servidor de mapas, com
   * {z}, {x} e {y}. Vazio = o app usa as imagens públicas do OpenStreetMap.
   */
  tileUpstream: env.TILE_UPSTREAM ?? '',
  /**
   * Comissão do Bazá nas corridas pagas em dinheiro: fica registada como dívida
   * do motorista (ver models/misc.ts › CommissionEntry) e é paga à equipa, que a
   * regista no painel. Com `enforced`, quem deve mais do que `debtLimit` não
   * pode ficar online. Desligado por omissão: a dívida só é registada.
   */
  commission: {
    enforced: env.COMMISSION_ENFORCED === 'true',
    debtLimit: Number(env.COMMISSION_DEBT_LIMIT ?? 5000),
    /** Como pagar, mostrado ao motorista no app. */
    payInfo: env.COMMISSION_PAY_INFO ?? 'Contacte a equipa do Bazá para saber como pagar a mensalidade ou a comissão.',
  },
  /** Mensalidade das viaturas de preço combinado: dias grátis ao registar a viatura. */
  subscriptionTrialDays: Number(env.SUBSCRIPTION_TRIAL_DAYS ?? 30),
  /** Cancelamentos tardios: quantos em 24 h levam à suspensão, e por quanto tempo. */
  cancellation: {
    /** Tempo (ms) depois de o motorista aceitar em que o passageiro ainda cancela sem penalização. */
    graceMs: Number(env.CANCEL_GRACE_SECONDS ?? 120) * 1000,
    maxLate: Number(env.CANCEL_MAX_LATE ?? 3),
    suspendMs: Number(env.CANCEL_SUSPEND_MINUTES ?? 30) * 60_000,
  },
  /** Locais registados por utilizadores estrela só aparecem depois de aprovados no painel. */
  starPlacesNeedApproval: env.STAR_PLACES_NEED_APPROVAL === 'true',
  /** Enviar o recibo da corrida por SMS (gasta saldo). Por e-mail é sempre enviado, se houver e-mail. */
  receiptBySms: env.RECEIPT_SMS === 'true',
  /** Chave da conta de serviço do Firebase (notificações push). Sem o ficheiro, o push fica desligado. */
  firebaseKeyFile: env.FIREBASE_KEY_FILE ?? 'firebase-chave.json',
  legal: {
    entity: env.LEGAL_ENTITY ?? 'Bazá Tranquilo',
    email: env.SUPPORT_EMAIL ?? '',
    phone: env.SUPPORT_PHONE ?? '',
  },
  paymentProvider: env.PAYMENT_PROVIDER ?? 'mock',
  emisApiUrl: env.EMIS_API_URL ?? '',
  emisFrameToken: env.EMIS_FRAME_TOKEN ?? '',

  /**
   * Aprovar os documentos automaticamente ao serem enviados. Ligado por omissão
   * em desenvolvimento; em produção um administrador revê-os no painel web (/painel).
   */
  autoApproveDocuments: env.AUTO_APPROVE_DOCUMENTS ? env.AUTO_APPROVE_DOCUMENTS === 'true' : isDev,
  /** Primeiro administrador do painel web, criado no arranque se ainda não houver nenhum. */
  adminEmail: env.ADMIN_EMAIL ?? '',
  adminPassword: env.ADMIN_PASSWORD ?? '',

  /**
   * Envio de SMS: "telcosms" envia mesmo (TelcoSMS, Angola) e gasta saldo;
   * "console" só escreve o SMS no log (desenvolvimento e testes). Por omissão,
   * envia a sério sempre que houver chave.
   */
  smsProvider: env.SMS_PROVIDER ?? (env.TELCOSMS_API_KEY ? 'telcosms' : 'console'),
  telcoSmsApiKey: env.TELCOSMS_API_KEY ?? '',
  telcoSmsUrl: (env.TELCOSMS_URL ?? 'https://www.telcosms.co.ao/api/v2').replace(/\/$/, ''),

  /**
   * E-mail: "smtp" envia a sério (com um Web App do Google Apps Script como
   * reserva); "console" só escreve no log. Por omissão, envia sempre que houver
   * utilizador SMTP configurado.
   */
  mail: {
    transport: env.MAIL_TRANSPORT ?? (env.SMTP_USER ? 'smtp' : 'console'),
    smtpHost: env.SMTP_HOST ?? 'smtp.hostinger.com',
    smtpPort: Number(env.SMTP_PORT ?? 465),
    smtpUser: env.SMTP_USER ?? '',
    smtpPass: env.SMTP_PASS ?? '',
    /** Tem de ser um endereço do domínio da conta SMTP, senão o e-mail é recusado ou vai para spam. */
    from: env.SMTP_REMETENTE ?? env.SMTP_USER ?? '',
    fromName: env.SMTP_REMETENTE_NOME ?? 'Bazá',
    timeoutMs: Number(env.SMTP_TIMEOUT ?? 15) * 1000,
    serviceUrl: env.EMAIL_SERVICE_URL ?? '',
    servicePass: env.EMAIL_SERVICE_PASS ?? '',
  },

  /**
   * Chamadas de voz no app (WebRTC). O STUN ajuda os telemóveis a encontrarem-se;
   * em muitas redes móveis é preciso também um servidor TURN (TURN_URL,
   * TURN_USERNAME, TURN_PASSWORD), sem o qual algumas chamadas não ligam.
   */
  iceServers: [
    { urls: (env.STUN_URLS ?? 'stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302').split(',') },
    ...(env.TURN_URL
      ? [{ urls: env.TURN_URL.split(','), username: env.TURN_USERNAME ?? '', credential: env.TURN_PASSWORD ?? '' }]
      : []),
  ],

  /** Endereço público do servidor, usado nos links de partilha de viagem. */
  publicUrl: (env.PUBLIC_URL ?? `http://localhost:${env.PORT ?? 4000}`).replace(/\/$/, ''),
  /** Número de emergência para que o botão SOS liga (polícia, em Angola). */
  emergencyNumber: env.EMERGENCY_NUMBER ?? '111',

  /**
   * Carteira no app (saldo, pagamento por carteira, comissões e levantamentos).
   * Desligada por enquanto: as corridas pagam-se em dinheiro ou Multicaixa e não
   * se movimentam saldos. Liga-se com WALLET_ENABLED=true.
   */
  walletEnabled: env.WALLET_ENABLED === 'true',

  currency: 'AOA',
  /** Parte de cada corrida que fica com a plataforma. */
  commissionRate: 0.15,
  /** Raio de procura de motoristas, em metros. */
  driverSearchRadiusM: 6000,
  /** Tempo máximo à procura de motorista antes de desistir. */
  searchTimeoutMs: 120_000,
  /** Tempo extra de procura quando chega uma proposta de preço de um motorista. */
  bidExtensionMs: 90_000,
  /** Negociação: o preço pode ir de 50 % a 300 % do preço da tarifa, em passos de 50 Kz. */
  minFareFactor: 0.5,
  maxFareFactor: 3,
  fareStep: 50,
  /** Tempo em que um pedido fica reservado ao motorista preferido. */
  preferredTimeoutMs: 30_000,
  /** Dívida máxima (comissões de corridas a dinheiro) com que o motorista ainda pode ficar online. */
  driverDebtLimit: 5000,
  minWithdrawal: 1000,
  otpTtlMs: 5 * 60_000,
  otpMaxAttempts: 5,
};

interface Service {
  /** "ride" transporta pessoas; "cargo" transporta mercadoria. */
  group: 'ride' | 'cargo';
  label: string;
  description: string;
  /** Lugares para passageiros (serviços de viagem). */
  seats?: number;
  /** Carga máxima em kg (serviços de carga). */
  capacityKg?: number;
  /** Se o cliente pode pedir ajudantes para carregar e descarregar. */
  helpers?: boolean;
  /**
   * Preço combinado directamente entre o cliente e o motorista: não há tarifa
   * calculada, o destino é opcional e não se cobra comissão por serviço — estas
   * viaturas pagam uma mensalidade para se manterem activas.
   */
  negotiated?: boolean;
  // Tarifa em Kwanzas
  base: number;
  perKm: number;
  perMin: number;
  minimum: number;
}

/**
 * Catálogo de serviços. A chave é a categoria da viatura: um motorista recebe
 * os pedidos da categoria da viatura que tem activa.
 */
export const services = {
  // ── Viagens ──
  moto: { group: 'ride', label: 'Moto', description: 'Rápida no trânsito', seats: 1, base: 300, perKm: 150, perMin: 15, minimum: 600 },
  tricycle: { negotiated: true, group: 'ride', label: 'Triciclo', description: 'Moto de 3 rodas para passageiros', seats: 3, base: 350, perKm: 180, perMin: 18, minimum: 700 },
  economy: { group: 'ride', label: 'Económico', description: 'Carro acessível', seats: 4, base: 500, perKm: 250, perMin: 30, minimum: 1000 },
  comfort: { group: 'ride', label: 'Conforto', description: 'Carro espaçoso com ar condicionado', seats: 4, base: 800, perKm: 350, perMin: 45, minimum: 1500 },
  xl: { negotiated: true, group: 'ride', label: 'XL', description: 'Carrinha para grupos e bagagem', seats: 6, base: 1000, perKm: 420, perMin: 50, minimum: 2000 },
  // ── Carga e entregas ──
  // Só as viagens de moto e de carro (acima) têm tarifa calculada. Triciclos, XL e
  // todos os serviços de carga são de preço combinado (`negotiated`).
  delivery: { negotiated: true, group: 'cargo', label: 'Entrega', description: 'Encomendas pequenas, de moto', capacityKg: 20, base: 400, perKm: 160, perMin: 15, minimum: 800 },
  cargo_tricycle: { negotiated: true, group: 'cargo', label: 'Triciclo de carga (Kupapata)', description: 'Moto de 3 rodas com caixa', capacityKg: 500, helpers: true, base: 800, perKm: 300, perMin: 25, minimum: 1500 },
  pickup: { negotiated: true, group: 'cargo', label: 'Carrinha', description: 'Caixa aberta ou furgão', capacityKg: 1500, helpers: true, base: 2000, perKm: 500, perMin: 50, minimum: 4000 },
  truck: { negotiated: true, group: 'cargo', label: 'Camião', description: 'Mudanças e cargas grandes', capacityKg: 8000, helpers: true, base: 5000, perKm: 900, perMin: 80, minimum: 10000 },
} satisfies Record<string, Service>;

export type RideCategory = keyof typeof services;
export const SERVICE_KEYS = Object.keys(services) as [RideCategory, ...RideCategory[]];
export const service = (category: RideCategory): Service => services[category];

/** Paragens intermédias: quantas se podem pedir e quanto custa cada uma (tempo de espera). */
export const MAX_STOPS = 3;
export const STOP_FEE = 200;

/** Preço por ajudante (carregar e descarregar), em serviços de carga. */
export const HELPER_FEE = 1500;
export const MAX_HELPERS = 3;
/** Número máximo de viaturas por motorista. */
export const MAX_VEHICLES = 5;

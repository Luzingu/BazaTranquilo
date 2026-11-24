// Painel Bazá: administrador da plataforma e frotas parceiras.
// JavaScript simples, sem bibliotecas (além do Leaflet para o mapa).

const API = '/painel/api';
const $ = (sel, root = document) => root.querySelector(sel);
const view = $('#view');

// A sessão vive só neste separador: fechar o browser termina-a.
let session = JSON.parse(sessionStorage.getItem('baza-painel') || 'null');
let refreshTimer = null; // actualização periódica da secção aberta
let map = null;
// Imagens do mapa: as do nosso servidor quando existem; senão, as públicas.
let TILES = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
fetch('/map/config')
  .then((r) => r.json())
  .then((c) => c.ownTiles && (TILES = '/map/tiles/{z}/{x}/{y}.png'))
  .catch(() => {});

// ── Utilitários ─────────────────────────────────────────────────────────────

/** Escapa texto vindo do servidor antes de o pôr em HTML. */
const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
// Agrupa sempre os milhares ("1 666 Kz"), o que o formato pt-PT não faz com 4 dígitos.
const kz = (n) => `${String(Math.round(n || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, '\u00a0')} Kz`;
const when = (iso) =>
  iso ? new Date(iso).toLocaleString('pt-PT', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—';
const day = (iso) => (iso ? new Date(iso).toLocaleDateString('pt-PT') : '—');

async function api(path, { method = 'GET', body } = {}) {
  let res;
  try {
    res = await fetch(API + path, {
      method,
      headers: {
        ...(body ? { 'Content-Type': 'application/json' } : {}),
        ...(session ? { Authorization: `Bearer ${session.token}` } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new Error('Sem ligação ao servidor.');
  }
  const data = await res.json().catch(() => ({}));
  if (res.status === 401 && session) {
    logout();
    throw new Error('A sessão terminou. Entre novamente.');
  }
  if (!res.ok) throw new Error(data.error || `Erro ${res.status}`);
  return data;
}

const VERIFICATION = {
  approved: ['ok', 'Aprovado'],
  pending: ['wait', 'Em análise'],
  rejected: ['bad', 'Rejeitado'],
  incomplete: ['off', 'Registo incompleto'],
};
const RIDE_STATUS = {
  searching: ['wait', 'À procura'],
  accepted: ['trip', 'A caminho'],
  arrived: ['trip', 'No local'],
  in_progress: ['trip', 'Em viagem'],
  completed: ['ok', 'Concluída'],
  cancelled: ['bad', 'Cancelada'],
  no_drivers: ['off', 'Sem motorista'],
};
const TICKET_CATEGORY = {
  lost_item: 'Objecto perdido',
  ride: 'Problema com uma corrida',
  payment: 'Pagamento',
  safety: 'Segurança',
  account: 'Conta',
  other: 'Outro assunto',
};
const PAYMENT = { cash: 'Dinheiro', wallet: 'Carteira', multicaixa: 'Multicaixa', corporate: 'Conta de empresa' };
const badge = ([cls, label]) => `<span class="badge ${cls}">${esc(label)}</span>`;

function driverState(d) {
  if (d.blocked) return badge(['bad', 'Suspenso']);
  if (d.onTrip) return badge(['trip', 'Em viagem']);
  return badge(d.online ? ['ok', 'Online'] : ['off', 'Offline']);
}

function table(headers, rows, emptyText) {
  if (!rows.length) return `<div class="table-wrap"><div class="empty">${esc(emptyText)}</div></div>`;
  const head = headers.map((h) => `<th${h.num ? ' class="num"' : ''} scope="col">${esc(h.label ?? h)}</th>`).join('');
  return `<div class="table-wrap"><table><thead><tr>${head}</tr></thead><tbody>${rows.join('')}</tbody></table></div>`;
}

/** Cabeçalho do resumo, sobre a imagem do mapa nocturno. */
const hero = (title, subtitle) => `<div class="hero"><h1>${esc(title)}</h1><p>${esc(subtitle)}</p></div>`;

// Ícones desenhados em linha (traço simples, 24×24), para não depender de ficheiros externos.
const ICONS = {
  home: '<path d="M3 11l9-8 9 8"/><path d="M5 10v10h14V10"/><path d="M10 20v-6h4v6"/>',
  car: '<path d="M3 17v-4l2-5h14l2 5v4"/><path d="M3 13h18M5 17h14"/><circle cx="7.5" cy="17" r="1.6"/><circle cx="16.5" cy="17" r="1.6"/>',
  map: '<path d="M9 4 3 6v14l6-2 6 2 6-2V4l-6 2-6-2z"/><path d="M9 4v14M15 6v14"/>',
  bus: '<rect x="4" y="4" width="16" height="13" rx="2"/><path d="M4 11h16M8 21v-2M16 21v-2M8 14.5h.01M16 14.5h.01"/>',
  alert: '<path d="M12 3 2 20h20L12 3z"/><path d="M12 10v4M12 17.3v.2"/>',
  wheel: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="2"/><path d="M12 14v7M3.5 10.5 10 12M20.5 10.5 14 12"/>',
  file: '<path d="M14 3H6v18h12V7l-4-4z"/><path d="M14 3v4h4M9 13.5l2 2 4-4"/>',
  users: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c.5-4 3-6 6.5-6s6 2 6.500 6M16 4.600a3.500 3.500 0 0 1 0 6.800M18 14.500c2 .800 3.200 2.600 3.500 5.500"/>',
  building: '<path d="M4 21V3h11v18M15 9h5v12M2 21h20M8 7h3M8 11h3M8 15h3"/>',
  wallet: '<rect x="3" y="6" width="18" height="13" rx="2"/><path d="M3 10h18M15.500 14.500h2.500"/>',
  percent: '<path d="M19 5 5 19"/><circle cx="7" cy="7" r="2.500"/><circle cx="17" cy="17" r="2.500"/>',
  calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',
  chat: '<path d="M4 5h16v11H9l-5 4V5z"/>',
  pin: '<path d="M12 21s7-6.200 7-11a7 7 0 0 0-14 0c0 4.800 7 11 7 11z"/><circle cx="12" cy="10" r="2.500"/>',
  settings: '<path d="M4 6h9M19 6h1M4 12h3M13 12h7M4 18h11M20 18h.01"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="17.500" cy="18" r="2"/>',
  shield: '<path d="M12 3 4 6v6c0 4.500 3.200 7.800 8 9 4.800-1.200 8-4.500 8-9V6l-8-3z"/><path d="M9 12l2 2 4-4"/>',
  logout: '<path d="M10 4H5v16h5M14 8l4 4-4 4M18 12H9"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  edit: '<path d="M4 20h4L19 9l-4-4L4 16v4z"/><path d="M13.500 6.500l4 4"/>',
  trash: '<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/>',
  check: '<path d="M5 12.500l4.500 4.500L19 7.500"/>',
  x: '<path d="M6 6l12 12M18 6 6 18"/>',
  key: '<circle cx="8" cy="15" r="4"/><path d="M11 12l9-9M16 7l3 3"/>',
  sms: '<rect x="7" y="2.500" width="10" height="19" rx="2"/><path d="M11 18h2"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  coins: '<circle cx="9" cy="9" r="6"/><path d="M14.800 9.200a6 6 0 1 1-5.600 5.600"/>',
  trend: '<path d="M3 17l6-6 4 4 8-8M15 7h6v6"/>',
  star: '<path d="M12 3l2.700 5.800 6.300.800-4.600 4.400 1.200 6.300L12 17.300l-5.600 3 1.200-6.300L3 9.600l6.300-.800L12 3z"/>',
  reply: '<path d="M9 7 4 12l5 5M4 12h10a6 6 0 0 1 6 6v1"/>',
  bell: '<path d="M6 16V11a6 6 0 0 1 12 0v5l1.500 2H4.500L6 16z"/><path d="M10 20.500a2.200 2.200 0 0 0 4 0"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.900 4.900l1.400 1.400M17.700 17.700l1.400 1.400M4.900 19.100l1.400-1.400M17.700 6.300l1.400-1.400"/>',
  moon: '<path d="M20 14.500A8 8 0 1 1 9.500 4a6.500 6.500 0 0 0 10.500 10.500z"/>',
};
const icon = (name, size = 18) =>
  `<svg class="ic" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] ?? ''}</svg>`;

// O menu, por grupos, e o ícone de cada secção.
const GROUPS = {
  admin: [
    ['', ['resumo']],
    ['Operação', ['corridas', 'mapa', 'intermunicipal', 'sos']],
    ['Pessoas', ['motoristas', 'revisoes', 'passageiros']],
    ['Instituições', ['frotas', 'empresas', 'postos']],
    ['Finanças', ['pagamentos', 'comissoes', 'mensalidades']],
    ['Atendimento', ['suporte', 'avisos', 'locais']],
    ['Sistema', ['definicoes', 'administradores']],
  ],
  fleet: [
    ['', ['resumo']],
    ['Operação', ['motoristas', 'viaturas', 'turnos', 'mapa', 'corridas', 'sos']],
    ['Finanças', ['contas', 'acertos']],
    ['Sistema', ['utilizadores']],
  ],
};
const SECTION_ICON = {
  resumo: 'home', corridas: 'car', mapa: 'map', intermunicipal: 'bus', sos: 'alert', motoristas: 'wheel', revisoes: 'file',
  passageiros: 'users', frotas: 'building', pagamentos: 'wallet', comissoes: 'percent', mensalidades: 'calendar',
  suporte: 'chat', avisos: 'bell', locais: 'pin', postos: 'star', empresas: 'building', contas: 'coins', acertos: 'wallet', viaturas: 'key', turnos: 'clock', utilizadores: 'users', consultas: 'file', definicoes: 'settings', administradores: 'shield',
};
/** Secção aberta (para o ícone do cabeçalho). */
let currentKey = 'resumo';

const header = (title, subtitle, extra = '') =>
  `<div class="head"><div class="head-title">${SECTION_ICON[currentKey] ? `<span class="head-ic">${icon(SECTION_ICON[currentKey], 22)}</span>` : ''}<div><h1>${esc(title)}</h1>${subtitle ? `<p class="muted">${esc(subtitle)}</p>` : ''}</div></div>${extra}</div>`;

/** Fotografia de perfil, ou a inicial do nome quando não há foto. Clicar na foto mostra-a em grande. */
const AVATAR_TONES = ['#fde68a', '#bbf7d0', '#bfdbfe', '#fecaca', '#ddd6fe', '#fed7aa'];
const avatar = (person) =>
  person.photoUrl
    ? `<button type="button" class="avatar" data-photo="${esc(person.photoUrl)}" aria-label="Ver a foto de ${esc(person.name)}"><img src="${esc(person.photoUrl)}" alt="" loading="lazy"></button>`
    : `<span class="avatar" style="background:${AVATAR_TONES[(person.name.codePointAt(0) ?? 0) % AVATAR_TONES.length]}" aria-hidden="true">${esc((person.name.replace(/[^\p{L}\p{N}]/gu, '')[0] ?? '?').toUpperCase())}</span>`;
/** Nome com a foto ao lado, para as listas de pessoas. */
const person = (p, sub = '') => `<div class="person">${avatar(p)}<div><strong>${esc(p.name)}</strong>${sub ? `<br><span class="muted">${sub}</span>` : ''}</div></div>`;
function bindPhotos() {
  view.querySelectorAll('[data-photo]').forEach(
    (b) =>
      (b.onclick = () => {
        $('#viewer img').src = b.dataset.photo;
        $('#viewer img').alt = b.getAttribute('aria-label').replace('Ver a foto', 'Foto');
        $('#viewer').showModal();
      }),
  );
}

/** Campo "repita a palavra-passe" para as janelas, e a verificação que o acompanha. */
const CONFIRM_FIELD = { name: 'confirm', label: 'Repita a palavra-passe', type: 'password', minlength: 8, autocomplete: 'new-password' };
function checkConfirm(password, confirmation) {
  if (password !== confirmation) throw new Error('As duas palavras-passe não são iguais.');
}

/** Botão com ícone. */
const ibtn = (ic, label, attrs = '', cls = '') => `<button type="button" class="btn ${cls}" ${attrs}>${icon(ic, 16)}<span>${esc(label)}</span></button>`;

/**
 * Janela para criar ou editar. `fields`: { name, label, type, value, required,
 * min, max, step, maxlength, placeholder, hint, options: [[valor, texto]] }.
 * `onSubmit(valores)` pode lançar um erro, que aparece dentro da janela.
 * Com `submit: null`, a janela só informa (botão "Fechar").
 */
function modal({ title, intro = '', fields = [], html = '', submit = 'Guardar', danger = false, wide = false, onSubmit }) {
  const dlg = $('#modal');
  dlg.className = wide ? 'wide' : '';
  const attr = (k, v) => (v === undefined || v === null || v === false ? '' : v === true ? ` ${k}` : ` ${k}="${esc(v)}"`);
  const field = (f) => {
    const common = attr('name', f.name) + attr('required', f.required !== false) + attr('placeholder', f.placeholder) + attr('maxlength', f.maxlength) + attr('minlength', f.minlength);
    let input;
    if (f.type === 'select') {
      input = `<select${common}>${f.options.map(([v, t]) => `<option value="${esc(v)}"${String(v) === String(f.value ?? '') ? ' selected' : ''}>${esc(t)}</option>`).join('')}</select>`;
    } else if (f.type === 'textarea') {
      input = `<textarea${common} rows="${f.rows ?? 3}">${esc(f.value ?? '')}</textarea>`;
    } else {
      input = `<input type="${f.type ?? 'text'}"${common}${attr('value', f.value)}${attr('min', f.min)}${attr('max', f.max)}${attr('step', f.step)}${attr('inputmode', f.inputmode)}${attr('autocomplete', f.autocomplete ?? 'off')}>`;
    }
    return `<label class="${f.half ? 'half' : ''}">${esc(f.label)}${input}${f.hint ? `<small>${esc(f.hint)}</small>` : ''}</label>`;
  };
  dlg.innerHTML = `<form class="modal">
    <header><h2 id="modal-title">${esc(title)}</h2><button type="button" class="x" data-close aria-label="Fechar">${icon('x', 20)}</button></header>
    ${intro ? `<p class="muted">${esc(intro)}</p>` : ''}
    ${html}
    <div class="fields">${fields.map(field).join('')}</div>
    <p class="error" role="alert" hidden></p>
    <footer>
      <button type="button" class="btn" data-close>${submit ? 'Cancelar' : 'Fechar'}</button>
      ${submit ? `<button type="submit" class="btn ${danger ? 'danger solid' : 'primary'}">${esc(submit)}</button>` : ''}
    </footer>
  </form>`;
  const form = $('form', dlg);
  dlg.querySelectorAll('[data-close]').forEach((b) => (b.onclick = () => dlg.close()));
  form.onsubmit = async (e) => {
    e.preventDefault();
    const error = $('.error', form);
    const button = $('button[type=submit]', form);
    error.hidden = true;
    button.disabled = true;
    try {
      await onSubmit(Object.fromEntries(new FormData(form).entries()));
      dlg.close();
    } catch (err) {
      error.textContent = err.message || String(err);
      error.hidden = false;
      button.disabled = false;
    }
  };
  dlg.showModal();
  (form.querySelector('input:not([type=hidden]), select, textarea') ?? form.querySelector('[data-close]')).focus();
  return form;
}

function showError(err) {
  const box = document.createElement('p');
  box.className = 'error';
  box.setAttribute('role', 'alert');
  box.textContent = err.message || String(err);
  view.prepend(box);
}

/** Corre uma acção de um botão, desligando-o enquanto decorre. */
async function act(button, fn) {
  button.disabled = true;
  try {
    await fn();
  } catch (err) {
    button.disabled = false;
    view.querySelectorAll('.error').forEach((e) => e.remove());
    showError(err);
  }
}

// ── Secções ─────────────────────────────────────────────────────────────────

const stat = (n, label, alert = false, ic = '', tone = '') =>
  `<div class="card${alert ? ' alert' : ''}">${ic ? `<span class="card-ic ${tone}">${icon(ic, 20)}</span>` : ''}<div><div class="n">${esc(n)}</div><div class="l">${esc(label)}</div></div></div>`;
const percentText = (rate) => `${String(Math.round(rate * 1000) / 10).replace('.', ',')} %`;

const sections = {
  // ─────────── Administrador ───────────
  admin: {
    resumo: {
      label: 'Resumo',
      refresh: 20000,
      async render() {
        const s = await api('/admin/resumo');
        setCount('revisoes', s.pendingDocs);
        setCount('frotas', s.pendingFleets);
        setCount('sos', s.sosToday);
        setCount('suporte', s.openTickets);
        setCount('pagamentos', s.pendingPayments);
        setCount('locais', s.placesToReview);
        const todo = [
          ['revisoes', s.pendingDocs, s.pendingDocs === 1 ? 'documento por rever' : 'documentos por rever'],
          ['pagamentos', s.pendingPayments, s.pendingPayments === 1 ? 'pagamento por confirmar' : 'pagamentos por confirmar'],
          ['suporte', s.openTickets, s.openTickets === 1 ? 'pedido de suporte por responder' : 'pedidos de suporte por responder'],
          ['frotas', s.pendingFleets, s.pendingFleets === 1 ? 'frota por aprovar' : 'frotas por aprovar'],
          ['locais', s.placesToReview, s.placesToReview === 1 ? 'local por rever' : 'locais por rever'],
          ['sos', s.sosToday, s.sosToday === 1 ? 'alerta SOS hoje' : 'alertas SOS hoje'],
        ].filter(([, n]) => n > 0);
        const max = Math.max(1, ...s.days.map((d) => d.rides));
        const weekday = (iso) => new Date(iso).toLocaleDateString('pt-PT', { weekday: 'long' }).slice(0, 3);
        view.innerHTML =
          hero(`Olá, ${session.name}`, 'O estado da plataforma neste momento.') +
          `<h2>A pedir a sua atenção</h2>
          ${
            todo.length
              ? `<div class="todo">${todo
                  .map(([key, n, text]) => `<a href="#${key}" class="${key === 'sos' ? 'urgent' : ''}">${icon(SECTION_ICON[key], 22)}<span><b>${esc(n)}</b> ${esc(text)}</span>${icon('reply', 16)}</a>`)
                  .join('')}</div>`
              : `<div class="allgood">${icon('check', 22)}<span>Está tudo em dia: não há nada à espera de resposta.</span></div>`
          }
          <h2>Agora</h2>
          <div class="cards">
            ${stat(s.online, `motoristas online (de ${s.drivers})`, false, 'wheel', 'green')}
            ${stat(s.onTrip, 'corridas a decorrer', false, 'car', 'yellow')}
            ${stat(s.passengers, 'passageiros registados', false, 'users', 'blue')}
            ${stat(kz(s.commissionDue), 'comissões por receber', false, 'coins', 'amber')}
          </div>
          <div class="split">
            <div class="panel">
              <h2>Corridas concluídas nos últimos 7 dias</h2>
              <div class="chart" role="img" aria-label="Corridas concluídas por dia: ${esc(s.days.map((d) => `${weekday(d.date)} ${d.rides}`).join(', '))}">
                ${s.days
                  .map(
                    (d, i) =>
                      `<div class="bar${i === s.days.length - 1 ? ' today' : ''}" title="${esc(d.rides)} corridas · ${kz(d.revenue)}"><span class="v">${esc(d.rides)}</span><i style="height:${Math.round((d.rides / max) * 100)}%"></i><span class="d">${esc(weekday(d.date))}</span></div>`,
                  )
                  .join('')}
              </div>
            </div>
            <div class="panel">
              <h2>Valores</h2>
              <table class="mini">
                <thead><tr><th scope="col"></th><th scope="col" class="num">Hoje</th><th scope="col" class="num">7 dias</th></tr></thead>
                <tbody>
                  <tr><th scope="row">Corridas concluídas</th><td class="num">${esc(s.today.rides)}</td><td class="num">${esc(s.week.rides)}</td></tr>
                  <tr><th scope="row">Valor das corridas</th><td class="num">${kz(s.today.revenue)}</td><td class="num">${kz(s.week.revenue)}</td></tr>
                  <tr><th scope="row">Comissão do Bazá</th><td class="num">${kz(s.today.commission)}</td><td class="num">${kz(s.week.commission)}</td></tr>
                </tbody>
              </table>
              <p class="muted small">Comissão das corridas: ${esc(percentText(s.commissionRate))}. <a href="#definicoes">Alterar nas Definições</a></p>
            </div>
          </div>
          ${
            s.sms
              ? `<h2>SMS de confirmação</h2>
                 <div class="cards">
                   ${stat(s.sms.available.toLocaleString('pt-PT'), 'SMS disponíveis', s.sms.available < 200, 'sms', 'blue')}
                   ${stat(s.sms.sent.toLocaleString('pt-PT'), 'SMS enviados pela conta', false, 'trend', 'green')}
                 </div>
                 ${s.sms.planExpired ? '<p class="notice">O fornecedor de SMS indica o plano como expirado. Confirme com a TelcoSMS se os envios continuam activos.</p>' : ''}`
              : ''
          }`;
      },
    },

    revisoes: {
      label: 'Documentos',
      async render() {
        const { drivers } = await api('/admin/revisoes');
        setCount('revisoes', drivers.length);
        const docBlock = (driverId, target, title, details, docs) => `
          <div class="doc-row" data-driver="${esc(driverId)}" data-target="${esc(target)}">
            <div class="info"><strong>${esc(title)}</strong><br><span class="muted">${details}</span>
              <div class="row-actions" style="margin-top:10px">
                <button class="btn primary small" data-approve>Aprovar</button>
                <button class="btn danger small" data-reject>Rejeitar…</button>
              </div>
            </div>
            <div class="thumbs">${docs
              .map(([doc, label]) => `<button type="button" data-doc="${esc(doc)}" aria-label="Ver ${esc(label)}">${esc(label)}</button>`)
              .join('')}</div>
          </div>`;
        view.innerHTML =
          header('Documentos por rever', 'Cartas de condução e documentos das viaturas (livrete, título e seguro).') +
          (drivers.length
            ? `<div class="review">${drivers
                .map(
                  (d) => `<div class="panel">
                    <div class="who-row">
                      ${d.photoUrl ? `<img class="face" src="${esc(d.photoUrl)}" alt="Foto de perfil de ${esc(d.name)}">` : ''}
                      <div><h2>${esc(d.name)}</h2>
                      <span class="muted">${esc(d.phone ?? '')}${d.fleet ? ` · Frota ${esc(d.fleet)}` : ''}</span></div>
                    </div>
                    ${
                      d.license
                        ? docBlock(
                            d.id,
                            'carta',
                            'Carta de condução',
                            `N.º ${esc(d.license.number)} · categoria ${esc(d.license.category)} · válida até ${esc(day(d.license.expiresAt))}`,
                            [['carta-frente', 'Frente'], ['carta-verso', 'Verso']],
                          )
                        : ''
                    }
                    ${d.vehicles
                      .map((v) =>
                        docBlock(
                          d.id,
                          v.id,
                          `Documentos da viatura — ${v.label}`,
                          `${esc(v.category)} · ${esc(v.color)} · matrícula ${esc(v.plate)} · seguro válido até ${esc(day(v.insuranceExpiresAt))}`,
                          [[`livrete-${v.id}`, 'Livrete'], [`titulo-${v.id}`, 'Título'], [`seguro-${v.id}`, 'Seguro']],
                        ),
                      )
                      .join('')}
                  </div>`,
                )
                .join('')}</div>`
            : `<div class="table-wrap"><div class="empty">Não há documentos à espera de revisão.</div></div>`);

        // Miniaturas: as fotos são privadas, por isso pedem-se com a sessão.
        view.querySelectorAll('.thumbs button').forEach(async (btn) => {
          const row = btn.closest('.doc-row');
          try {
            const res = await fetch(`${API}/admin/documentos/${row.dataset.driver}/${btn.dataset.doc}`, {
              headers: { Authorization: `Bearer ${session.token}` },
            });
            if (!res.ok) throw new Error();
            const url = URL.createObjectURL(await res.blob());
            const img = new Image();
            img.src = url;
            img.alt = btn.getAttribute('aria-label').replace('Ver ', '');
            btn.replaceChildren(img);
            btn.onclick = () => {
              $('#viewer img').src = url;
              $('#viewer').showModal();
            };
          } catch {
            btn.textContent = 'Não foi possível carregar';
          }
        });

        const decide = (row, approve, note) =>
          api(`/admin/revisoes/${row.dataset.driver}`, {
            method: 'POST',
            body: { target: row.dataset.target, approve, note },
          }).then(() => go('revisoes'));
        view.querySelectorAll('[data-approve]').forEach((b) => (b.onclick = () => act(b, () => decide(b.closest('.doc-row'), true))));
        view.querySelectorAll('[data-reject]').forEach(
          (b) =>
            (b.onclick = () =>
              modal({
                title: 'Rejeitar documento',
                intro: 'O motorista vê este motivo no app e pode enviar o documento de novo.',
                fields: [{ name: 'note', label: 'Motivo', type: 'textarea', maxlength: 200, placeholder: 'Ex.: a fotografia está desfocada' }],
                submit: 'Rejeitar',
                danger: true,
                onSubmit: (v) => decide(b.closest('.doc-row'), false, v.note),
              })),
        );
      },
    },

    motoristas: {
      label: 'Motoristas',
      async render(query = '') {
        const { drivers } = await api(`/admin/motoristas${query ? `?q=${encodeURIComponent(query)}` : ''}`);
        view.innerHTML =
          header('Motoristas', `${drivers.length} ${query ? 'encontrados' : 'registados'}`, searchBox(query)) +
          table(
            ['Motorista', 'Frota', 'Viatura', 'Documentos', 'Estado', { label: 'Hoje', num: true }, 'Registo', ''],
            drivers.map(
              (d) => `<tr>
                <td>${person(d, `${esc(d.phone ?? d.email ?? '')}${d.phoneVerified === false ? ' · <span class="muted" title="A conta foi criada quando o SMS falhou; o app pede a confirmação quando o SMS voltar a funcionar">número por confirmar</span>' : ''}${d.rating ? ` · ★ ${esc(d.rating)}` : ''}`)}</td>
                <td>${esc(d.fleet ?? '—')}</td>
                <td>${d.vehicle ? `${esc(d.vehicle.category)} · ${esc(d.vehicle.label)}<br><span class="muted">${esc(d.vehicle.color)} · ${esc(d.vehicle.plate)}</span>` : '—'}</td>
                <td>${badge(VERIFICATION[d.verification])}</td>
                <td>${driverState(d)}${d.blocked && d.blockedReason ? `<br><span class="muted small">${esc(d.blockedReason)}</span>` : ''}</td>
                <td class="num">${esc(d.ridesToday)} corridas<br><span class="muted">${kz(d.revenueToday)}</span></td>
                <td>${esc(day(d.createdAt))}</td>
                <td><button class="btn small" data-star="${esc(d.id)}" data-kind="motoristas" data-value="${!d.star}" title="Utilizador estrela: pode registar locais no mapa a partir do app">${d.star ? '★ Estrela' : '☆ Tornar estrela'}</button> ${ibtn('bell', 'Avisar', `data-notice="${esc(d.id)}" data-kind="motoristas" data-name="${esc(d.name)}"`, 'small')} <button class="btn small" data-reset="${esc(d.id)}" data-kind="motoristas" data-name="${esc(d.name || d.phone || '')}" title="Cria uma senha provisória para quem esqueceu a senha e não recebe o código SMS">Repor senha</button> ${ibtn('file', d.blocked ? 'Rever e reactivar' : 'Ver ficha', `data-ficha="${esc(d.id)}"`, `small${d.blocked ? ' primary' : ''}`)}</td>
              </tr>`,
            ),
            query ? 'Nenhum motorista corresponde à pesquisa.' : 'Ainda não há motoristas registados.',
          );
        bindPhotos();
        bindNotices();
        bindSearch((q) => sections.admin.motoristas.render(q));
        bindStars(() => sections.admin.motoristas.render(query));
        bindResets();
        view.querySelectorAll('[data-ficha]').forEach((b) => (b.onclick = () => act(b, () => driverFile(b.dataset.ficha, () => sections.admin.motoristas.render(query)).finally(() => (b.disabled = false)))));
      },
    },

    frotas: {
      label: 'Frotas',
      async render() {
        const { fleets } = await api('/admin/frotas');
        setCount('frotas', fleets.filter((f) => f.status === 'pending').length);
        const STATUS = { pending: ['wait', 'Por aprovar'], active: ['ok', 'Activa'], suspended: ['bad', 'Suspensa'] };
        view.innerHTML =
          header('Frotas', 'Empresas parceiras com motoristas próprios.') +
          table(
            ['Empresa', 'Contacto', { label: 'Motoristas', num: true }, 'Estado', 'Registo', ''],
            fleets.map(
              (f) => `<tr>
                <td><strong>${esc(f.name)}</strong><br><span class="muted">NIF ${esc(f.nif)}</span></td>
                <td>${esc(f.email)}<br><span class="muted">${esc(f.phone)}</span></td>
                <td class="num">${esc(f.drivers)}</td>
                <td>${badge(STATUS[f.status])}</td>
                <td>${esc(day(f.createdAt))}</td>
                <td><div class="row-actions">
                  ${f.status !== 'active' ? `<button class="btn primary small" data-fleet="${esc(f.id)}" data-status="active">${f.status === 'pending' ? 'Aprovar' : 'Reactivar'}</button>` : ''}
                  ${f.status === 'active' ? `<button class="btn danger small" data-fleet="${esc(f.id)}" data-status="suspended">Suspender</button>` : ''}
                </div></td>
              </tr>`,
            ),
            'Ainda nenhuma frota se registou.',
          );
        view.querySelectorAll('[data-fleet]').forEach(
          (b) =>
            (b.onclick = () =>
              act(b, () =>
                api(`/admin/frotas/${b.dataset.fleet}/estado`, { method: 'POST', body: { status: b.dataset.status } }).then(() =>
                  go('frotas'),
                ),
              )),
        );
      },
    },

    empresas: {
      label: 'Empresas clientes',
      async render() {
        const d = await api('/admin/empresas');
        const monthName = (key) => new Date(`${key}-15`).toLocaleDateString('pt-PT', { month: 'long', year: 'numeric' });
        const again = () => go('empresas');
        const fields = (c = {}) => [
          { name: 'name', label: 'Nome da empresa', value: c.name, minlength: 2, maxlength: 100 },
          { name: 'nif', label: 'NIF', value: c.nif, required: false, maxlength: 20, half: true },
          { name: 'monthlyLimit', label: 'Limite por mês (Kz)', type: 'number', min: 0, step: 1000, value: c.monthlyLimit ?? 0, half: true, hint: '0 = sem limite.' },
          { name: 'contactName', label: 'Pessoa de contacto', value: c.contactName, required: false, maxlength: 80 },
          { name: 'phone', label: 'Telefone', type: 'tel', value: c.phone, required: false, half: true },
          { name: 'email', label: 'Email', type: 'email', value: c.email, required: false, half: true },
        ];
        view.innerHTML =
          header(
            'Empresas clientes',
            'Os colaboradores autorizados viajam por conta da empresa: não pagam ao motorista, e a empresa recebe a conta no fim do mês. O Bazá paga ao motorista (Finanças › Comissões).',
            ibtn('plus', 'Nova empresa', 'id="new-company"', 'primary'),
          ) +
          `<div class="cards">
            ${stat(d.companies.filter((c) => c.active).length, 'empresas activas', false, 'building', 'blue')}
            ${stat(kz(d.companies.reduce((n, c) => n + c.current.total, 0)), `corridas em ${monthName(d.months.current)}`, false, 'trend', 'green')}
            ${stat(kz(d.companies.reduce((n, c) => n + Math.max(0, c.previous.total - c.previous.paid), 0)), `por receber de ${monthName(d.months.previous)}`, false, 'coins', 'amber')}
          </div>` +
          (d.companies.length
            ? d.companies
                .map(
                  (c, i) => `<div class="panel station">
                    <div class="panel-head">
                      <div><h2>${esc(c.name)} ${c.active ? '' : badge(['off', 'Desactivada'])}</h2>
                      <p class="muted">${esc([c.nif && `NIF ${c.nif}`, c.contactName, c.phone, c.email].filter(Boolean).join(' · ') || 'Sem contactos')} · ${c.monthlyLimit ? `limite de ${kz(c.monthlyLimit)} por mês` : 'sem limite mensal'}</p></div>
                      <div class="row-actions">${ibtn('plus', 'Colaborador', `data-member-add="${i}"`, 'small primary')}${ibtn('file', 'Conta do mês', `data-statement="${i}"`, 'small')}${ibtn('edit', 'Editar', `data-company="${i}"`, 'small')}</div>
                    </div>
                    <div class="fees">
                      <div><span class="muted">Este mês</span><b>${kz(c.current.total)}</b><span class="muted small">${esc(c.current.rides)} corridas</span></div>
                      <div><span class="muted">Mês anterior</span><b>${kz(c.previous.total)}</b><span class="muted small">${c.previous.total - c.previous.paid > 0 ? `faltam ${kz(c.previous.total - c.previous.paid)}` : 'pago'}</span></div>
                    </div>
                    <p class="small" style="margin:12px 0 0">${
                      c.members.length
                        ? `<strong>Colaboradores autorizados:</strong> ${c.members.map((m) => `${esc(m.name || m.phone)} <span class="muted">${m.name ? esc(m.phone) : ''}</span> <button class="btn small danger" data-member-del="${esc(c.id)}/${esc(m.id)}" data-name="${esc(m.name || m.phone)}" aria-label="Retirar ${esc(m.name || m.phone)}">${icon('x', 14)}</button>`).join(' · ')}`
                        : '<span class="muted">Ainda sem colaboradores autorizados. Sem eles, ninguém viaja por conta desta empresa.</span>'
                    }</p>
                  </div>`,
                )
                .join('')
            : '<div class="table-wrap"><div class="empty">Ainda não há empresas clientes. Registe a primeira em "Nova empresa".</div></div>');
        $('#new-company').onclick = () => modal({ title: 'Nova empresa cliente', fields: fields(), submit: 'Registar', onSubmit: (v) => api('/admin/empresas', { method: 'POST', body: v }).then(again) });
        view.querySelectorAll('[data-company]').forEach((b) => {
          const c = d.companies[b.dataset.company];
          b.onclick = () =>
            modal({
              title: c.name,
              fields: [...fields(c), { name: 'active', label: 'Estado', type: 'select', value: c.active ? 'true' : '', options: [['true', 'Activa'], ['', 'Desactivada — os colaboradores deixam de viajar por conta dela']] }],
              onSubmit: (v) => api(`/admin/empresas/${c.id}`, { method: 'POST', body: { ...v, active: v.active === 'true' } }).then(again),
            });
        });
        view.querySelectorAll('[data-member-add]').forEach((b) => {
          const c = d.companies[b.dataset.memberAdd];
          b.onclick = () =>
            modal({
              title: `Novo colaborador · ${c.name}`,
              intro: 'Use o número com que a pessoa entra no Bazá como passageiro. Ao pedir uma corrida, passa a poder escolher "Conta da empresa".',
              fields: [
                { name: 'name', label: 'Nome', required: false, maxlength: 80 },
                { name: 'phone', label: 'Telefone', type: 'tel', placeholder: '923 456 789' },
              ],
              submit: 'Autorizar',
              onSubmit: (v) => api(`/admin/empresas/${c.id}/colaboradores`, { method: 'POST', body: v }).then(again),
            });
        });
        view.querySelectorAll('[data-member-del]').forEach(
          (b) =>
            (b.onclick = () => {
              const [cid, mid] = b.dataset.memberDel.split('/');
              if (confirm(`Retirar ${b.dataset.name}? Deixa de poder viajar por conta da empresa.`)) act(b, () => api(`/admin/empresas/${cid}/colaboradores/${mid}`, { method: 'DELETE' }).then(again));
            }),
        );
        // A conta de um mês: as corridas, o que foi pago e o que falta.
        const statement = async (c, month) => {
          const s = await api(`/admin/empresas/${c.id}/conta?mes=${month}`);
          modal({
            title: `${c.name} · ${monthName(month)}`,
            wide: true,
            html: `<div class="ficha">
                <div class="row-actions" style="justify-content:flex-start;margin-bottom:10px"><button type="button" class="btn small${month === d.months.current ? ' primary' : ''}" data-month="${d.months.current}">${esc(monthName(d.months.current))}</button><button type="button" class="btn small${month === d.months.previous ? ' primary' : ''}" data-month="${d.months.previous}">${esc(monthName(d.months.previous))}</button></div>
                <div class="facts"><div class="fact"><b>${kz(s.total)}</b><span>${esc(s.rides.length)} corridas</span></div><div class="fact"><b>${kz(s.paid)}</b><span>já pago</span></div><div class="fact${s.balance > 0 ? ' bad' : ''}"><b>${kz(Math.max(0, s.balance))}</b><span>por pagar</span></div></div>
                <h3>Corridas</h3>
                ${s.rides.length ? `<table class="mini">${s.rides.map((r) => `<tr><td>${esc(when(r.completedAt))}</td><td>${esc(r.passenger)}</td><td>${esc(r.from)}<span class="muted"> → ${esc(r.to)}</span></td><td class="num">${kz(r.fare)}</td></tr>`).join('')}</table>` : '<p class="muted">Sem corridas neste mês.</p>'}
                ${s.payments.length ? `<h3>Pagamentos recebidos</h3><table class="mini">${s.payments.map((p) => `<tr><td>${esc(when(p.createdAt))}</td><td>${esc(p.note || '—')}</td><td>${esc(p.by)}</td><td class="num">${kz(p.amount)}</td></tr>`).join('')}</table>` : ''}
              </div>`,
            fields: s.balance > 0 ? [{ name: 'amount', label: 'Registar pagamento recebido (Kz)', type: 'number', min: 1, value: s.balance, half: true }, { name: 'note', label: 'Nota', required: false, maxlength: 120, half: true }] : [],
            submit: s.balance > 0 ? 'Registar pagamento' : null,
            onSubmit: (v) => api(`/admin/empresas/${c.id}/pagamento`, { method: 'POST', body: { month, amount: v.amount, note: v.note } }).then(again),
          });
          $('#modal').querySelectorAll('[data-month]').forEach((m) => (m.onclick = () => statement(c, m.dataset.month).catch(showError)));
          $('#modal').scrollTop = 0;
        };
        view.querySelectorAll('[data-statement]').forEach((b) => {
          const c = d.companies[b.dataset.statement];
          b.onclick = () => act(b, () => statement(c, d.months.current).finally(() => (b.disabled = false)));
        });
      },
    },

    postos: {
      label: 'Postos policiais',
      render: () => renderPostos(),
    },

    passageiros: {
      label: 'Passageiros',
      async render(query = '') {
        const { passengers } = await api(`/admin/passageiros${query ? `?q=${encodeURIComponent(query)}` : ''}`);
        view.innerHTML =
          header('Passageiros', `${passengers.length} ${query ? 'encontrados' : 'registados'}`, searchBox(query)) +
          table(
            ['Passageiro', 'Contacto', { label: 'Corridas', num: true }, { label: 'Avaliação', num: true }, 'Registo', ''],
            passengers.map(
              (p) => `<tr>
                <td>${person(p)}</td>
                <td>${esc(p.phone ?? p.email ?? '—')}${p.deactivated ? '<br><span class="muted small" title="O número é também de um motorista: cada número só pode ter um tipo de conta. As corridas ficam no histórico.">Desactivada · número de motorista</span>' : ''}${p.phoneVerified === false ? '<br><span class="muted small" title="A conta foi criada quando o SMS falhou; o app pede a confirmação quando o SMS voltar a funcionar">Número por confirmar</span>' : ''}</td>
                <td class="num">${esc(p.rides)}</td>
                <td class="num">${p.rating ? `★ ${esc(p.rating)}` : '—'}</td>
                <td>${esc(day(p.createdAt))}</td>
                <td><button class="btn small" data-star="${esc(p.id)}" data-kind="passageiros" data-value="${!p.star}" title="Utilizador estrela: pode registar locais no mapa a partir do app">${p.star ? '★ Estrela' : '☆ Tornar estrela'}</button> ${ibtn('bell', 'Avisar', `data-notice="${esc(p.id)}" data-kind="passageiros" data-name="${esc(p.name)}"`, 'small')} <button class="btn small" data-reset="${esc(p.id)}" data-kind="passageiros" data-name="${esc(p.name || p.phone || '')}" title="Cria uma senha provisória para quem esqueceu a senha e não recebe o código SMS">Repor senha</button></td>
              </tr>`,
            ),
            query ? 'Nenhum passageiro corresponde à pesquisa.' : 'Ainda não há passageiros registados.',
          );
        bindPhotos();
        bindNotices();
        bindSearch((q) => sections.admin.passageiros.render(q));
        bindStars(() => sections.admin.passageiros.render(query));
        bindResets();
      },
    },

    corridas: { label: 'Corridas', refresh: 20000, render: () => renderRides('/admin/corridas', true) },
    mapa: { label: 'Mapa ao vivo', render: () => renderMap('/admin/motoristas') },

    sos: {
      label: 'Alertas SOS',
      refresh: 15000,
      async render() {
        const { alerts } = await api('/admin/sos');
        view.innerHTML = header('Alertas SOS', 'Alertas de perigo accionados por passageiros ou motoristas durante uma corrida. Os postos policiais mais próximos são avisados de imediato.') + sosTable(alerts);
      },
    },

    pagamentos: {
      label: 'Pagamentos',
      refresh: 30000,
      async render(estado = 'pending') {
        const data = await api(`/admin/pagamentos?estado=${estado}`);
        setCount('pagamentos', data.pending);
        const METHOD = { transfer: 'Transferência ou depósito', cash: 'Dinheiro', multicaixa: 'Multicaixa Express' };
        const tab = (key, label) =>
          `<button class="btn small${estado === key ? ' primary' : ''}" data-estado="${key}"${estado === key ? ' aria-pressed="true"' : ''}>${esc(label)}</button>`;
        view.innerHTML =
          header(
            'Pagamentos',
            'Pagamentos de mensalidades e comissões que os motoristas comunicaram no app. Confirme só depois de verificar que o dinheiro entrou.',
            `<div class="inline-form">${tab('pending', `Por confirmar (${data.pending})`)}${tab('confirmed', 'Confirmados')}${tab('rejected', 'Rejeitados')}</div>`,
          ) +
          table(
            ['Data', 'Motorista', 'Pagamento', { label: 'Valor', num: true }, 'Como pagou', estado === 'pending' ? 'Decisão' : 'Resultado'],
            data.requests.map(
              (r) => `<tr>
                <td>${esc(when(r.createdAt))}</td>
                <td><strong>${esc(r.driver)}</strong><br><span class="muted">${esc(r.phone ?? '')}</span></td>
                <td>${
                  r.kind === 'subscription'
                    ? `Mensalidade · ${esc(r.months)} ${r.months === 1 ? 'mês' : 'meses'}<br><span class="muted">${esc(r.categoryLabel ?? '')} ${esc(r.plate ?? '')}</span>`
                    : 'Comissões de corridas'
                }</td>
                <td class="num"><strong>${kz(r.amount)}</strong></td>
                <td>${esc(METHOD[r.method] ?? r.method)}${r.reference ? `<br><span class="muted">Ref.: ${esc(r.reference)}</span>` : ''}</td>
                <td>${
                  estado === 'pending'
                    ? `<button class="btn small primary" data-pay-ok="${esc(r.id)}" data-what="${kz(r.amount)} de ${esc(r.driver)}">Confirmar</button> <button class="btn small danger" data-pay-no="${esc(r.id)}">Rejeitar</button>`
                    : `${badge(r.status === 'confirmed' ? ['ok', 'Confirmado'] : ['bad', 'Rejeitado'])} ${esc(r.reviewedBy ?? '')}${r.note ? `<br><span class="muted">${esc(r.note)}</span>` : ''}`
                }</td>
              </tr>`,
            ),
            estado === 'pending' ? 'Não há pagamentos por confirmar.' : 'Nada para mostrar.',
          );
        const again = () => sections.admin.pagamentos.render(estado);
        view.querySelectorAll('[data-estado]').forEach((b) => (b.onclick = () => sections.admin.pagamentos.render(b.dataset.estado).catch(showError)));
        view.querySelectorAll('[data-pay-ok]').forEach(
          (b) =>
            (b.onclick = () => {
              if (!confirm(`Confirmar que recebeu ${b.dataset.what}?`)) return;
              act(b, () => api(`/admin/pagamentos/${b.dataset.payOk}`, { method: 'POST', body: { approve: true } }).then(again));
            }),
        );
        view.querySelectorAll('[data-pay-no]').forEach(
          (b) =>
            (b.onclick = () =>
              modal({
                title: 'Rejeitar pagamento',
                intro: 'O motorista vê este motivo no app.',
                fields: [{ name: 'note', label: 'Motivo', type: 'textarea', maxlength: 200, placeholder: 'Ex.: não encontrámos a transferência' }],
                submit: 'Rejeitar',
                danger: true,
                onSubmit: (v) => api(`/admin/pagamentos/${b.dataset.payNo}`, { method: 'POST', body: { approve: false, note: v.note.trim() } }).then(again),
              })),
        );
      },
    },

    comissoes: {
      label: 'Comissões',
      async render() {
        const c = await api('/admin/comissoes');
        view.innerHTML =
          header('Comissões', 'O que cada motorista deve ao Bazá pelas corridas e viagens pagas em dinheiro.') +
          `<div class="cards">
            ${stat(kz(c.totalDue), 'por receber, no total', false, 'coins', 'amber')}
            ${stat(c.drivers.length, 'motoristas com valores por pagar', false, 'wheel', 'blue')}
            ${stat(percentText(c.rate), 'comissão por corrida', false, 'percent', 'yellow')}
          </div>
          <p class="notice">${
            c.enforced
              ? `Bloqueio activo: quem dever mais de ${kz(c.limit)} não pode ficar online.`
              : `Por agora a dívida é só registada. O bloqueio automático acima de ${kz(c.limit)} está desligado (activa-se no servidor com COMMISSION_ENFORCED=true).`
          }${c.walletEnabled ? ' Com a carteira ligada, as comissões saem da carteira do motorista e não aparecem aqui.' : ''} A percentagem altera-se em <a href="#definicoes">Definições</a>.</p>
          <h2>Motoristas com comissões por pagar</h2>` +
          table(
            ['Motorista', 'Frota', { label: 'Deve', num: true }, ''],
            c.drivers.map(
              (d) => `<tr>
                <td><strong>${esc(d.name)}</strong><br><span class="muted">${esc(d.phone ?? '')}</span></td>
                <td>${esc(d.fleet ?? '—')}</td>
                <td class="num"><strong>${kz(d.due)}</strong>${d.overLimit ? `<br>${badge(['bad', 'Acima do limite'])}` : ''}</td>
                <td class="num">${ibtn('plus', 'Registar pagamento', `data-pay="${esc(d.id)}" data-due="${esc(d.due)}" data-name="${esc(d.name)}"`, 'small primary')}</td>
              </tr>`,
            ),
            'Nenhum motorista tem comissões por pagar.',
          ) +
          (c.toPay.length
            ? `<h2>A pagar aos motoristas</h2>
               <p class="muted">Corridas por conta de empresas clientes: o passageiro não pagou ao motorista, por isso o Bazá deve-lhe o valor da corrida menos a comissão. Total: <strong>${kz(c.totalToPay)}</strong>.</p>` +
              table(
                ['Motorista', 'Frota', { label: 'A receber', num: true }, ''],
                c.toPay.map(
                  (d) => `<tr>
                    <td><strong>${esc(d.name)}</strong><br><span class="muted">${esc(d.phone ?? '')}</span></td>
                    <td>${esc(d.fleet ?? '—')}</td>
                    <td class="num"><strong>${kz(d.amount)}</strong></td>
                    <td class="num">${ibtn('check', 'Registar pagamento feito', `data-payout="${esc(d.id)}" data-amount="${esc(d.amount)}" data-name="${esc(d.name)}"`, 'small primary')}</td>
                  </tr>`,
                ),
                '',
              )
            : '') +
          '<h2>Últimos movimentos</h2>' +
          table(
            ['Data', 'Motorista', 'Movimento', { label: 'Valor', num: true }, 'Nota', 'Registado por'],
            c.payments.map(
              (p) => `<tr><td>${esc(when(p.createdAt))}</td><td>${esc(p.driver)}</td><td>${p.type === 'payout' ? badge(['trip', 'Pago ao motorista']) : badge(['ok', 'Recebido do motorista'])}</td><td class="num">${kz(p.amount)}</td><td>${esc(p.note || '—')}</td><td>${esc(p.by)}</td></tr>`,
            ),
            'Ainda não foi registado nenhum pagamento.',
          );
        view.querySelectorAll('[data-payout]').forEach(
          (b) =>
            (b.onclick = () =>
              modal({
                title: `Pagar a ${b.dataset.name}`,
                intro: `O Bazá deve ${kz(Number(b.dataset.amount))}. Registe só depois de fazer o pagamento.`,
                fields: [
                  { name: 'amount', label: 'Valor pago (Kz)', type: 'number', min: 1, max: b.dataset.amount, value: b.dataset.amount },
                  { name: 'note', label: 'Nota', required: false, maxlength: 120, placeholder: 'Ex.: transferência n.º …' },
                ],
                submit: 'Registar pagamento',
                onSubmit: (v) => api(`/admin/comissoes/${b.dataset.payout}/pagar-motorista`, { method: 'POST', body: v }).then(() => go('comissoes')),
              })),
        );
        view.querySelectorAll('[data-pay]').forEach(
          (b) =>
            (b.onclick = () =>
              modal({
                title: `Pagamento de ${b.dataset.name}`,
                intro: `Deve ${kz(Number(b.dataset.due))}. Registe só o que já recebeu: o valor é abatido à dívida do motorista.`,
                fields: [
                  { name: 'amount', label: 'Valor recebido (Kz)', type: 'number', min: 1, max: b.dataset.due, value: b.dataset.due },
                  { name: 'note', label: 'Nota', required: false, maxlength: 120, placeholder: 'Ex.: dinheiro, transferência n.º …' },
                ],
                submit: 'Registar pagamento',
                onSubmit: (v) => api(`/admin/comissoes/${b.dataset.pay}/pagamento`, { method: 'POST', body: v }).then(() => go('comissoes')),
              })),
        );
      },
    },

    mensalidades: {
      label: 'Mensalidades',
      async render() {
        const m = await api('/admin/mensalidades');
        const STATE = { free: ['off', 'Gratuita'], trial: ['wait', 'Período grátis por começar'], active: ['ok', 'Em dia'], expired: ['bad', 'Em atraso'] };
        const expired = m.vehicles.filter((v) => v.state === 'expired').length;
        view.innerHTML =
          header('Mensalidades', 'Triciclos, XL, carrinhas e camiões combinam o preço com o cliente e não pagam comissão por serviço: pagam uma mensalidade por viatura.') +
          `<div class="cards">
            ${stat(kz(m.receivedThisMonth), 'recebido este mês', false, 'coins', 'green')}
            ${stat(m.vehicles.filter((v) => v.state === 'active').length, 'viaturas em dia', false, 'check', 'blue')}
            ${stat(expired, 'viaturas em atraso', expired > 0, 'clock', 'amber')}
          </div>
          <p class="muted">O valor por tipo de viatura altera-se em <a href="#definicoes">Definições</a>.</p>
          <h2>Viaturas de preço combinado</h2>` +
          table(
            ['Motorista', 'Viatura', 'Tipo', 'Estado', ''],
            m.vehicles.map(
              (v) => `<tr>
                <td><strong>${esc(v.driver)}</strong><br><span class="muted">${esc(v.phone ?? '')}</span></td>
                <td>${esc(v.label)}<br><span class="muted">${esc(v.plate)}</span></td>
                <td>${esc(v.categoryLabel)}<br><span class="muted">${v.fee ? `${kz(v.fee)} por mês` : 'sem mensalidade'}</span></td>
                <td>${badge(STATE[v.state] ?? ['off', v.state])}${v.paidUntil ? `<br><span class="muted">até ${esc(day(v.paidUntil))}</span>` : ''}</td>
                <td class="num">${
                  v.fee
                    ? ibtn('plus', 'Registar pagamento', `data-sub="${esc(v.driverId)}/${esc(v.vehicleId)}" data-fee="${esc(v.fee)}" data-name="${esc(v.driver)}" data-plate="${esc(v.plate)}"`, 'small primary')
                    : '<span class="muted">—</span>'
                }</td>
              </tr>`,
            ),
            'Ainda não há viaturas de preço combinado registadas.',
          ) +
          '<h2>Últimos pagamentos</h2>' +
          table(
            ['Data', 'Motorista', 'Matrícula', 'Meses', { label: 'Valor', num: true }, 'Válida até', 'Registado por'],
            m.payments.map(
              (p) => `<tr><td>${esc(when(p.createdAt))}</td><td>${esc(p.driver)}</td><td>${esc(p.plate)}</td><td>${esc(p.months)}</td><td class="num">${kz(p.amount)}</td><td>${esc(day(p.paidUntil))}</td><td>${esc(p.by)}${p.note ? `<br><span class="muted">${esc(p.note)}</span>` : ''}</td></tr>`,
            ),
            'Ainda não foi registado nenhum pagamento.',
          );
        view.querySelectorAll('[data-sub]').forEach(
          (b) =>
            (b.onclick = () => {
              const fee = Number(b.dataset.fee);
              modal({
                title: `Mensalidade · ${b.dataset.plate}`,
                intro: `Viatura de ${b.dataset.name}. Registe só o que já recebeu: a viatura fica activa pelos meses pagos.`,
                fields: [
                  { name: 'months', label: 'Meses pagos', type: 'select', value: 1, options: [1, 2, 3, 6, 12].map((n) => [n, `${n} ${n === 1 ? 'mês' : 'meses'} · ${kz(fee * n)}`]) },
                  { name: 'note', label: 'Nota', required: false, maxlength: 120, placeholder: 'Ex.: transferência n.º …' },
                ],
                submit: 'Registar pagamento',
                onSubmit: (v) => api(`/admin/mensalidades/${b.dataset.sub}/pagamento`, { method: 'POST', body: { months: Number(v.months), note: v.note } }).then(() => go('mensalidades')),
              });
            }),
        );
      },
    },

    suporte: {
      label: 'Suporte',
      async render(estado = 'open') {
        const data = await api(`/admin/suporte?estado=${estado}`);
        setCount('suporte', data.open);
        const tab = (key, label) =>
          `<button class="btn small${estado === key ? ' primary' : ''}" data-estado="${key}"${estado === key ? ' aria-pressed="true"' : ''}>${esc(label)}</button>`;
        view.innerHTML =
          header('Suporte', 'Pedidos de ajuda e reclamações enviados pelo app.', `<div class="inline-form">${tab('open', `Por responder (${data.open})`)}${tab('resolved', 'Respondidos')}</div>`) +
          (data.tickets.length
            ? data.tickets
                .map(
                  (t) => `<div class="panel">
              <p><strong>${esc(TICKET_CATEGORY[t.category] ?? t.category)}</strong> · ${esc(t.name)} (${t.role === 'driver' ? 'motorista' : 'passageiro'})${t.phone ? ` · <a href="tel:${esc(t.phone)}">${esc(t.phone)}</a>` : ''} <span class="muted">· ${esc(when(t.createdAt))}</span></p>
              <p>${esc(t.message)}</p>
              ${t.ride ? `<p class="muted">Corrida: ${esc(t.ride.from)} → ${esc(t.ride.to)} · ${kz(t.ride.fare)} · ${esc(when(t.ride.at))}</p>` : ''}
              ${
                t.status === 'open'
                  ? ibtn('reply', 'Responder', `data-reply="${esc(t.id)}" data-name="${esc(t.name)}"`, 'primary')
                  : `<p><span class="badge ok">Respondido</span> ${esc(t.repliedBy ?? '')}</p><p class="muted">${esc(t.reply ?? '')}</p>`
              }
            </div>`,
                )
                .join('')
            : `<div class="table-wrap"><div class="empty">${estado === 'open' ? 'Não há pedidos por responder.' : 'Ainda não há pedidos respondidos.'}</div></div>`);
        view.querySelectorAll('[data-estado]').forEach((b) => (b.onclick = () => sections.admin.suporte.render(b.dataset.estado).catch(showError)));
        view.querySelectorAll('[data-reply]').forEach(
          (b) =>
            (b.onclick = () =>
              modal({
                title: `Responder a ${b.dataset.name}`,
                intro: 'O utilizador vê a resposta no app, em "Ajuda e suporte", e o pedido fica fechado.',
                fields: [{ name: 'reply', label: 'Resposta', type: 'textarea', rows: 5, minlength: 2, maxlength: 1500 }],
                submit: 'Responder e fechar',
                onSubmit: (v) => api(`/admin/suporte/${b.dataset.reply}/resposta`, { method: 'POST', body: { reply: v.reply } }).then(() => sections.admin.suporte.render('open')),
              })),
        );
      },
    },

    avisos: {
      label: 'Avisos',
      async render() {
        const { notices } = await api('/admin/avisos');
        view.innerHTML =
          header(
            'Avisos',
            'Mensagens da equipa para passageiros e motoristas. Para avisar uma só pessoa, use "Avisar" na lista de Motoristas ou de Passageiros.',
            `<div class="row-actions">${ibtn('bell', 'Avisar todos os motoristas', 'data-all="motoristas"', 'primary')}${ibtn('bell', 'Avisar todos os passageiros', 'data-all="passageiros"')}</div>`,
          ) +
          table(
            ['Data', 'Para', 'Aviso', 'Lido', 'Enviado por'],
            notices.map(
              (n) => `<tr>
                <td>${esc(when(n.createdAt))}</td>
                <td><strong>${esc(n.to)}</strong><br><span class="muted">${n.role === 'driver' ? 'Motorista' : 'Passageiro'}${n.sent > 1 ? ` · ${esc(n.sent)} contas` : ''}</span></td>
                <td><strong>${esc(n.title)}</strong><br><span class="muted">${esc(n.message)}</span></td>
                <td>${n.sent > 1 ? `${esc(n.read)} de ${esc(n.sent)}` : badge(n.read ? ['ok', 'Lido'] : ['wait', 'Por ler'])}</td>
                <td>${esc(n.sentBy)}</td>
              </tr>`,
            ),
            'Ainda não foi enviado nenhum aviso.',
          );
        view.querySelectorAll('[data-all]').forEach((b) => (b.onclick = () => noticeModal({ kind: b.dataset.all }, () => go('avisos'))));
      },
    },

    locais: {
      label: 'Locais',
      async render() {
        await renderLocais();
      },
    },
    intermunicipal: {
      label: 'Intermunicipal',
      async render() {
        const d = await api('/admin/intermunicipal');
        const STATE = { open: ['wait', 'Aberta'], departed: ['trip', 'Em viagem'], completed: ['ok', 'Concluída'], cancelled: ['bad', 'Cancelada'] };
        const again = () => sections.admin.intermunicipal.render();
        const routeFields = (r = {}) => [
          { name: 'price', label: 'Preço por passageiro (Kz)', type: 'number', min: 100, step: 50, value: r.price, half: true },
          { name: 'maxPrice', label: 'Preço máximo (Kz)', type: 'number', min: 0, step: 50, value: r.maxPrice ?? '', required: false, half: true, hint: 'Vazio: preço fixo. Preenchido: o motorista pode pedir entre metade do preço e este máximo.' },
          { name: 'distanceKm', label: 'Distância (km)', type: 'number', min: 0, value: r.distanceKm ?? '', required: false, half: true },
        ];
        view.innerHTML =
          header(
            'Táxi intermunicipal',
            'Rotas entre municípios e preço por passageiro. Os motoristas publicam viagens nestas rotas e os passageiros reservam lugares no app.',
            ibtn('plus', 'Nova rota', 'id="new-route"', 'primary'),
          ) +
          `<div class="cards">
            ${stat(d.routes.filter((r) => r.active).length, 'rotas activas', false, 'bus', 'blue')}
            ${stat(d.trips.filter((t) => t.status === 'open').length, 'viagens abertas', false, 'calendar', 'green')}
            ${stat(percentText(d.commissionRate), 'comissão por passageiro', false, 'percent', 'yellow')}
          </div>
          <h2>Rotas</h2>` +
          table(
            ['Rota', { label: 'Preço por passageiro', num: true }, { label: 'Preço máximo', num: true }, { label: 'Distância', num: true }, 'Estado', ''],
            d.routes.map(
              (r, i) => `<tr>
                <td><strong>${esc(r.from)} ⇄ ${esc(r.to)}</strong></td>
                <td class="num">${kz(r.price)}</td>
                <td class="num">${r.maxPrice ? kz(r.maxPrice) : '<span class="muted">fixo</span>'}</td>
                <td class="num">${r.distanceKm ? `${esc(r.distanceKm)} km` : '—'}</td>
                <td>${badge(r.active ? ['ok', 'Activa'] : ['off', 'Desactivada'])}</td>
                <td><div class="row-actions">
                  ${ibtn('edit', 'Editar', `data-route-edit="${i}"`, 'small')}
                  <button class="btn small" data-route-toggle="${i}">${r.active ? 'Desactivar' : 'Activar'}</button>
                  ${ibtn('trash', 'Apagar', `data-route-del="${i}"`, 'small danger')}
                </div></td>
              </tr>`,
            ),
            'Ainda não há rotas. Crie a primeira em "Nova rota".',
          ) +
          `<p class="muted">A comissão das viagens intermunicipais altera-se em <a href="#definicoes">Definições</a>.</p>
          <h2>Viagens publicadas</h2>` +
          table(
            ['Partida', 'Viagem', 'Motorista', 'Lugares', { label: 'Preço', num: true }, 'Estado', { label: 'Comissão', num: true }],
            d.trips.map(
              (t) => `<tr>
                <td>${esc(when(t.departAt))}</td>
                <td><strong>${esc(t.from)} → ${esc(t.to)}</strong></td>
                <td>${esc(t.driver)}<br><span class="muted">${esc(t.phone ?? '')} · ${esc(t.vehicle)}</span></td>
                <td>${esc(t.seatsTaken)} de ${esc(t.seats)} confirmados${t.pending ? `<br><span class="muted">${esc(t.pending)} por confirmar</span>` : ''}</td>
                <td class="num">${kz(t.price)}</td>
                <td>${badge(STATE[t.status])}</td>
                <td class="num">${t.commission ? kz(t.commission) : '—'}</td>
              </tr>`,
            ),
            'Ainda não foi publicada nenhuma viagem.',
          );
        $('#new-route').onclick = () =>
          modal({
            title: 'Nova rota',
            intro: 'Cada rota serve nos dois sentidos. O preço é por passageiro.',
            fields: [
              { name: 'from', label: 'De', maxlength: 60, minlength: 2, placeholder: 'Ex.: Mbanza Kongo', half: true },
              { name: 'to', label: 'Para', maxlength: 60, minlength: 2, placeholder: 'Ex.: Soyo', half: true },
              ...routeFields(),
            ],
            submit: 'Criar rota',
            onSubmit: (v) => api('/admin/intermunicipal/rotas', { method: 'POST', body: v }).then(again),
          });
        const save = (r, changes) =>
          api(`/admin/intermunicipal/rotas/${r.id}`, { method: 'POST', body: { price: r.price, maxPrice: r.maxPrice ?? '', distanceKm: r.distanceKm ?? '', active: r.active, ...changes } }).then(again);
        view.querySelectorAll('[data-route-edit]').forEach((b) => {
          const r = d.routes[b.dataset.routeEdit];
          b.onclick = () => modal({ title: `${r.from} ⇄ ${r.to}`, intro: 'As viagens já publicadas mantêm o preço que tinham.', fields: routeFields(r), onSubmit: (v) => save(r, v) });
        });
        view.querySelectorAll('[data-route-toggle]').forEach((b) => {
          const r = d.routes[b.dataset.routeToggle];
          b.onclick = () => act(b, () => save(r, { active: !r.active }));
        });
        view.querySelectorAll('[data-route-del]').forEach((b) => {
          const r = d.routes[b.dataset.routeDel];
          b.onclick = () => {
            if (confirm(`Apagar a rota ${r.from} ⇄ ${r.to}?`)) act(b, () => api(`/admin/intermunicipal/rotas/${r.id}`, { method: 'DELETE' }).then(again));
          };
        });
      },
    },

    // Tudo o que se configura fica aqui: percentagens, mensalidades e a forma de entrar no app.
    definicoes: {
      label: 'Definições',
      async render() {
        const [c, m, i, a] = await Promise.all([api('/admin/comissoes'), api('/admin/mensalidades'), api('/admin/intermunicipal'), api('/admin/acesso')]);
        const again = () => sections.admin.definicoes.render();
        const without = a.passengers.total - a.passengers.withPassword + (a.drivers.total - a.drivers.withPassword);
        const setting = (ic, tone, title, value, text, button) =>
          `<div class="setting"><span class="card-ic ${tone}">${icon(ic, 22)}</span><div class="body"><h3>${esc(title)}</h3><div class="value">${value}</div><p class="muted">${text}</p></div>${button}</div>`;
        view.innerHTML =
          header('Definições', 'O que se pode ajustar sem mexer no servidor. Cada alteração fica em vigor de imediato.') +
          `<h2>Quanto o Bazá cobra</h2>
          <div class="settings">
            ${setting('percent', 'yellow', 'Comissão das corridas', esc(percentText(c.rate)), 'Moto, Económico e Conforto. Aplica-se às corridas pedidas a partir da alteração.', ibtn('edit', 'Alterar', 'id="set-rate"'))}
            ${setting('bus', 'blue', 'Comissão intermunicipal', esc(percentText(i.commissionRate)), 'Sobre os lugares confirmados no app, quando o motorista conclui a viagem. Com 0, não há comissão.', ibtn('edit', 'Alterar', 'id="set-inter"'))}
          </div>
          <div class="panel">
            <div class="panel-head"><div><h2>Mensalidade por tipo de viatura</h2><p class="muted">Viaturas de preço combinado pagam por mês, por viatura registada. Com 0, o tipo é gratuito. Uma viatura nova tem ${esc(m.trialDays)} dias grátis a contar da primeira vez que fica online.</p></div>${ibtn('edit', 'Alterar valores', 'id="set-fees"')}</div>
            <div class="fees">${m.fees.map((f) => `<div><span class="muted">${esc(f.label)}</span><b>${f.fee ? kz(f.fee) : 'Gratuita'}</b></div>`).join('')}</div>
          </div>
          <h2>Entrada no app</h2>
          <div class="settings">
            ${setting(
              'sms',
              a.otp ? 'green' : 'amber',
              'Código por SMS para entrar',
              badge(a.otp ? ['ok', 'Ligado'] : ['wait', 'Desligado']),
              a.otp
                ? 'O app pede o código SMS para entrar. A senha só é pedida se o SMS falhar, se o código não chegar ou se o utilizador não tiver o telefone consigo.'
                : 'O app pede a senha a quem já tem conta, sem enviar SMS. Criar conta continua a exigir o código, para confirmar o número.',
              `<button type="button" class="btn${a.otp ? ' danger' : ' primary'}" id="otp-toggle">${a.otp ? 'Desligar' : 'Voltar a ligar'}</button>`,
            )}
            ${setting('key', 'blue', 'Contas com senha', `${esc(a.passengers.withPassword + a.drivers.withPassword)} de ${esc(a.passengers.total + a.drivers.total)}`, `${esc(a.passengers.withPassword)} de ${esc(a.passengers.total)} passageiros e ${esc(a.drivers.withPassword)} de ${esc(a.drivers.total)} motoristas.${without > 0 ? ' As restantes criam a senha na próxima vez que abrirem o app.' : ''} Para repor uma senha esquecida, use "Repor senha" em Motoristas ou Passageiros.${a.passengers.unverified + a.drivers.unverified > 0 ? ` ${esc(a.passengers.unverified + a.drivers.unverified)} com o número por confirmar (criadas quando o SMS falhou): o app pede o código quando o SMS voltar a funcionar.` : ''}`, '')}
          </div>`;
        const rateModal = (title, intro, value, path) =>
          modal({
            title,
            intro,
            fields: [{ name: 'percent', label: 'Percentagem (%)', type: 'number', min: 0, max: 50, step: 0.5, value: Math.round(value * 1000) / 10 }],
            onSubmit: (v) => api(path, { method: 'POST', body: v }).then(again),
          });
        $('#set-rate').onclick = () => rateModal('Comissão das corridas', 'As corridas já pedidas mantêm a percentagem que tinham.', c.rate, '/admin/comissoes/percentagem');
        $('#set-inter').onclick = () => rateModal('Comissão intermunicipal', 'Vale para as viagens concluídas a partir de agora.', i.commissionRate, '/admin/intermunicipal/comissao');
        $('#set-fees').onclick = () =>
          modal({
            title: 'Mensalidade por tipo de viatura',
            intro: 'Valor em kwanzas por mês. Com 0, esse tipo fica gratuito.',
            fields: m.fees.map((f) => ({ name: f.category, label: f.label, type: 'number', min: 0, step: 100, value: f.fee, half: true })),
            onSubmit: (v) => api('/admin/mensalidades/taxas', { method: 'POST', body: { fees: v } }).then(again),
          });
        const toggle = $('#otp-toggle');
        toggle.onclick = () => {
          if (a.otp && !confirm('Desligar o código por SMS para entrar? Quem já tem conta passa a entrar só com o número e a senha. Criar conta continua a pedir o código.')) return;
          act(toggle, () => api('/admin/acesso', { method: 'POST', body: { otp: !a.otp } }).then(again));
        };
      },
    },

    administradores: {
      label: 'Administradores',
      async render() {
        const { admins } = await api('/admin/administradores');
        view.innerHTML =
          header(
            'Administradores',
            'Quem pode entrar neste painel e gerir a plataforma.',
            `<div class="row-actions">${ibtn('key', 'Alterar a minha palavra-passe', 'id="my-password"')}${ibtn('plus', 'Novo administrador', 'id="add-admin"', 'primary')}</div>`,
          ) +
          table(
            ['Nome', 'Email', 'Desde', ''],
            admins.map(
              (a) => `<tr>
                <td><strong>${esc(a.name)}</strong>${a.you ? ' <span class="badge ok">Você</span>' : ''}${a.defaultPassword ? ' <span class="badge wait">Palavra-passe por defeito</span>' : ''}</td>
                <td>${esc(a.email)}</td>
                <td>${esc(day(a.createdAt))}</td>
                <td class="num">${a.you ? '' : ibtn('trash', 'Remover', `data-remove-admin="${esc(a.id)}" data-name="${esc(a.name)}"`, 'small danger')}</td>
              </tr>`,
            ),
            'Sem administradores.',
          );
        $('#my-password').onclick = () =>
          modal({
            title: 'Alterar a minha palavra-passe',
            fields: [
              { name: 'current', label: 'Palavra-passe actual', type: 'password', autocomplete: 'current-password' },
              { name: 'next', label: 'Nova palavra-passe', type: 'password', minlength: 8, autocomplete: 'new-password', hint: 'Pelo menos 8 caracteres.' },
              { ...CONFIRM_FIELD, label: 'Repita a nova palavra-passe' },
            ],
            onSubmit: async (v) => {
              checkConfirm(v.next, v.confirm);
              await api('/admin/palavra-passe', { method: 'POST', body: { current: v.current, next: v.next } });
              // Já não usa a palavra-passe por defeito: o aviso desaparece.
              session.mustChangePassword = false;
              sessionStorage.setItem('baza-painel', JSON.stringify(session));
              await go('administradores');
              const ok = document.createElement('p');
              ok.className = 'notice';
              ok.setAttribute('role', 'status');
              ok.textContent = 'Palavra-passe alterada.';
              view.prepend(ok);
            },
          });
        $('#add-admin').onclick = () =>
          modal({
            title: 'Novo administrador',
            intro: 'Esta pessoa passa a poder gerir toda a plataforma.',
            fields: [
              { name: 'name', label: 'Nome', minlength: 2, maxlength: 80 },
              { name: 'email', label: 'Email', type: 'email' },
              { name: 'password', label: 'Palavra-passe', type: 'password', minlength: 8, autocomplete: 'new-password', hint: 'Pelo menos 8 caracteres.' },
              CONFIRM_FIELD,
            ],
            submit: 'Adicionar',
            onSubmit: async (v) => {
              checkConfirm(v.password, v.confirm);
              await api('/admin/administradores', { method: 'POST', body: { name: v.name, email: v.email, password: v.password } });
              await go('administradores');
            },
          });
        view.querySelectorAll('[data-remove-admin]').forEach(
          (b) =>
            (b.onclick = () => {
              if (!confirm(`Remover o administrador ${b.dataset.name}? Deixa de poder entrar no painel.`)) return;
              act(b, () => api(`/admin/administradores/${b.dataset.removeAdmin}`, { method: 'DELETE' }).then(() => go('administradores')));
            }),
        );
      },
    },
  },

  // ─────────── Frota ───────────
  fleet: {
    resumo: {
      label: 'Resumo',
      refresh: 20000,
      async render() {
        const s = await api('/frota/resumo');
        view.innerHTML =
          hero(s.fleet.name, `NIF ${s.fleet.nif} · ${s.fleet.email}`) +
          `<div class="cards">
            ${stat(`${s.online} de ${s.drivers}`, 'motoristas online', false, 'wheel', 'green')}
            ${stat(s.onTrip, 'em viagem agora', false, 'car', 'yellow')}
            ${stat(s.pending, 'com documentos por concluir', s.pending > 0, 'file', 'amber')}
          </div>
          <h2>Hoje</h2>
          <div class="cards">${stat(s.today.rides, 'corridas concluídas')}${stat(kz(s.today.revenue), 'facturado pelos motoristas')}</div>
          <h2>Últimos 7 dias</h2>
          <div class="cards">${stat(s.week.rides, 'corridas concluídas')}${stat(kz(s.week.revenue), 'facturado pelos motoristas')}</div>
          <div class="panel">
            <div class="panel-head"><div><h2>Dados da empresa</h2><p class="muted">${esc(s.fleet.name)} · NIF ${esc(s.fleet.nif)} · ${esc(s.fleet.phone)} · ${esc(s.fleet.email)}</p></div>${session.userRole === 'manager' ? ibtn('edit', 'Alterar', 'id="edit-company"') : ''}</div>
          </div>
          <div class="panel">
            <h2>Código da frota</h2>
            <p class="muted">Um motorista que já tenha conta no Bazá junta-se à sua frota introduzindo este código no app, em “Frota”.</p>
            <span class="code">${esc(s.fleet.joinCode)}</span>
          </div>`;
        const edit = $('#edit-company');
        if (edit) {
          edit.onclick = () =>
            modal({
              title: 'Dados da empresa',
              fields: [
                { name: 'name', label: 'Nome da empresa', value: s.fleet.name, minlength: 2, maxlength: 80 },
                { name: 'phone', label: 'Telefone', type: 'tel', value: s.fleet.phone },
              ],
              onSubmit: async (v) => {
                await api('/frota/empresa', { method: 'POST', body: v });
                session.institution = v.name;
                sessionStorage.setItem('baza-painel', JSON.stringify(session));
                start();
              },
            });
        }
      },
    },

    motoristas: {
      label: 'Motoristas',
      async render() {
        const { drivers } = await api('/frota/motoristas');
        view.innerHTML =
          header('Motoristas da frota', `${drivers.length} registados`, `<div class="row-actions">${ibtn('bell', 'Avisar todos', 'id="notify-all"')}${ibtn('plus', 'Registar motorista', 'id="add-driver"', 'primary')}</div>`) +
          table(
            ['Motorista', 'Viatura', 'Documentos', 'Estado', { label: 'Hoje', num: true }, ''],
            drivers.map(
              (d) => `<tr>
                <td>${person(d, `${esc(d.phone ?? '')}${d.rating ? ` · ★ ${esc(d.rating)}` : ''}`)}</td>
                <td>${d.vehicle ? `${esc(d.vehicle.category)} · ${esc(d.vehicle.label)}<br><span class="muted">${esc(d.vehicle.color)} · ${esc(d.vehicle.plate)}</span>` : '<span class="muted">Por registar</span>'}</td>
                <td>${badge(VERIFICATION[d.verification])}</td>
                <td>${driverState(d)}</td>
                <td class="num">${esc(d.ridesToday)} corridas<br><span class="muted">${kz(d.revenueToday)}</span></td>
                <td><div class="row-actions">${ibtn('file', 'Ver ficha', `data-ficha="${esc(d.id)}"`, 'small')}${ibtn('bell', 'Avisar', `data-notice="${esc(d.id)}" data-kind="motoristas" data-name="${esc(d.name)}"`, 'small')}<button class="btn small danger" data-remove="${esc(d.id)}" data-name="${esc(d.name)}">Retirar</button></div></td>
              </tr>`,
            ),
            'Ainda não tem motoristas. Registe o primeiro em "Registar motorista".',
          );
        bindPhotos();
        bindNotices();
        $('#notify-all').onclick = () => noticeModal({ kind: 'motoristas' });
        view.querySelectorAll('[data-ficha]').forEach((b) => (b.onclick = () => act(b, () => driverFile(b.dataset.ficha, null, { base: '/frota', readOnly: true }).finally(() => (b.disabled = false)))));
        $('#add-driver').onclick = () =>
          modal({
            title: 'Registar motorista',
            intro: 'O motorista entra no app com este número, como "Motorista", e envia a carta de condução e os documentos da viatura.',
            fields: [
              { name: 'name', label: 'Nome', minlength: 2, maxlength: 80 },
              { name: 'phone', label: 'Telefone', type: 'tel', placeholder: '923 456 789' },
            ],
            submit: 'Registar',
            onSubmit: (v) => api('/frota/motoristas', { method: 'POST', body: v }).then(() => go('motoristas')),
          });
        view.querySelectorAll('[data-remove]').forEach(
          (b) =>
            (b.onclick = () => {
              if (!confirm(`Retirar ${b.dataset.name} da frota? A conta do motorista continua a existir.`)) return;
              act(b, () => api(`/frota/motoristas/${b.dataset.remove}`, { method: 'DELETE' }).then(() => go('motoristas')));
            }),
        );
      },
    },

    mapa: { label: 'Mapa ao vivo', render: () => renderMap('/frota/motoristas') },
    corridas: { label: 'Corridas', refresh: 20000, render: () => renderRides('/frota/corridas', false) },

    sos: {
      label: 'Alertas SOS',
      refresh: 15000,
      async render() {
        const { alerts } = await api('/frota/sos');
        view.innerHTML = header('Alertas SOS', 'Alertas de perigo accionados em corridas dos motoristas da frota.') + sosTable(alerts);
      },
    },

    contas: {
      label: 'Contas',
      async render(dias = 30) {
        const c = await api(`/frota/contas?dias=${dias}`);
        const tab = (n, label) => `<button class="btn small${dias === n ? ' primary' : ''}" data-dias="${n}"${dias === n ? ' aria-pressed="true"' : ''}>${esc(label)}</button>`;
        view.innerHTML =
          header(
            'Contas da frota',
            `O que cada motorista fez desde ${day(c.since)}, e o que deve ao Bazá.`,
            `<div class="row-actions">${tab(1, 'Hoje')}${tab(7, '7 dias')}${tab(30, '30 dias')}${tab(90, '90 dias')}${ibtn('file', 'Exportar', 'id="export"')}</div>`,
          ) +
          `<div class="cards">
            ${stat(c.totals.rides, 'corridas concluídas', false, 'car', 'blue')}
            ${stat(kz(c.totals.revenue), 'facturado pelos motoristas', false, 'trend', 'green')}
            ${stat(kz(c.totals.commission), 'comissão do Bazá no período', false, 'percent', 'yellow')}
            ${stat(kz(c.totals.commissionDue), 'comissões por pagar ao Bazá', c.totals.commissionDue > 0, 'coins', 'amber')}
          </div>` +
          table(
            ['Motorista', 'Viatura', { label: 'Corridas', num: true }, { label: 'Facturado', num: true }, { label: 'Comissão', num: true }, { label: 'Líquido', num: true }, { label: 'Deve ao Bazá', num: true }],
            c.drivers.map(
              (d) => `<tr>
                <td><strong>${esc(d.name)}</strong><br><span class="muted">${esc(d.phone ?? '')}</span></td>
                <td>${esc(d.plate ?? '—')}</td>
                <td class="num">${esc(d.rides)}</td>
                <td class="num">${kz(d.revenue)}</td>
                <td class="num">${kz(d.commission)}</td>
                <td class="num"><strong>${kz(d.revenue - d.commission)}</strong></td>
                <td class="num">${d.commissionDue ? kz(d.commissionDue) : '—'}</td>
              </tr>`,
            ),
            'A frota ainda não tem motoristas.',
          );
        view.querySelectorAll('[data-dias]').forEach((b) => (b.onclick = () => sections.fleet.contas.render(Number(b.dataset.dias)).catch(showError)));
        // Ficheiro CSV, que o Excel abre directamente.
        $('#export').onclick = () => {
          const rows = [['Motorista', 'Telefone', 'Matrícula', 'Corridas', 'Facturado (Kz)', 'Comissão (Kz)', 'Líquido (Kz)', 'Deve ao Bazá (Kz)'], ...c.drivers.map((d) => [d.name, d.phone ?? '', d.plate ?? '', d.rides, d.revenue, d.commission, d.revenue - d.commission, d.commissionDue])];
          const csv = '\ufeff' + rows.map((r) => r.map((v) => `"${String(v).replace(/"/g, '""')}"`).join(';')).join('\r\n');
          const a = document.createElement('a');
          a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
          a.download = `contas-frota-${dias}-dias.csv`;
          a.click();
          URL.revokeObjectURL(a.href);
        };
      },
    },

    acertos: {
      label: 'Acertos',
      async render() {
        const d = await api('/frota/acertos');
        const rule = (t) => (!t ? '<span class="muted">Sem regra</span>' : t.mode === 'percent' ? `${esc(String(t.value).replace('.', ','))} % do facturado` : `${kz(t.value)} por dia trabalhado`);
        view.innerHTML =
          header('Acerto de contas', 'O que cada motorista tem de entregar à frota, pela regra combinada com ele, e o que já entregou.') +
          `<div class="cards">
            ${stat(kz(d.totals.owed), 'a entregar, no total', false, 'coins', 'blue')}
            ${stat(kz(d.totals.delivered), 'já entregue', false, 'check', 'green')}
            ${stat(kz(d.totals.balance), 'por entregar', d.totals.balance > 0, 'wallet', 'amber')}
          </div>` +
          table(
            ['Motorista', 'Regra', { label: 'Facturou', num: true }, { label: 'A entregar', num: true }, { label: 'Entregou', num: true }, { label: 'Saldo', num: true }, ''],
            d.drivers.map(
              (r, i) => `<tr>
                <td>${person(r, esc(r.phone ?? ''))}</td>
                <td>${rule(r.term)}${r.term ? `<br><span class="muted small">desde ${esc(day(r.term.startAt))}${r.term.mode === 'daily' ? ` · ${esc(r.days)} ${r.days === 1 ? 'dia' : 'dias'}` : ''}</span>` : ''}</td>
                <td class="num">${kz(r.revenue)}</td>
                <td class="num">${kz(r.owed)}</td>
                <td class="num">${kz(r.delivered)}${r.lastHandover ? `<br><span class="muted small">${esc(day(r.lastHandover))}</span>` : ''}</td>
                <td class="num"><strong>${r.balance > 0 ? kz(r.balance) : r.balance < 0 ? `${kz(-r.balance)} a favor` : 'Em dia'}</strong></td>
                <td><div class="row-actions">${ibtn('edit', 'Regra', `data-term="${i}"`, 'small')}${r.term ? ibtn('plus', 'Entrega', `data-handover="${i}"`, 'small primary') : ''}</div></td>
              </tr>`,
            ),
            'A frota ainda não tem motoristas.',
          ) +
          '<h2>Últimas entregas</h2>' +
          table(
            ['Data', 'Motorista', { label: 'Valor', num: true }, 'Nota', 'Registado por'],
            d.handovers.map((h) => `<tr><td>${esc(when(h.createdAt))}</td><td>${esc(h.driver)}</td><td class="num">${kz(h.amount)}</td><td>${esc(h.note || '—')}</td><td>${esc(h.by)}</td></tr>`),
            'Ainda não foi registada nenhuma entrega.',
          );
        bindPhotos();
        const again = () => go('acertos');
        view.querySelectorAll('[data-term]').forEach((b) => {
          const r = d.drivers[b.dataset.term];
          b.onclick = () =>
            modal({
              title: `Regra de ${r.name}`,
              intro: 'Ao guardar, a contagem recomeça a partir de hoje: o que estava para trás deixa de contar.',
              fields: [
                { name: 'mode', label: 'Como se calcula', type: 'select', value: r.term?.mode ?? 'percent', options: [['percent', 'Percentagem do que facturou'], ['daily', 'Valor fixo por dia trabalhado (conta diária)']] },
                { name: 'value', label: 'Percentagem (%) ou valor por dia (Kz)', type: 'number', min: 0, step: 0.5, value: r.term?.value ?? '' },
              ],
              onSubmit: (v) => api(`/frota/acertos/${r.id}`, { method: 'POST', body: v }).then(again),
            });
        });
        view.querySelectorAll('[data-handover]').forEach((b) => {
          const r = d.drivers[b.dataset.handover];
          b.onclick = () =>
            modal({
              title: `Entrega de ${r.name}`,
              intro: r.balance > 0 ? `Tem ${kz(r.balance)} por entregar.` : 'Está em dia.',
              fields: [
                { name: 'amount', label: 'Valor recebido (Kz)', type: 'number', min: 1, value: r.balance > 0 ? r.balance : '' },
                { name: 'note', label: 'Nota', required: false, maxlength: 120, placeholder: 'Ex.: em mão, transferência' },
              ],
              submit: 'Registar entrega',
              onSubmit: (v) => api(`/frota/acertos/${r.id}/entrega`, { method: 'POST', body: v }).then(again),
            });
        });
      },
    },

    viaturas: {
      label: 'Viaturas',
      async render() {
        const d = await api('/frota/viaturas');
        const KIND = { fuel: 'Combustível', workshop: 'Oficina', fine: 'Multa', insurance: 'Seguro', other: 'Outra' };
        const soon = Date.now() + 15 * 24 * 3600_000;
        // Vencido, a vencer em 15 dias, ou em dia.
        const due = (label, iso) => {
          if (!iso) return '';
          const t = new Date(iso).getTime();
          const cls = t < Date.now() ? 'bad' : t < soon ? 'wait' : 'ok';
          return `<span class="badge ${cls}" title="${t < Date.now() ? 'Já passou' : t < soon ? 'Nos próximos 15 dias' : 'Em dia'}">${esc(label)} ${esc(day(iso))}</span> `;
        };
        const late = d.vehicles.filter((v) => [v.insuranceDue, v.inspectionDue, v.serviceDue].some((x) => x && new Date(x).getTime() < soon)).length;
        const today = new Date().toISOString().slice(0, 10);
        const dateValue = (iso) => (iso ? new Date(iso).toISOString().slice(0, 10) : '');
        const fields = (v = {}) => [
          { name: 'plate', label: 'Matrícula', value: v.plate, minlength: 3, maxlength: 15, half: true },
          { name: 'label', label: 'Marca, modelo e cor', value: v.label, minlength: 2, maxlength: 60, half: true },
          { name: 'driver', label: 'Entregue a', type: 'select', value: v.driverId ?? '', required: false, options: [['', 'Ninguém'], ...d.drivers.map((x) => [x.id, x.name])] },
          { name: 'insuranceDue', label: 'Seguro válido até', type: 'date', value: dateValue(v.insuranceDue), required: false, half: true },
          { name: 'inspectionDue', label: 'Inspecção até', type: 'date', value: dateValue(v.inspectionDue), required: false, half: true },
          { name: 'serviceDue', label: 'Próxima revisão', type: 'date', value: dateValue(v.serviceDue), required: false, half: true },
          { name: 'notes', label: 'Notas', value: v.notes, required: false, maxlength: 300 },
        ];
        view.innerHTML =
          header('Viaturas da frota', 'A quem está entregue cada viatura, as datas a não deixar passar e quanto custa manter cada uma.', ibtn('plus', 'Nova viatura', 'id="new-vehicle"', 'primary')) +
          `<div class="cards">
            ${stat(d.vehicles.length, 'viaturas registadas', false, 'key', 'blue')}
            ${stat(late, 'com datas vencidas ou a vencer', late > 0, 'clock', 'amber')}
            ${stat(kz(d.spentMonth), 'despesas este mês', false, 'coins', 'yellow')}
          </div>` +
          table(
            ['Viatura', 'Entregue a', 'Datas', { label: 'Gasto este mês', num: true }, { label: 'Gasto total', num: true }, ''],
            d.vehicles.map(
              (v, i) => `<tr>
                <td><strong>${esc(v.plate)}</strong><br><span class="muted">${esc(v.label)}</span></td>
                <td>${v.driver ? esc(v.driver) : '<span class="muted">Ninguém</span>'}</td>
                <td>${due('Seguro', v.insuranceDue)}${due('Inspecção', v.inspectionDue)}${due('Revisão', v.serviceDue) || (v.insuranceDue || v.inspectionDue ? '' : '<span class="muted">Sem datas</span>')}${v.notes ? `<br><span class="muted small">${esc(v.notes)}</span>` : ''}</td>
                <td class="num">${kz(v.spentMonth)}</td>
                <td class="num">${kz(v.spentTotal)}</td>
                <td><div class="row-actions">${ibtn('plus', 'Despesa', `data-expense="${i}"`, 'small primary')}${ibtn('edit', 'Editar', `data-vehicle="${i}"`, 'small')}${ibtn('trash', 'Apagar', `data-vehicle-del="${i}"`, 'small danger')}</div></td>
              </tr>`,
            ),
            'Ainda não registou viaturas. Comece em "Nova viatura".',
          ) +
          '<h2>Últimas despesas</h2>' +
          table(
            ['Data', 'Viatura', 'Tipo', { label: 'Valor', num: true }, 'Nota', ''],
            d.expenses.map(
              (e) => `<tr><td>${esc(day(e.date))}</td><td>${esc(e.plate)}</td><td>${esc(KIND[e.kind] ?? e.kind)}</td><td class="num">${kz(e.amount)}</td><td>${esc(e.note || '—')}<br><span class="muted small">${esc(e.by)}</span></td><td class="num">${ibtn('trash', 'Apagar', `data-expense-del="${esc(e.id)}"`, 'small danger')}</td></tr>`,
            ),
            'Ainda não registou despesas.',
          );
        const again = () => go('viaturas');
        $('#new-vehicle').onclick = () => modal({ title: 'Nova viatura', fields: fields(), submit: 'Registar', onSubmit: (v) => api('/frota/viaturas', { method: 'POST', body: v }).then(again) });
        view.querySelectorAll('[data-vehicle]').forEach((b) => {
          const v = d.vehicles[b.dataset.vehicle];
          b.onclick = () => modal({ title: v.plate, fields: fields(v), onSubmit: (x) => api(`/frota/viaturas/${v.id}`, { method: 'POST', body: x }).then(again) });
        });
        view.querySelectorAll('[data-vehicle-del]').forEach((b) => {
          const v = d.vehicles[b.dataset.vehicleDel];
          b.onclick = () => {
            if (confirm(`Apagar a viatura ${v.plate} e as suas despesas?`)) act(b, () => api(`/frota/viaturas/${v.id}`, { method: 'DELETE' }).then(again));
          };
        });
        view.querySelectorAll('[data-expense]').forEach((b) => {
          const v = d.vehicles[b.dataset.expense];
          b.onclick = () =>
            modal({
              title: `Despesa · ${v.plate}`,
              fields: [
                { name: 'kind', label: 'Tipo', type: 'select', value: 'fuel', options: Object.entries(KIND), half: true },
                { name: 'date', label: 'Data', type: 'date', value: today, half: true },
                { name: 'amount', label: 'Valor (Kz)', type: 'number', min: 1 },
                { name: 'note', label: 'Nota', required: false, maxlength: 120, placeholder: 'Ex.: 40 litros de gasóleo' },
              ],
              submit: 'Registar despesa',
              onSubmit: (x) => api(`/frota/viaturas/${v.id}/despesas`, { method: 'POST', body: x }).then(again),
            });
        });
        view.querySelectorAll('[data-expense-del]').forEach(
          (b) =>
            (b.onclick = () => {
              if (confirm('Apagar esta despesa?')) act(b, () => api(`/frota/despesas/${b.dataset.expenseDel}`, { method: 'DELETE' }).then(again));
            }),
        );
      },
    },

    turnos: {
      label: 'Turnos',
      refresh: 60000,
      async render() {
        const d = await api('/frota/turnos');
        const DAYS = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];
        view.innerHTML =
          header('Turnos', 'O horário semanal de cada motorista, e quem devia estar a trabalhar agora e não está online.') +
          `<div class="cards">
            ${stat(d.expected, 'de turno agora', false, 'clock', 'blue')}
            ${stat(d.expected - d.missing, 'de turno e online', false, 'check', 'green')}
            ${stat(d.missing, 'de turno, mas offline', d.missing > 0, 'alert', 'amber')}
          </div>` +
          table(
            ['Motorista', 'Dias', 'Horário', 'Agora', ''],
            d.drivers.map(
              (r, i) => `<tr class="${r.missing ? 'row-danger' : ''}">
                <td>${person(r, esc(r.phone ?? ''))}</td>
                <td>${r.shift ? DAYS.map((n, k) => `<span class="badge ${r.shift.days.includes(k) ? 'trip' : 'off'}">${n}</span>`).join(' ') : '<span class="muted">Sem turno definido</span>'}</td>
                <td>${r.shift ? `${esc(r.shift.start)} – ${esc(r.shift.end)}` : '—'}</td>
                <td>${r.missing ? badge(['bad', 'Em falta']) : r.expected ? badge(['ok', 'De turno e online']) : badge(r.online ? ['ok', 'Online'] : ['off', 'Fora do turno'])}</td>
                <td class="num">${ibtn('edit', r.shift ? 'Alterar' : 'Definir turno', `data-shift="${i}"`, 'small')}</td>
              </tr>`,
            ),
            'A frota ainda não tem motoristas.',
          );
        bindPhotos();
        view.querySelectorAll('[data-shift]').forEach((b) => {
          const r = d.drivers[b.dataset.shift];
          b.onclick = () =>
            modal({
              title: `Turno de ${r.name}`,
              intro: 'Marque os dias de trabalho. Um turno pode passar da meia-noite (ex.: 18:00 às 06:00). Sem dias marcados, o turno é retirado.',
              html: `<div class="days">${DAYS.map((n, k) => `<label class="day"><input type="checkbox" name="d${k}"${r.shift?.days.includes(k) ? ' checked' : ''}><span>${n}</span></label>`).join('')}</div>`,
              fields: [
                { name: 'start', label: 'Início', type: 'time', value: r.shift?.start ?? '06:00', half: true },
                { name: 'end', label: 'Fim', type: 'time', value: r.shift?.end ?? '18:00', half: true },
              ],
              onSubmit: (v) => api(`/frota/turnos/${r.id}`, { method: 'POST', body: { days: [0, 1, 2, 3, 4, 5, 6].filter((k) => v[`d${k}`] === 'on'), start: v.start, end: v.end } }).then(() => go('turnos')),
            });
        });
      },
    },

    utilizadores: { label: 'Utilizadores', render: () => renderUsers() },
  },
};

// ── Secções partilhadas ─────────────────────────────────────────────────────

const searchBox = (value) =>
  `<form id="search" class="inline-form" role="search"><input name="q" value="${esc(value)}" placeholder="Nome, telefone, matrícula…" aria-label="Pesquisar"><button class="btn">Pesquisar</button></form>`;
function bindSearch(run) {
  const form = $('#search');
  if (form) form.onsubmit = (e) => (e.preventDefault(), run(form.q.value.trim()).catch(showError));
}

/** Tabela de alertas SOS (administrador e frota). */
function sosTable(alerts) {
  return table(
    ['Quando', 'Quem accionou', 'Corrida', 'Estado', 'Localização'],
    alerts.map(
      (a) => `<tr class="${a.open ? 'row-danger' : ''}">
        <td>${esc(when(a.createdAt))}</td>
        <td><strong>${esc(a.name)}</strong><br><span class="muted">${a.role === 'driver' ? 'Motorista' : 'Passageiro'}${a.phone ? ` · ${esc(a.phone)}` : ''}</span></td>
        <td>${a.trip ? `${esc(a.trip.from)}<span class="muted"> → ${esc(a.trip.to || 'a combinar')}</span><br><span class="muted">Motorista ${esc(a.trip.driver)}${a.trip.plate ? ` · ${esc(a.trip.plate)}` : ''} · Passageiro ${esc(a.trip.passenger)}</span>` : '—'}</td>
        <td>${a.open ? badge(['bad', 'Aberto']) : `${badge(['off', 'Fechado'])}${a.closedBy ? `<br><span class="muted small">${esc(a.closedBy)}${a.closeNote ? `: ${esc(a.closeNote)}` : ''}</span>` : ''}`}</td>
        <td>${
          a.lat != null
            ? `<a href="https://www.openstreetmap.org/?mlat=${encodeURIComponent(a.lat)}&mlon=${encodeURIComponent(a.lng)}#map=17/${encodeURIComponent(a.lat)}/${encodeURIComponent(a.lng)}" target="_blank" rel="noopener noreferrer">Ver no mapa</a>`
            : '<span class="muted">Sem posição</span>'
        }</td>
      </tr>`,
    ),
    'Nenhum alerta SOS registado.',
  );
}

// ── Postos policiais e agentes ──────────────────────────────────────────────
// Os agentes não têm painel: usam a aplicação, que os reconhece pelo número.
let postosProvince = '';
async function renderPostos() {
  const d = await api('/admin/postos');
  const KIND = { alert: 'Abriu um alerta', assume: 'Assumiu um alerta', close: 'Fechou um alerta' };
  const provinces = [...new Set(d.stations.map((s) => s.province))];
  if (postosProvince && !provinces.includes(postosProvince)) postosProvince = '';
  const shown = d.stations.filter((s) => !postosProvince || s.province === postosProvince);
  const onDuty = d.stations.reduce((n, s) => n + s.agents.filter((a) => a.onDuty).length, 0);
  const totalAgents = d.stations.reduce((n, s) => n + s.agents.length, 0);
  view.innerHTML =
    header(
      'Postos policiais',
      'Os agentes usam a mesma aplicação: ao entrarem com o número registado aqui, abre-se a área do agente. Só são avisados e só vêem uma corrida quando o passageiro ou o motorista acciona o alerta de perigo.',
      ibtn('plus', 'Novo posto', 'id="new-station"', 'primary'),
    ) +
    `<div class="cards">
      ${stat(d.stations.filter((s) => s.active).length, 'postos activos', false, 'star', 'blue')}
      ${stat(`${onDuty} de ${totalAgents}`, 'agentes de serviço agora', false, 'users', 'green')}
      ${stat(d.openAlerts, 'alertas de perigo abertos', d.openAlerts > 0, 'alert', 'amber')}
    </div>
    <div class="toolbar">
      <label>Província<select id="postos-province"><option value="">Todas</option>${provinces.map((p) => `<option${p === postosProvince ? ' selected' : ''}>${esc(p)}</option>`).join('')}</select></label>
      <p class="muted">Clique no mapa no sítio do posto para o registar, ou use "Novo posto". Um alerta vai para os postos a menos de 10 km; sem resposta em 2 minutos, sobe para o comando provincial.</p>
    </div>
    <div id="map" role="application" aria-label="Mapa dos postos policiais"></div>` +
    (shown.length
      ? shown
          .map(
            (s) => `<div class="panel station">
              <div class="panel-head">
                <div><h2>${esc(s.name)} ${s.command ? badge(['trip', 'Comando provincial']) : ''} ${s.active ? '' : badge(['off', 'Desactivado'])}</h2>
                <p class="muted">${esc([s.municipality, s.province].filter(Boolean).join(', '))}${s.phone ? ` · ${esc(s.phone)}` : ' · sem telefone do posto'}</p></div>
                <div class="row-actions">${ibtn('plus', 'Agente', `data-agent-add="${esc(s.id)}"`, 'small primary')}${ibtn('edit', 'Editar', `data-station-edit="${esc(s.id)}"`, 'small')}${ibtn('trash', 'Apagar', `data-station-del="${esc(s.id)}"`, 'small danger')}</div>
              </div>
              ${
                s.agents.length
                  ? table(
                      ['Agente', 'Telefone', 'Estado', 'Último acesso', ''],
                      s.agents.map(
                        (a) => `<tr>
                          <td>${person(a, esc(a.rank || 'Agente'))}</td>
                          <td>${esc(a.phone)}</td>
                          <td>${badge(!a.active ? ['off', 'Desactivado'] : a.onDuty ? ['ok', 'De serviço'] : ['wait', 'Fora de serviço'])}</td>
                          <td>${a.lastLoginAt ? esc(when(a.lastLoginAt)) : '<span class="muted">Nunca entrou</span>'}</td>
                          <td><div class="row-actions">
                            ${a.hasDevice ? `<button class="btn small" data-agent="${esc(a.id)}" data-do="resetDevice" title="O agente mudou de telemóvel: permite-lhe entrar no aparelho novo">Autorizar outro telemóvel</button>` : ''}
                            <button class="btn small" data-agent="${esc(a.id)}" data-do="resetPassword" title="O agente esqueceu a senha: escolhe outra na próxima entrada">Repor senha</button>
                            <button class="btn small" data-agent="${esc(a.id)}" data-do="${a.active ? 'deactivate' : 'activate'}">${a.active ? 'Desactivar' : 'Activar'}</button>
                            ${ibtn('trash', 'Remover', `data-agent-del="${esc(a.id)}" data-name="${esc(a.name)}"`, 'small danger')}
                          </div></td>
                        </tr>`,
                      ),
                      '',
                    )
                  : '<p class="muted">Este posto ainda não tem agentes. Sem agentes, os alertas desta zona só chegam por SMS ao telefone do posto.</p>'
              }
            </div>`,
          )
          .join('')
      : `<div class="table-wrap"><div class="empty">Ainda não há postos${postosProvince ? ' nesta província' : ''}. Registe o primeiro em "Novo posto".</div></div>`) +
    '<h2>Registo de acessos dos agentes</h2>' +
    table(
      ['Data', 'Posto', 'Agente', 'O que fez', 'Nota'],
      d.queries.map((q) => `<tr><td>${esc(when(q.createdAt))}</td><td>${esc(q.authority)}</td><td>${esc(q.user)}</td><td><strong>${esc(KIND[q.kind] ?? q.kind)}</strong><br><span class="muted">${esc(q.target)}</span></td><td>${esc(q.reason)}</td></tr>`),
      'Ainda não houve acessos.',
    );

  const again = () => go('postos');
  const first = shown[0];
  map = L.map('map').setView(first ? [first.lat, first.lng] : [-8.8383, 13.2344], first ? 11 : 6);
  L.tileLayer(TILES, { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map);
  for (const s of shown) {
    L.circleMarker([s.lat, s.lng], { radius: 8, color: '#14161A', weight: 2, fillColor: s.command ? '#FFC400' : '#2563eb', fillOpacity: s.active ? 1 : 0.35 }).bindTooltip(s.name).addTo(map);
    // A zona em que este posto é avisado de um alerta.
    L.circle([s.lat, s.lng], { radius: 10000, color: '#2563eb', weight: 1, fillOpacity: 0.04, interactive: false }).addTo(map);
  }
  if (shown.length > 1) map.fitBounds(L.latLngBounds(shown.map((s) => [s.lat, s.lng])), { padding: [60, 60], maxZoom: 12 });

  const stationFields = (s = {}) => [
    { name: 'name', label: 'Nome do posto', value: s.name, minlength: 3, maxlength: 100, placeholder: 'Ex.: Esquadra do Kikudo' },
    { name: 'province', label: 'Província', type: 'select', value: s.province ?? (postosProvince || 'Luanda'), options: PROVINCES.map((p) => [p, p]), half: true },
    { name: 'municipality', label: 'Município', value: s.municipality, required: false, maxlength: 60, placeholder: 'Ex.: Soyo', half: true },
    { name: 'phone', label: 'Telefone do posto', type: 'tel', value: s.phone, required: false, maxlength: 20, hint: 'Recebe um SMS quando há um alerta e nenhum agente do posto está de serviço.' },
    { name: 'lat', label: 'Latitude', value: s.lat, inputmode: 'decimal', half: true },
    { name: 'lng', label: 'Longitude', value: s.lng, inputmode: 'decimal', half: true },
    { name: 'command', label: 'Tipo', type: 'select', value: s.command ? 'true' : '', options: [['', 'Posto ou esquadra'], ['true', 'Comando provincial — recebe os alertas sem resposta']] },
  ];
  const newStation = (lat, lng) =>
    modal({
      title: 'Novo posto policial',
      intro: 'A posição vem do ponto marcado no mapa. Depois de criar o posto, registe os seus agentes.',
      fields: stationFields({ lat: lat.toFixed(6), lng: lng.toFixed(6) }),
      submit: 'Criar posto',
      onSubmit: (v) => api('/admin/postos', { method: 'POST', body: { ...v, command: v.command === 'true' } }).then(again),
    });
  map.on('click', (e) => newStation(e.latlng.lat, e.latlng.lng));
  $('#new-station').onclick = () => {
    const c = map.getCenter();
    newStation(c.lat, c.lng);
  };
  $('#postos-province').onchange = (e) => {
    postosProvince = e.target.value;
    again();
  };
  const byId = (id) => d.stations.find((s) => s.id === id);
  view.querySelectorAll('[data-station-edit]').forEach((b) => {
    const s = byId(b.dataset.stationEdit);
    b.onclick = () =>
      modal({
        title: s.name,
        fields: [...stationFields(s), { name: 'active', label: 'Estado', type: 'select', value: s.active ? 'true' : '', options: [['true', 'Activo'], ['', 'Desactivado — deixa de receber alertas']] }],
        onSubmit: (v) => api(`/admin/postos/${s.id}`, { method: 'POST', body: { ...v, command: v.command === 'true', active: v.active === 'true' } }).then(again),
      });
  });
  view.querySelectorAll('[data-station-del]').forEach((b) => {
    const s = byId(b.dataset.stationDel);
    b.onclick = () => {
      if (confirm(`Apagar o posto ${s.name}?`)) act(b, () => api(`/admin/postos/${s.id}`, { method: 'DELETE' }).then(again));
    };
  });
  view.querySelectorAll('[data-agent-add]').forEach((b) => {
    const s = byId(b.dataset.agentAdd);
    b.onclick = () =>
      modal({
        title: `Novo agente · ${s.name}`,
        intro: 'O agente entra na aplicação Bazá com este número: recebe o código SMS e escolhe a sua senha. O número fica exclusivo — não pode ter conta de passageiro nem de motorista.',
        fields: [
          { name: 'name', label: 'Nome', minlength: 2, maxlength: 80 },
          { name: 'rank', label: 'Patente ou função', required: false, maxlength: 40, placeholder: 'Ex.: Subinspector', half: true },
          { name: 'phone', label: 'Telefone', type: 'tel', placeholder: '923 456 789', half: true },
        ],
        submit: 'Registar agente',
        onSubmit: (v) => api(`/admin/postos/${s.id}/agentes`, { method: 'POST', body: v }).then(again),
      });
  });
  const ASK = {
    resetDevice: 'Autorizar este agente a entrar noutro telemóvel? O telemóvel antigo deixa de estar associado.',
    resetPassword: 'Repor a senha deste agente? Na próxima entrada escolhe uma senha nova, depois do código SMS.',
    deactivate: 'Desactivar este agente? Perde o acesso de imediato e deixa de receber alertas.',
  };
  view.querySelectorAll('[data-agent]').forEach(
    (b) =>
      (b.onclick = () => {
        const what = b.dataset.do;
        if (ASK[what] && !confirm(ASK[what])) return;
        const body = what === 'resetDevice' ? { resetDevice: true } : what === 'resetPassword' ? { resetPassword: true } : { active: what === 'activate' };
        act(b, () => api(`/admin/agentes/${b.dataset.agent}`, { method: 'POST', body }).then(again));
      }),
  );
  view.querySelectorAll('[data-agent-del]').forEach(
    (b) =>
      (b.onclick = () => {
        if (confirm(`Remover o agente ${b.dataset.name}? O número fica livre.`)) act(b, () => api(`/admin/agentes/${b.dataset.agentDel}`, { method: 'DELETE' }).then(again));
      }),
  );
}

// ── Utilizadores da frota ───────────────────────────────────────────────────
async function renderUsers() {
  const d = await api('/equipa/utilizadores');
  const ROLE = { manager: 'Gestor', operator: 'Operador' };
  view.innerHTML =
    header(
      'Utilizadores',
      `Quem entra no painel em nome de ${session.institution ?? 'esta instituição'}. Os gestores registam e removem utilizadores; os operadores só usam o painel.`,
      `<div class="row-actions">${ibtn('key', 'Alterar a minha palavra-passe', 'id="my-password"')}${d.canManage ? ibtn('plus', 'Novo utilizador', 'id="add-user"', 'primary') : ''}</div>`,
    ) +
    table(
      ['Nome', 'Email', 'Papel', 'Último acesso', 'Estado', ''],
      d.users.map(
        (u, i) => `<tr>
          <td>${person(u)}${u.you ? ' <span class="badge ok">Você</span>' : ''}</td>
          <td>${esc(u.email)}</td>
          <td>${esc(ROLE[u.role])}</td>
          <td>${u.lastLoginAt ? esc(when(u.lastLoginAt)) : '<span class="muted">Nunca entrou</span>'}</td>
          <td>${badge(u.active ? ['ok', 'Activo'] : ['off', 'Desactivado'])}</td>
          <td>${
            d.canManage && !u.you
              ? `<div class="row-actions"><button class="btn small" data-user-role="${i}">${u.role === 'manager' ? 'Passar a operador' : 'Tornar gestor'}</button><button class="btn small" data-user-active="${i}">${u.active ? 'Desactivar' : 'Activar'}</button>${ibtn('trash', 'Remover', `data-user-del="${i}"`, 'small danger')}</div>`
              : ''
          }</td>
        </tr>`,
      ),
      'Sem utilizadores.',
    );
  const again = () => go('utilizadores');
  $('#my-password').onclick = () =>
    modal({
      title: 'Alterar a minha palavra-passe',
      fields: [
        { name: 'current', label: 'Palavra-passe actual', type: 'password', autocomplete: 'current-password' },
        { name: 'next', label: 'Nova palavra-passe', type: 'password', minlength: 8, autocomplete: 'new-password', hint: 'Pelo menos 8 caracteres.' },
        { ...CONFIRM_FIELD, label: 'Repita a nova palavra-passe' },
      ],
      onSubmit: async (v) => {
        checkConfirm(v.next, v.confirm);
        await api('/equipa/palavra-passe', { method: 'POST', body: { current: v.current, next: v.next } });
        session.mustChangePassword = false;
        sessionStorage.setItem('baza-painel', JSON.stringify(session));
        await again();
      },
    });
  const add = $('#add-user');
  if (add) {
    add.onclick = () =>
      modal({
        title: 'Novo utilizador',
        intro: 'A pessoa entra no painel com este email e a palavra-passe provisória, e é convidada a trocá-la.',
        fields: [
          { name: 'name', label: 'Nome', minlength: 2, maxlength: 80 },
          { name: 'email', label: 'Email', type: 'email' },
          { name: 'role', label: 'Papel', type: 'select', value: 'operator', options: [['operator', 'Operador — só usa o painel'], ['manager', 'Gestor — também gere utilizadores']] },
          { name: 'password', label: 'Palavra-passe provisória', type: 'password', minlength: 8, autocomplete: 'new-password', half: true },
          { ...CONFIRM_FIELD, half: true },
        ],
        submit: 'Registar',
        onSubmit: async ({ confirm: confirmation, ...v }) => {
          checkConfirm(v.password, confirmation);
          await api('/equipa/utilizadores', { method: 'POST', body: v });
          await again();
        },
      });
  }
  const change = (u, body) => api(`/equipa/utilizadores/${u.id}`, { method: 'POST', body }).then(again);
  view.querySelectorAll('[data-user-role]').forEach((b) => (b.onclick = () => act(b, () => change(d.users[b.dataset.userRole], { role: d.users[b.dataset.userRole].role === 'manager' ? 'operator' : 'manager' }))));
  view.querySelectorAll('[data-user-active]').forEach((b) => (b.onclick = () => act(b, () => change(d.users[b.dataset.userActive], { active: !d.users[b.dataset.userActive].active }))));
  view.querySelectorAll('[data-user-del]').forEach((b) => {
    const u = d.users[b.dataset.userDel];
    b.onclick = () => {
      if (confirm(`Remover ${u.name}? Deixa de poder entrar no painel.`)) act(b, () => api(`/equipa/utilizadores/${u.id}`, { method: 'DELETE' }).then(again));
    };
  });
}

/** Miniaturas de documentos: as fotos são privadas, por isso pedem-se com a sessão. */
function loadThumbs(root, driverId, base = '/admin') {
  root.querySelectorAll('.thumbs button[data-doc]').forEach(async (btn) => {
    try {
      const res = await fetch(`${API}${base}/documentos/${driverId}/${btn.dataset.doc}`, { headers: { Authorization: `Bearer ${session.token}` } });
      if (!res.ok) throw new Error();
      const url = URL.createObjectURL(await res.blob());
      const img = new Image();
      img.src = url;
      img.alt = btn.getAttribute('aria-label').replace('Ver ', '');
      btn.replaceChildren(img);
      btn.onclick = () => window.open(url, '_blank', 'noopener');
    } catch {
      btn.textContent = 'Não foi possível carregar';
    }
  });
}

/**
 * Ficha do motorista: dados, documentos e historial, para decidir com
 * fundamento se se suspende ou se reactiva. Suspender exige um motivo.
 */
async function driverFile(id, reload, { base = '/admin', readOnly = false } = {}) {
  const d = await api(`${base}/motoristas/${id}`);
  const REVIEW = { approved: ['ok', 'Aprovado'], pending: ['wait', 'Em análise'], rejected: ['bad', 'Rejeitado'] };
  const thumbs = (photos) =>
    photos.length
      ? `<div class="thumbs">${photos.map(([doc, label]) => `<button type="button" data-doc="${esc(doc)}" aria-label="Ver ${esc(label)}">${esc(label)}</button>`).join('')}</div>`
      : '<span class="muted">Sem fotografias enviadas</span>';
  const fact = (n, label, bad = false) => `<div class="fact${bad ? ' bad' : ''}"><b>${esc(n)}</b><span>${esc(label)}</span></div>`;
  // Sinais que merecem atenção antes de decidir.
  const flags = [
    d.license?.expired && 'Carta de condução caducada',
    ...d.vehicles.filter((v) => v.insuranceExpired).map((v) => `Seguro caducado (${v.plate})`),
    d.rating !== null && d.rating < 4 && d.ratingCount >= 5 && `Avaliação média baixa (${d.rating})`,
    d.stats.lowRatings >= 3 && `${d.stats.lowRatings} avaliações de 1 ou 2 estrelas`,
    d.stats.lateCancelled >= 3 && `${d.stats.lateCancelled} cancelamentos tardios`,
    d.stats.sos > 0 && `${d.stats.sos} ${d.stats.sos === 1 ? 'alerta SOS' : 'alertas SOS'} em corridas suas`,
    d.tickets.some((t) => t.status === 'open') && 'Tem pedidos de suporte por responder',
  ].filter(Boolean);
  const html = `
    <div class="ficha">
      <div class="person big">${avatar(d)}<div><strong>${esc(d.name)}</strong><br><span class="muted">${esc(d.phone ?? d.email ?? '')}${d.fleet ? ` · Frota ${esc(d.fleet)}` : ''} · desde ${esc(day(d.createdAt))}</span><br>${badge(VERIFICATION[d.verification])} ${driverState(d)}${d.star ? ` ${badge(['trip', '★ Estrela'])}` : ''}</div></div>
      ${d.blocked ? `<p class="notice"><strong>Conta suspensa</strong>${d.blockedAt ? ` em ${esc(when(d.blockedAt))}` : ''}${d.blockedBy ? ` por ${esc(d.blockedBy)}` : ''}.${d.blockedReason ? ` Motivo: ${esc(d.blockedReason)}` : ''}</p>` : ''}
      ${
        flags.length
          ? `<div class="flags"><strong>${icon('alert', 16)} A ter em conta</strong><ul>${flags.map((f) => `<li>${esc(f)}</li>`).join('')}</ul></div>`
          : `<div class="allgood small">${icon('check', 18)}<span>Sem sinais de alerta nos dados deste motorista.</span></div>`
      }
      <div class="facts">
        ${fact(d.stats.rides, 'corridas concluídas')}
        ${fact(d.stats.rides30, 'nos últimos 30 dias')}
        ${fact(d.rating ?? '—', `avaliação (${d.ratingCount})`, d.rating !== null && d.rating < 4)}
        ${fact(d.stats.cancelled, 'cancelou depois de aceitar', d.stats.lateCancelled >= 3)}
        ${fact(d.stats.lowRatings, 'avaliações de 1–2 ★', d.stats.lowRatings >= 3)}
        ${fact(kz(d.commissionDue), 'comissões por pagar')}
      </div>
      <h3>Carta de condução</h3>
      ${
        d.license
          ? `<div class="doc-row"><div class="info">N.º ${esc(d.license.number)} · categoria ${esc(d.license.category)}<br><span class="${d.license.expired ? 'bad-text' : 'muted'}">${d.license.expired ? 'Caducou em' : 'Válida até'} ${esc(day(d.license.expiresAt))}</span><br>${badge(REVIEW[d.license.status])}${d.license.note ? ` <span class="muted">${esc(d.license.note)}</span>` : ''}</div>${thumbs(d.license.photos)}</div>`
          : '<p class="muted">Ainda não registou a carta de condução.</p>'
      }
      <h3>Viaturas</h3>
      ${
        d.vehicles.length
          ? d.vehicles
              .map(
                (v) => `<div class="doc-row"><div class="info"><strong>${esc(v.label)}</strong> · ${esc(v.plate)}${v.active ? ` ${badge(['ok', 'Em uso'])}` : ''}<br><span class="muted">${esc(v.category)} · ${esc(v.color)}</span><br><span class="${v.insuranceExpired ? 'bad-text' : 'muted'}">${v.insuranceExpiresAt ? `Seguro ${v.insuranceExpired ? 'caducou em' : 'válido até'} ${esc(day(v.insuranceExpiresAt))}` : 'Sem data do seguro'}</span><br>${badge(REVIEW[v.status])}${v.note ? ` <span class="muted">${esc(v.note)}</span>` : ''}</div>${thumbs(v.photos)}</div>`,
              )
              .join('')
          : '<p class="muted">Ainda não registou nenhuma viatura.</p>'
      }
      <h3>Últimas corridas</h3>
      ${
        d.recent.length
          ? `<table class="mini">${d.recent
              .map(
                (r) => `<tr><td>${esc(when(r.createdAt))}</td><td>${esc(r.from)}<span class="muted"> → ${esc(r.to || 'a combinar')}</span></td><td>${badge(RIDE_STATUS[r.status] ?? ['off', r.status])}${r.cancelledBy === 'driver' ? ' <span class="muted small">pelo motorista</span>' : ''}</td><td class="num">${r.rating ? `★ ${esc(r.rating)}` : ''}</td></tr>`,
              )
              .join('')}</table>`
          : '<p class="muted">Ainda não fez corridas.</p>'
      }
      ${
        d.tickets.length
          ? `<h3>Pedidos de suporte dele</h3>${d.tickets.map((t) => `<p class="small">${badge(t.status === 'open' ? ['wait', 'Por responder'] : ['ok', 'Respondido'])} <strong>${esc(TICKET_CATEGORY[t.category] ?? t.category)}</strong> · ${esc(when(t.createdAt))}<br><span class="muted">${esc(t.message)}</span></p>`).join('')}`
          : ''
      }
    </div>`;
  const form = modal({
    title: 'Ficha do motorista',
    wide: true,
    html,
    fields: readOnly || d.blocked ? [] : [{ name: 'reason', label: 'Motivo da suspensão', type: 'textarea', minlength: 5, maxlength: 300, placeholder: 'O motorista lê este motivo no app. Ex.: seguro da viatura caducado.', hint: 'Só é preciso se for suspender. Para sair sem alterar nada, use "Cancelar".' }],
    submit: readOnly ? null : d.blocked ? 'Reactivar motorista' : 'Suspender motorista',
    danger: !d.blocked,
    onSubmit: (v) => api(`/admin/motoristas/${id}/bloqueio`, { method: 'POST', body: d.blocked ? { blocked: false } : { blocked: true, reason: v.reason } }).then(reload),
  });
  loadThumbs(form, id, base);
  form.querySelectorAll('[data-photo]').forEach((b) => (b.onclick = () => window.open(b.dataset.photo, '_blank', 'noopener')));
  // Abre no cimo da ficha, não no campo do motivo.
  form.querySelector('[data-close]').focus();
  $('#modal').scrollTop = 0;
}

/**
 * Janela para enviar um aviso. Com `id`, vai para essa pessoa; sem ele, para
 * todos os motoristas ou todos os passageiros (`kind`).
 */
function noticeModal({ kind, id, name }, done) {
  const fleet = session.role === 'fleet';
  const everyone = fleet ? 'todos os motoristas da frota' : kind === 'motoristas' ? 'todos os motoristas' : 'todos os passageiros';
  modal({
    title: id ? `Aviso para ${name}` : `Aviso para ${everyone}`,
    intro: 'Aparece numa janela no app e chega por notificação. A pessoa tem de tocar em "Entendi".',
    fields: [
      { name: 'title', label: 'Título', minlength: 3, maxlength: 80, placeholder: 'Ex.: Documentos a caducar' },
      { name: 'message', label: 'Mensagem', type: 'textarea', rows: 5, minlength: 5, maxlength: 600, placeholder: 'Escreva de forma clara o que a pessoa deve saber ou fazer.' },
    ],
    submit: id ? 'Enviar aviso' : `Enviar a ${everyone}`,
    onSubmit: async (v) => {
      if (!id && !confirm(`Enviar este aviso a ${everyone}?`)) throw new Error('Envio cancelado.');
      const r = await api(fleet ? '/frota/avisos' : '/admin/avisos', { method: 'POST', body: fleet ? { id, title: v.title, message: v.message } : { kind, id, title: v.title, message: v.message } });
      if (done) await done(r);
    },
  });
}
/** Botões "Avisar" das listas de pessoas. */
function bindNotices() {
  view.querySelectorAll('[data-notice]').forEach((b) => (b.onclick = () => noticeModal({ kind: b.dataset.kind, id: b.dataset.notice, name: b.dataset.name })));
}

/** Botões "Repor senha": cria uma senha provisória, mostrada uma só vez. */
function bindResets() {
  view.querySelectorAll('[data-reset]').forEach(
    (b) =>
      (b.onclick = () => {
        if (!confirm(`Repor a senha de ${b.dataset.name}? A senha actual deixa de funcionar.`)) return;
        act(b, async () => {
          const r = await api(`/admin/${b.dataset.kind}/${b.dataset.reset}/senha`, { method: 'POST' });
          modal({
            title: `Senha provisória de ${b.dataset.name}`,
            intro: 'Diga-a ao utilizador e peça-lhe para a mudar em "Os meus dados". Não volta a ser mostrada.',
            html: `<p class="code">${esc(r.password)}</p>`,
            submit: null,
          });
          b.disabled = false;
        });
      }),
  );
}

/** Botões "Tornar estrela": quem é estrela pode registar locais no mapa a partir do app. */
function bindStars(reload) {
  view.querySelectorAll('[data-star]').forEach(
    (b) =>
      (b.onclick = () =>
        act(b, () =>
          api(`/admin/${b.dataset.kind}/${b.dataset.star}/estrela`, { method: 'POST', body: { star: b.dataset.value === 'true' } }).then(reload),
        )),
  );
}

async function renderRides(path, showCommission) {
  const { rides } = await api(path);
  view.innerHTML =
    header('Corridas', 'As 100 mais recentes.') +
    table(
      ['Data', 'Passageiro', 'Motorista', 'Serviço', 'Percurso', 'Estado', { label: 'Valor', num: true }],
      rides.map(
        (r) => `<tr>
          <td>${esc(when(r.createdAt))}</td>
          <td>${esc(r.passenger)}</td>
          <td>${esc(r.driver)}</td>
          <td>${esc(r.service)}</td>
          <td>${esc(r.from)}<br><span class="muted">→ ${esc(r.to)}</span></td>
          <td>${badge(RIDE_STATUS[r.status] ?? ['off', r.status])}</td>
          <td class="num">${kz(r.fare)}<br><span class="muted">${esc(PAYMENT[r.payment] ?? r.payment)}${showCommission ? ` · comissão ${kz(r.commission)}` : ''}</span></td>
        </tr>`,
      ),
      'Ainda não há corridas.',
    );
}

const PROVINCES = ['Bengo', 'Benguela', 'Bié', 'Cabinda', 'Cuando', 'Cuanza Norte', 'Cuanza Sul', 'Cubango', 'Cunene', 'Huambo', 'Huíla', 'Ícolo e Bengo', 'Luanda', 'Lunda Norte', 'Lunda Sul', 'Malanje', 'Moxico', 'Moxico Leste', 'Namibe', 'Uíge', 'Zaire'];
// Onde centrar o mapa ao escolher a província (capital de cada uma, quando conhecida).
const PROVINCE_CENTER = { Luanda: [-8.8383, 13.2344], Zaire: [-6.267, 14.2401] };
let locaisState = { province: 'Zaire', q: '' };

/** Registo de locais: pontos conhecidos de cada província, que aparecem na pesquisa do app. */
async function renderLocais() {
  const { province, q } = locaisState;
  const data = await api(`/admin/locais?provincia=${encodeURIComponent(province)}&q=${encodeURIComponent(q)}`);
  setCount('locais', data.toReview);
  const count = (name) => data.provinces.find((p) => p.name === name)?.count ?? 0;
  view.innerHTML =
    header('Locais', `Pontos registados pela equipa e pelos utilizadores estrela: aparecem no mapa e primeiro na pesquisa do app. ${data.total} no total.`, ibtn('plus', 'Adicionar local', 'id="new-place"', 'primary')) +
    (data.toReview
      ? `<p class="notice">${data.toReview} ${data.toReview === 1 ? 'local registado por um utilizador estrela está' : 'locais registados por utilizadores estrela estão'} por rever. ${data.needApproval ? 'Só aparecem na pesquisa depois de aprovados.' : 'Já aparecem na pesquisa; reveja-os e remova os que estiverem errados.'}</p>`
      : '') +
    `<div class="toolbar">
      <label>Província<select id="province">${PROVINCES.map((p) => `<option${p === province ? ' selected' : ''}>${esc(p)}${count(p) ? ` (${count(p)})` : ''}</option>`).join('')}</select></label>
      <p class="muted">Clique no mapa no sítio exacto para registar um local, ou use "Adicionar local".</p>
    </div>
    <div id="map" role="application" aria-label="Mapa para marcar o local"></div>
    <h2>Locais em ${esc(province)} (${count(province)})</h2>
    <form id="filter-local" class="inline-form" role="search"><input name="q" value="${esc(q)}" placeholder="Filtrar por nome…" aria-label="Filtrar locais"><button class="btn">Filtrar</button></form>` +
    table(
      ['Nome', 'Bairro ou município', 'Posição', 'Registado por', ''],
      data.locais.map(
        (l) => `<tr>
          <td>${esc(l.name)}</td>
          <td>${esc(l.zone || '—')}</td>
          <td><a href="#" data-show-local="${l.lat},${l.lng}">${l.lat.toFixed(5)}, ${l.lng.toFixed(5)}</a></td>
          <td>${esc(l.addedBy ?? 'Equipa Bazá')}${l.reviewed ? '' : ` ${badge(['wait', 'Por rever'])} <button class="btn small" data-approve-local="${esc(l.id)}">Aprovar</button>`}</td>
          <td class="num"><button class="btn small danger" data-remove-local="${esc(l.id)}" data-name="${esc(l.name)}">Remover</button></td>
        </tr>`,
      ),
      q ? 'Nenhum local com esse nome nesta província.' : 'Ainda não há locais registados nesta província.',
    );

  const center = PROVINCE_CENTER[province] ?? (data.locais[0] ? [data.locais[0].lat, data.locais[0].lng] : [-11.2, 17.87]);
  map = L.map('map').setView(center, PROVINCE_CENTER[province] || data.locais[0] ? 13 : 6);
  L.tileLayer(TILES, { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map);
  for (const l of data.locais) L.circleMarker([l.lat, l.lng], { radius: 6, color: '#14161A', fillColor: '#FFC400', fillOpacity: 1, weight: 2 }).bindTooltip(l.name).addTo(map);
  let marker = null;
  /** Abre a janela de registo, já com a posição (do clique no mapa ou do centro do mapa). */
  const addPlace = (lat, lng) => {
    if (marker) marker.setLatLng([lat, lng]);
    else marker = L.marker([lat, lng]).addTo(map);
    modal({
      title: `Adicionar local em ${province}`,
      intro: 'Escreva o nome por que o local é conhecido. A posição vem do ponto marcado no mapa.',
      fields: [
        { name: 'name', label: 'Nome do local', minlength: 2, maxlength: 80, placeholder: 'Ex.: Mercado do Kikolo' },
        { name: 'zone', label: 'Bairro ou município', required: false, maxlength: 60, placeholder: 'Ex.: Soyo' },
        { name: 'lat', label: 'Latitude', value: lat.toFixed(6), inputmode: 'decimal', half: true },
        { name: 'lng', label: 'Longitude', value: lng.toFixed(6), inputmode: 'decimal', half: true },
      ],
      submit: 'Adicionar',
      onSubmit: (v) => api('/admin/locais', { method: 'POST', body: { province, ...v } }).then(() => go('locais')),
    });
  };
  map.on('click', (e) => addPlace(e.latlng.lat, e.latlng.lng));
  $('#new-place').onclick = () => {
    const c = map.getCenter();
    addPlace(c.lat, c.lng);
  };
  $('#province').onchange = (e) => {
    // O texto da opção pode trazer a contagem: "Zaire (12)".
    locaisState = { province: PROVINCES[e.target.selectedIndex], q: '' };
    go('locais');
  };
  $('#filter-local').onsubmit = (e) => {
    e.preventDefault();
    locaisState.q = e.target.q.value.trim();
    go('locais');
  };
  view.querySelectorAll('[data-show-local]').forEach(
    (a) =>
      (a.onclick = (e) => {
        e.preventDefault();
        const [lat, lng] = a.dataset.showLocal.split(',').map(Number);
        map.setView([lat, lng], 17);
        $('#map').scrollIntoView({ behavior: 'smooth', block: 'center' });
      }),
  );
  view.querySelectorAll('[data-approve-local]').forEach(
    (b) => (b.onclick = () => act(b, () => api(`/admin/locais/${b.dataset.approveLocal}/aprovar`, { method: 'POST' }).then(() => go('locais')))),
  );
  view.querySelectorAll('[data-remove-local]').forEach(
    (b) =>
      (b.onclick = () => {
        if (!confirm(`Remover o local "${b.dataset.name}"? Deixa de aparecer na pesquisa do app.`)) return;
        act(b, () => api(`/admin/locais/${b.dataset.removeLocal}`, { method: 'DELETE' }).then(() => go('locais')));
      }),
  );
}

/** Mapa com os motoristas online, actualizado de poucos em poucos segundos. */
async function renderMap(path) {
  view.innerHTML =
    header('Mapa ao vivo', 'Motoristas online neste momento.') +
    `<div id="map" role="application" aria-label="Mapa dos motoristas online"></div>
     <div class="legend"><span><i style="background:var(--green)"></i>Livre</span><span><i style="background:var(--yellow)"></i>Em viagem</span><span id="map-count"></span></div>`;
  map = L.map('map').setView([-8.8383, 13.2344], 12);
  L.tileLayer(TILES, { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map);
  const layer = L.layerGroup().addTo(map);
  let fitted = false;

  async function update() {
    const { drivers } = await api(path);
    const visible = drivers.filter((d) => d.position);
    layer.clearLayers();
    for (const d of visible) {
      const icon = L.divIcon({ className: '', html: `<div class="pin${d.onTrip ? ' trip' : ''}">🚕</div>`, iconSize: [30, 30], iconAnchor: [15, 15] });
      const popup = document.createElement('div');
      popup.innerHTML = `<strong>${esc(d.name)}</strong><br>${esc(d.vehicle ? `${d.vehicle.label} · ${d.vehicle.plate}` : '')}<br>${d.onTrip ? 'Em viagem' : 'Livre'} · posição das ${esc(new Date(d.positionAt).toLocaleTimeString('pt-PT', { hour: '2-digit', minute: '2-digit' }))}`;
      L.marker([d.position.lat, d.position.lng], { icon, title: d.name }).bindPopup(popup).addTo(layer);
    }
    $('#map-count').textContent = `${visible.length} no mapa`;
    if (!fitted && visible.length) {
      fitted = true;
      map.fitBounds(L.latLngBounds(visible.map((d) => [d.position.lat, d.position.lng])), { padding: [50, 50], maxZoom: 15 });
    }
  }
  await update();
  refreshTimer = setInterval(() => update().catch(() => {}), 8000);
}

// ── Navegação ───────────────────────────────────────────────────────────────

function setCount(key, n) {
  const el = $(`#nav a[data-key="${key}"] .count`);
  if (!el) return;
  el.textContent = n;
  el.hidden = !n;
}

async function go(key) {
  const mine = sections[session.role];
  if (key === 'acesso') key = 'definicoes'; // endereço antigo
  if (!mine[key]) key = 'resumo';
  currentKey = key;
  // Barra do topo: grupo › secção.
  const group = GROUPS[session.role].find(([, keys]) => keys.includes(key))?.[0];
  $('#crumb').innerHTML = `${group ? `<span class="muted">${esc(group)}</span><span class="muted" aria-hidden="true">›</span>` : ''}<strong>${esc(mine[key].label)}</strong>`;
  if ($('#modal').open) $('#modal').close();
  if (location.hash !== `#${key}`) history.replaceState(null, '', `#${key}`);
  clearInterval(refreshTimer);
  refreshTimer = null;
  if (map) {
    map.remove();
    map = null;
  }
  document.querySelectorAll('#nav a').forEach((a) => {
    if (a.dataset.key === key) a.setAttribute('aria-current', 'page');
    else a.removeAttribute('aria-current');
  });
  view.innerHTML = '<p class="muted">A carregar…</p>';
  try {
    await mine[key].render();
    if (session.mustChangePassword && session.role !== 'admin' && key !== 'utilizadores') {
      const warn = document.createElement('p');
      warn.className = 'notice';
      warn.innerHTML = 'A sua palavra-passe foi definida por outra pessoa. <a href="#utilizadores">Troque-a agora</a> (Utilizadores › Alterar a minha palavra-passe).';
      view.prepend(warn);
    }
    if (session.mustChangePassword && session.role === 'admin' && key !== 'administradores') {
      const warn = document.createElement('p');
      warn.className = 'notice';
      warn.innerHTML =
        'Está a usar a palavra-passe por defeito. <a href="#administradores">Troque-a agora</a> (Administradores › Alterar a minha palavra-passe) para proteger o painel.';
      view.prepend(warn);
    }
    if (mine[key].refresh) {
      // Actualiza em segundo plano, sem apagar o que está no ecrã se falhar.
      refreshTimer = setInterval(() => {
        if (!document.hidden && !$('#modal').open && !view.querySelector('form:focus-within')) mine[key].render().catch(() => {});
      }, mine[key].refresh);
    }
  } catch (err) {
    view.innerHTML = '';
    showError(err);
  }
}

function start() {
  $('#auth').hidden = !!session;
  $('#app').hidden = !session;
  if (!session) return;
  $('#who-name').textContent = session.name;
  $('#who-role').textContent =
    session.role === 'admin' ? 'Bazá · Administrador' : `${session.institution ?? ''} · ${session.userRole === 'manager' ? 'Gestor' : 'Operador'}`;
  const mine = sections[session.role];
  $('#nav').innerHTML = GROUPS[session.role]
    .map(
      ([title, keys]) =>
        (title ? `<p class="group">${esc(title)}</p>` : '') +
        keys
          .filter((key) => mine[key])
          .map((key) => `<a href="#${key}" data-key="${key}">${icon(SECTION_ICON[key])}<span class="t">${esc(mine[key].label)}</span><span class="count" hidden></span></a>`)
          .join(''),
    )
    .join('');
  $('#logout').innerHTML = `${icon('logout', 16)}<span>Sair</span>`;
  $('#who-initial').textContent = (session.name.trim()[0] ?? '?').toUpperCase();
  go(location.hash.slice(1) || 'resumo');
}

function logout() {
  session = null;
  sessionStorage.removeItem('baza-painel');
  clearInterval(refreshTimer);
  history.replaceState(null, '', location.pathname);
  start();
}

window.addEventListener('hashchange', () => session && go(location.hash.slice(1)));

// ── Tema claro ou escuro ────────────────────────────────────────────────────
// O tema inicial é posto por tema.js; aqui fica o botão que o troca e guarda.
function paintTheme() {
  const dark = document.documentElement.dataset.theme === 'dark';
  const label = dark ? 'Mudar para o modo claro' : 'Mudar para o modo escuro';
  $('#theme').innerHTML = icon(dark ? 'sun' : 'moon', 20);
  $('#theme').setAttribute('aria-label', label);
  $('#theme').title = label;
}
$('#theme').onclick = () => {
  const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  try {
    localStorage.setItem('baza-tema', next);
  } catch {
    // Sem armazenamento, a escolha vale só até recarregar.
  }
  paintTheme();
};
paintTheme();
$('#logout').onclick = logout;

// ── Entrada e registo de frota ──────────────────────────────────────────────

function showAuth(which) {
  $('#login-form').hidden = which !== 'login';
  $('#register-form').hidden = which !== 'register';
  $('#register-done').hidden = which !== 'done';
  $('#auth-title').textContent = which === 'register' ? 'Registar frota' : 'Painel de gestão';
  $('#auth-sub').textContent =
    which === 'register' ? 'Para empresas com motoristas próprios.' : 'Para administradores e frotas parceiras.';
}
document.querySelectorAll('[data-show]').forEach((b) => (b.onclick = () => showAuth(b.dataset.show)));

async function submitAuth(form, run) {
  const error = $('.error', form);
  const button = $('button[type=submit]', form);
  error.hidden = true;
  button.disabled = true;
  try {
    await run(Object.fromEntries(new FormData(form)));
  } catch (err) {
    error.textContent = err.message;
    error.hidden = false;
  } finally {
    button.disabled = false;
  }
}

$('#login-form').onsubmit = (e) => {
  e.preventDefault();
  submitAuth(e.target, async (body) => {
    session = await api('/login', { method: 'POST', body });
    sessionStorage.setItem('baza-painel', JSON.stringify(session));
    e.target.reset();
    start();
  });
};

$('#register-form').onsubmit = (e) => {
  e.preventDefault();
  submitAuth(e.target, async ({ confirm: confirmation, ...body }) => {
    checkConfirm(body.password, confirmation);
    await api('/frotas/registo', { method: 'POST', body });
    e.target.reset();
    showAuth('done');
  });
};

start();

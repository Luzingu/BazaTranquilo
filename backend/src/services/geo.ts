import { config } from '../config.js';
import { LocalModel, searchKeyOf } from '../models/misc.js';

export interface LatLng {
  lat: number;
  lng: number;
}

const USER_AGENT = 'BazaApp/0.1';
const COUNTRY = process.env.COUNTRY_CODES ?? 'ao';

export function haversineM(a: LatLng, b: LatLng) {
  const R = 6371000;
  const rad = (d: number) => (d * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

async function getJson(url: string): Promise<any> {
  const res = await fetch(url, {
    headers: { 'User-Agent': USER_AGENT, 'Accept-Language': 'pt' },
    signal: AbortSignal.timeout(7000),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

export interface RouteInfo {
  distanceM: number;
  durationS: number;
  /** Polyline codificada (precisão 5) ou null se o serviço de rotas falhou. */
  geometry: string | null;
}

/** Rota de carro entre dois pontos. Se o OSRM falhar, estima em linha recta. */
/**
 * Rota de carro entre dois pontos, passando pelas paragens `via` pela ordem
 * dada. Se o OSRM falhar, estima em linha recta.
 */
export async function getRoute(from: LatLng, to: LatLng, via: LatLng[] = []): Promise<RouteInfo> {
  const points = [from, ...via, to];
  try {
    const coords = points.map((p) => `${p.lng},${p.lat}`).join(';');
    const data = await getJson(
      `${config.osrmUrl}/route/v1/driving/${coords}?overview=full&geometries=polyline`,
    );
    const route = data.routes?.[0];
    if (!route) throw new Error('sem rota');
    return {
      distanceM: Math.round(route.distance),
      durationS: Math.round(route.duration),
      geometry: route.geometry ?? null,
    };
  } catch (err) {
    console.warn('OSRM indisponível, a usar estimativa em linha recta:', (err as Error).message);
    let straight = 0;
    for (let i = 1; i < points.length; i++) straight += haversineM(points[i - 1]!, points[i]!);
    const distanceM = Math.round(straight * 1.35);
    return { distanceM, durationS: Math.round(distanceM / (25 / 3.6)), geometry: null };
  }
}

export interface Place extends LatLng {
  address: string;
}

function shortAddress(item: any): string {
  const a = item.address ?? {};
  const street = [a.road ?? a.pedestrian ?? item.name, a.house_number].filter(Boolean).join(' ');
  const area = a.suburb ?? a.neighbourhood ?? a.city_district ?? a.town ?? a.city ?? a.county;
  const parts = [street, area].filter(Boolean);
  return parts.length
    ? [...new Set(parts)].join(', ')
    : String(item.display_name ?? '').split(',').slice(0, 3).join(',');
}

export interface Suggestion extends Place {
  /** Nome curto do local, ex.: "Talatona". */
  title: string;
  /** Zona onde fica, ex.: "Belas, Luanda". */
  subtitle: string;
}

const PHOTON_URL = process.env.PHOTON_URL ?? 'https://photon.komoot.io';
/** Limites de Angola (oeste, sul, leste, norte), para não sugerir outros países. */
const COUNTRY_BBOX = process.env.COUNTRY_BBOX ?? '11.4,-18.1,24.1,-4.3';

const uniq = (parts: unknown[]) => [...new Set(parts.filter(Boolean).map(String))];

/** Pesquisa por prefixo ("tala" → Talatona), própria para sugerir enquanto se escreve. */
async function photonSearch(q: string, near?: LatLng): Promise<Suggestion[]> {
  const params = new URLSearchParams({ q, limit: '10', bbox: COUNTRY_BBOX });
  if (near) {
    params.set('lat', String(near.lat));
    params.set('lon', String(near.lng));
  }
  const data = await getJson(`${PHOTON_URL}/api/?${params}`);
  const out: Suggestion[] = [];
  for (const f of (data.features ?? []) as any[]) {
    const p = f.properties ?? {};
    const [lng, lat] = f.geometry?.coordinates ?? [];
    if (typeof lat !== 'number' || typeof lng !== 'number') continue;
    if (p.countrycode && String(p.countrycode).toLowerCase() !== COUNTRY) continue;
    const street = [p.street, p.housenumber].filter(Boolean).join(' ');
    const title = String(p.name ?? street);
    if (!title) continue;
    const area = uniq([p.name ? street : '', p.district, p.city, p.state]).filter((x) => x !== title);
    const subtitle = area.slice(0, 3).join(', ');
    out.push({ title, subtitle, address: uniq([title, area[0]]).join(', '), lat, lng });
  }
  return out;
}

async function nominatimSearch(q: string, near?: LatLng): Promise<Suggestion[]> {
  const params = new URLSearchParams({
    format: 'jsonv2',
    q,
    limit: '8',
    addressdetails: '1',
    countrycodes: COUNTRY,
  });
  if (near) {
    const d = 0.6;
    params.set('viewbox', `${near.lng - d},${near.lat + d},${near.lng + d},${near.lat - d}`);
  }
  const data = await getJson(`${config.nominatimUrl}/search?${params}`);
  return (data as any[]).map((item) => {
    const address = shortAddress(item);
    const [title = address, ...rest] = address.split(', ');
    const a = item.address ?? {};
    const subtitle = uniq([...rest, a.city ?? a.town, a.state]).slice(0, 3).join(', ');
    return { title, subtitle, address, lat: Number(item.lat), lng: Number(item.lon) };
  });
}

/** Raio (m) dentro do qual um resultado conta como "perto" de quem pesquisa. */
const NEARBY_M = 80_000;

/** Locais do nosso registo cujo nome ou zona contém todas as palavras escritas. */
async function ownPlaces(q: string, near?: LatLng): Promise<Suggestion[]> {
  const words = searchKeyOf(q).split(' ').filter(Boolean).slice(0, 6);
  if (!words.length) return [];
  const esc = (w: string) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const found = await LocalModel.find({
    $and: words.map((w) => ({ searchKey: new RegExp(`(^| )${esc(w)}`) })),
    ...(config.starPlacesNeedApproval ? { reviewed: { $ne: false } } : {}),
  })
    .limit(40)
    .lean();
  const out = found.map((l) => {
    const subtitle = uniq([l.zone, l.province]).join(', ');
    return { title: l.name, subtitle, address: uniq([l.name, l.zone || l.province]).join(', '), lat: l.lat, lng: l.lng };
  });
  if (near) out.sort((a, b) => haversineM(near, a) - haversineM(near, b));
  return out.slice(0, 6);
}

/** Chamado quando o registo de locais muda, para a pesquisa mostrar logo as alterações. */
export const clearSearchCache = () => searchCache.clear();

const searchCache = new Map<string, { at: number; results: Suggestion[] }>();
const CACHE_TTL_MS = 10 * 60_000;

/** Sugestões de locais para um texto parcial, das mais próximas de `near` primeiro. */
export async function searchPlaces(q: string, near?: LatLng): Promise<Suggestion[]> {
  // Arredonda a posição para que pesquisas da mesma zona partilhem a cache.
  const zone = near ? `${near.lat.toFixed(1)},${near.lng.toFixed(1)}` : '';
  const key = `${q.toLowerCase()}|${zone}`;
  const hit = searchCache.get(key);
  if (hit && Date.now() - hit.at < CACHE_TTL_MS) return hit.results;

  // Locais registados pela equipa (painel) vêm primeiro.
  const own = await ownPlaces(q, near).catch(() => [] as Suggestion[]);

  let results: Suggestion[] = [];
  try {
    results = await photonSearch(q, near);
  } catch (err) {
    console.warn('Photon indisponível, a usar Nominatim:', (err as Error).message);
  }
  if (!results.length && q.length >= 3 && config.nominatimUrl) results = await nominatimSearch(q, near);

  // Perto do utilizador primeiro: quem está no Zaire não quer ver Luanda no topo.
  if (near) {
    const local = (r: Suggestion) => (haversineM(near, r) <= NEARBY_M ? 0 : 1);
    results = results.map((r, i) => ({ r, i })).sort((a, b) => local(a.r) - local(b.r) || a.i - b.i).map((x) => x.r);
  }
  results = [...own, ...results];

  const seen = new Set<string>();
  results = results.filter((r) => {
    const id = `${r.title}|${r.subtitle}`;
    return seen.has(id) ? false : (seen.add(id), true);
  });
  if (searchCache.size > 2000) searchCache.clear();
  searchCache.set(key, { at: Date.now(), results });
  return results;
}

/** Morada de um ponto pelo Photon (o mesmo serviço da pesquisa). */
async function photonReverse(p: LatLng): Promise<string | null> {
  const params = new URLSearchParams({ lat: String(p.lat), lon: String(p.lng), limit: '1' });
  const data = await getJson(`${PHOTON_URL}/reverse?${params}`);
  const f = (data.features ?? [])[0]?.properties;
  if (!f) return null;
  const street = [f.street ?? (f.osm_key === 'highway' ? f.name : ''), f.housenumber].filter(Boolean).join(' ');
  const parts = uniq([f.osm_key === 'highway' ? '' : f.name, street, f.district ?? f.locality ?? f.city]);
  return parts.slice(0, 2).join(', ') || null;
}

/** Bairro/município e província de um ponto (vazios se o serviço não souber). */
export async function regionOf(p: LatLng): Promise<{ zone: string; province: string }> {
  try {
    const params = new URLSearchParams({ lat: String(p.lat), lon: String(p.lng), limit: '1' });
    const f = ((await getJson(`${PHOTON_URL}/reverse?${params}`)).features ?? [])[0]?.properties ?? {};
    return {
      zone: String(f.district ?? f.locality ?? f.city ?? f.county ?? ''),
      province: String(f.state ?? '').replace(/^Província d[eoa] /i, ''),
    };
  } catch {
    return { zone: '', province: '' };
  }
}

export async function reverseGeocode(p: LatLng): Promise<Place> {
  try {
    const address = await photonReverse(p);
    if (address) return { address, ...p };
  } catch {
    // tenta o Nominatim, se estiver configurado
  }
  if (!config.nominatimUrl) return { address: 'Local no mapa', ...p };
  try {
    const params = new URLSearchParams({
      format: 'jsonv2',
      lat: String(p.lat),
      lon: String(p.lng),
      zoom: '18',
      addressdetails: '1',
    });
    const item = await getJson(`${config.nominatimUrl}/reverse?${params}`);
    if (item?.error) throw new Error(item.error);
    return { address: shortAddress(item) || 'Local no mapa', ...p };
  } catch {
    return { address: 'Local no mapa', ...p };
  }
}

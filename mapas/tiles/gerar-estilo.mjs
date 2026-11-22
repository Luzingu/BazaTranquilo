// Gera o estilo do mapa do Bazá (tema claro da Protomaps, nomes em português).
import { layers, namedFlavor } from '@protomaps/basemaps';
import { writeFileSync } from 'node:fs';
const style = {
  version: 8,
  name: 'Bazá',
  glyphs: '{fontstack}/{range}.pbf',
  sprite: '{style}',
  sources: {
    protomaps: {
      type: 'vector',
      url: 'pmtiles://{angola}',
      attribution: '© OpenStreetMap · Protomaps',
    },
  },
  layers: layers('protomaps', namedFlavor('light'), { lang: 'pt' }),
};

// ── Mapa mais vivo ──────────────────────────────────────────────────────────
// O tema original só mostra alguns tipos de locais e com letra muito pequena.
// Aqui passam a aparecer todos os locais com nome (bancos, farmácias, igrejas,
// mercados, hotéis, bombas…), um nível de ampliação mais cedo, e as ruas
// pequenas ganham nome mais cedo. Os tipos sem ícone próprio levam um ponto.
const pois = style.layers.find((l) => l.id === 'pois');
pois.filter = ['all', ['has', 'name'], ['>=', ['zoom'], ['-', ['get', 'min_zoom'], 1]]];
pois.minzoom = 13;
pois.layout['icon-image'] = [
  'coalesce',
  ['image', ['match', ['get', 'kind'], 'station', 'train_station', ['get', 'kind']]],
  ['image', 'townspot'],
];
pois.layout['text-size'] = ['interpolate', ['linear'], ['zoom'], 13, 11, 16, 12, 19, 15];
pois.layout['text-optional'] = false;
pois.layout['symbol-sort-key'] = ['get', 'min_zoom']; // os mais importantes primeiro
const cores = pois.paint['text-color'];
cores[cores.length - 1] = '#5b6472'; // restantes tipos: cinzento legível (era quase invisível)
pois.paint['text-halo-color'] = '#ffffff';
pois.paint['text-halo-width'] = 1.2;
const ruas = style.layers.find((l) => l.id === 'roads_labels_minor');
if (ruas) ruas.minzoom = 14;

writeFileSync(process.argv[2], JSON.stringify(style));
console.log('camadas:', style.layers.length);

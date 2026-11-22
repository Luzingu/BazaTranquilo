#!/bin/sh
# Descarrega e prepara os dados dos mapas de Angola. Correr na 1.ª instalação e
# sempre que se quiser actualizar os mapas (por exemplo, uma vez por mês):
#
#   ./preparar.sh && docker compose up -d --force-recreate
#
# Precisa de Docker, curl e zstd (apt install zstd / brew install zstd) e de
# cerca de 2 GB livres. Demora 10 a 30 minutos, quase
# tudo em descargas (cerca de 800 MB).
set -eu
command -v zstd >/dev/null || { echo 'Falta o programa zstd (apt install zstd / brew install zstd).'; exit 1; }
cd "$(dirname "$0")"
mkdir -p dados
D="$PWD/dados"

# Limites de Angola: oeste, sul, leste, norte.
BBOX="11.4,-18.2,24.2,-4.2"
PHOTON_VERSION="1.3.0"
# Região da base de pesquisa que contém Angola (só as moradas de Angola são importadas).
PHOTON_REGIONS="central-africa"

echo "1/4  Estradas de Angola (Geofabrik)…"
curl -fL -o "$D/angola-latest.osm.pbf.novo" https://download.geofabrik.de/africa/angola-latest.osm.pbf
mv "$D/angola-latest.osm.pbf.novo" "$D/angola-latest.osm.pbf"

echo "2/4  Rotas (OSRM)…"
rm -rf "$D/osrm.novo" && mkdir -p "$D/osrm.novo"
cp "$D/angola-latest.osm.pbf" "$D/osrm.novo/"
OSRM="docker run --rm -v $D/osrm.novo:/data ghcr.io/project-osrm/osrm-backend:latest"
$OSRM osrm-extract -p /opt/car.lua /data/angola-latest.osm.pbf
$OSRM osrm-partition /data/angola-latest.osrm
$OSRM osrm-customize /data/angola-latest.osrm
rm "$D/osrm.novo/angola-latest.osm.pbf"
rm -rf "$D/osrm" && mv "$D/osrm.novo" "$D/osrm"

echo "3/4  Imagens do mapa (Protomaps)…"
BUILD=$(curl -fsL https://build-metadata.protomaps.dev/builds.json | tr ',' '\n' | grep -o '[0-9]\{8\}\.pmtiles' | tail -n 1)
docker run --rm -v "$D":/dados protomaps/go-pmtiles extract "https://build.protomaps.com/$BUILD" /dados/angola.pmtiles.novo --bbox="$BBOX" --maxzoom=15
mv "$D/angola.pmtiles.novo" "$D/angola.pmtiles"

echo "4/4  Pesquisa de moradas (Photon)…"
[ -f "$D/photon.jar" ] || curl -fL -o "$D/photon.jar" "https://github.com/komoot/photon/releases/download/$PHOTON_VERSION/photon-$PHOTON_VERSION.jar"
rm -rf "$D/photon.novo" && mkdir -p "$D/photon.novo"
for r in $PHOTON_REGIONS; do
  curl -fL -o "$D/photon-dump-$r.jsonl.zst" "https://download1.graphhopper.com/public/africa/$r/photon-dump-$r-1.0-latest.jsonl.zst"
done
# O ficheiro vem comprimido (zstd); o Photon lê-o já descomprimido, pela entrada.
for r in $PHOTON_REGIONS; do
  zstd -dc "$D/photon-dump-$r.jsonl.zst" | docker run --rm -i -v "$D":/dados -w /dados/photon.novo eclipse-temurin:21-jre \
    java -Xmx1g -jar /dados/photon.jar import -import-file - -country-codes ao -languages pt,en,fr
done
rm -rf "$D/photon" && mv "$D/photon.novo" "$D/photon"

echo "Pronto. Arranque com:  docker compose up -d"

#!/bin/bash
# Envia uma CORRECÇÃO (Shorebird) a uma versão do Bazá já publicada na loja, sem nova versão na loja (2026-11-26).
#
#   bash app/tools/publicar_correcao.sh [percentagem] [commit]     (por omissão: 100, HEAD)
#
# Vai para a versão do `version:` do pubspec.yaml DESSE commit (compilada com compilar_loja.sh). Os telemóveis
# descarregam-na em segundo plano e usam-na na abertura seguinte. ⛔ Só código Dart: permissões, plugins, ícone,
# AndroidManifest e versão do Flutter → o Shorebird recusa (vai à loja). ⛔ Não subir o `version:` para uma correcção.
set -euo pipefail
RAIZ=/var/www/BazaTranquilo
PERC=${1:-100}; COMMIT=${2:-HEAD}; API=${API_URL:-https://bazatranquilo.com}
COMMIT=$(git -C "$RAIZ" rev-parse --verify "$COMMIT^{commit}")  # fixa o commit já: o HEAD pode avançar durante a compilação
[[ "$PERC" =~ ^[0-9]+(\.[0-9]{1,2})?$ ]] && awk "BEGIN{exit !($PERC>0 && $PERC<=100)}" || { echo "Percentagem inválida: $PERC"; exit 1; }
git -C "$RAIZ" cat-file -e "$COMMIT:app/shorebird.yaml" 2>/dev/null || { echo "O commit não tem app/shorebird.yaml — o app não está ligado ao Shorebird nesse commit."; exit 1; }
VERSAO=$(git -C "$RAIZ" show "$COMMIT:app/pubspec.yaml" | sed -n 's/^version:[[:space:]]*//p' | tr -d '[:space:]')
NOME=${VERSAO%%+*}
echo "Correcção para o Bazá $VERSAO · $PERC % · commit $(git -C "$RAIZ" rev-parse --short "$COMMIT")"
export JAVA_HOME=/opt/jdk-17.0.2 ANDROID_HOME=/opt/android-sdk PATH=/root/.shorebird/bin:/opt/flutter/bin:$PATH
[ -n "${SHOREBIRD_TOKEN:-}" ] || { [ -f /root/my_secrets/apps_flutter/shorebird_token ] && export SHOREBIRD_TOKEN=$(cat /root/my_secrets/apps_flutter/shorebird_token); }
DEST=/tmp/correcao_baza_$(date +%Y%m%d%H%M%S)
git -C "$RAIZ" worktree prune
git -C "$RAIZ" worktree add --detach "$DEST" "$COMMIT" >/dev/null
trap 'git -C "$RAIZ" worktree remove --force "$DEST" >/dev/null 2>&1 || true' EXIT
cp "$RAIZ/app/android/key.properties" "$DEST/app/android/key.properties"
cp "$RAIZ/app/android/app/baza-upload.jks" "$DEST/app/android/app/baza-upload.jks"
cd "$DEST/app"
# os MESMOS dart-define da versão publicada (o Shorebird recusa valores diferentes)
shorebird patch android --release-version="$VERSAO" --track stable --rollout "$PERC" --dart-define=API_URL="$API" --dart-define=APP_VERSAO="$NOME"
echo "Correcção publicada. Ver e controlar: https://console.shorebird.dev"

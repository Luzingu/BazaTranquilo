#!/bin/bash
# Compila o app Bazá para a LOJA a partir de um commit FIXO, com Shorebird e a versão do pubspec.yaml (2026-11-26).
#
#   bash app/tools/compilar_loja.sh [appbundle|apk|--so-versao] [commit]     (por omissão: appbundle, HEAD)
#
# - Versão: `version:` do pubspec.yaml desse commit → --dart-define=APP_VERSAO (comparada com site/app-versao.json).
#   ⛔ Cada envio à loja exige o número depois do «+» maior.
# - Shorebird: com app/shorebird.yaml no commit, `shorebird release android` — a versão fica registada e passa a
#   poder receber CORRECÇÕES sem loja (app/tools/publicar_correcao.sh). ⛔ Sem Shorebird nunca recebe correcções.
# - Commit fixo (git worktree): o trabalho por commitar NÃO entra. Os ficheiros secretos (fora do git) são copiados
#   para a cópia: android/key.properties e android/app/baza-upload.jks.
# - API: https://bazatranquilo.com (API_URL=… para outro servidor).
set -euo pipefail
RAIZ=/var/www/BazaTranquilo
ALVO=${1:-appbundle}; COMMIT=${2:-HEAD}; API=${API_URL:-https://bazatranquilo.com}
COMMIT=$(git -C "$RAIZ" rev-parse --verify "$COMMIT^{commit}")  # fixa o commit já: o HEAD pode avançar durante a compilação
VERSAO=$(git -C "$RAIZ" show "$COMMIT:app/pubspec.yaml" | sed -n 's/^version:[[:space:]]*//p' | tr -d '[:space:]')
NOME=${VERSAO%%+*}; NUMERO=${VERSAO#*+}
[[ "$NOME" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$NUMERO" =~ ^[0-9]+$ ]] || { echo "Versão inválida no pubspec.yaml: '$VERSAO'"; exit 1; }
echo "Bazá · versão $NOME (n.º $NUMERO) · commit $(git -C "$RAIZ" rev-parse --short "$COMMIT") · API $API"
[ "$ALVO" = "--so-versao" ] && exit 0
case "$ALVO" in appbundle|apk) ;; *) echo "Alvo inválido: $ALVO (appbundle|apk)"; exit 1;; esac
EXT=$([ "$ALVO" = appbundle ] && echo aab || echo apk)
SAIDA=${SAIDA:-$RAIZ/app/build/loja}; FINAL="$SAIDA/Baza-$NOME+$NUMERO.$EXT"
[ -e "$FINAL" ] && { echo "Já existe $FINAL — suba a versão no pubspec.yaml (a loja recusa o mesmo número)."; exit 1; }
for f in android/key.properties android/app/baza-upload.jks; do [ -f "$RAIZ/app/$f" ] || { echo "Falta $RAIZ/app/$f (chave de assinatura)"; exit 1; }; done

export JAVA_HOME=/opt/jdk-17.0.2 ANDROID_HOME=/opt/android-sdk PATH=/root/.shorebird/bin:/opt/flutter/bin:$PATH
[ -n "${SHOREBIRD_TOKEN:-}" ] || { [ -f /root/my_secrets/apps_flutter/shorebird_token ] && export SHOREBIRD_TOKEN=$(cat /root/my_secrets/apps_flutter/shorebird_token); }
VERSAO_FLUTTER=$(flutter --version 2>/dev/null | sed -n 's/^Flutter \([0-9.]*\).*/\1/p' | head -1)
DEST=/tmp/compilar_baza_${NOME}_${NUMERO}
rm -rf "$DEST"; git -C "$RAIZ" worktree prune
git -C "$RAIZ" worktree add --detach "$DEST" "$COMMIT" >/dev/null
trap 'git -C "$RAIZ" worktree remove --force "$DEST" >/dev/null 2>&1 || true' EXIT
cp "$RAIZ/app/android/key.properties" "$DEST/app/android/key.properties"
cp "$RAIZ/app/android/app/baza-upload.jks" "$DEST/app/android/app/baza-upload.jks"
cd "$DEST/app"
flutter pub get >/dev/null
if [ -f shorebird.yaml ]; then
  shorebird release android --artifact "$EXT" --flutter-version "$VERSAO_FLUTTER" --dart-define=API_URL="$API" --dart-define=APP_VERSAO="$NOME" --no-tree-shake-icons
else
  echo "Sem shorebird.yaml neste commit: compilação normal (esta versão NÃO poderá receber correcções sem loja)."
  flutter build "$ALVO" --release --dart-define=API_URL="$API" --dart-define=APP_VERSAO="$NOME" --no-tree-shake-icons
fi
if [ "$ALVO" = appbundle ]; then F=build/app/outputs/bundle/release/app-release.aab; else F=build/app/outputs/flutter-apk/app-release.apk; fi
mkdir -p "$SAIDA"; cp "$F" "$FINAL"
echo "Pronto: $FINAL"

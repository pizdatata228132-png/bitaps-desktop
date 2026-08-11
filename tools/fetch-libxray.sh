#!/usr/bin/env bash
# Скачать LibXray.xcframework (Xray-core для iOS/macOS, MIT) из релизов XTLS/libXray
# и разложить в ios/Frameworks/. Запуск: bash tools/fetch-libxray.sh [версия, напр. v26.7.28]
#
# Версия и sha256 ЗАКРЕПЛЕНЫ (аудит M5): по умолчанию никакого «latest» — артефакт тянем
# строго по пину и проверяем хэш до распаковки, как xray в build.yml. Другую версию можно
# передать аргументом — но тогда и хэш спрашиваем с неё же (см. ниже), молча не доверяем.
set -euo pipefail
cd "$(dirname "$0")/.."

# ── ПИН (менять оба значения вместе, хэш — свежего zip с релиза) ──
LIBXRAY_VERSION="v26.7.28"
LIBXRAY_SHA256="07f7ed7697277930e1c517755855950f594f41435b0dfc5917a66eea6278aeb9"  # libxray-apple-cgo.zip

VER="${1:-$LIBXRAY_VERSION}"
DEST=ios/Frameworks
ZIP=/tmp/libxray-apple-cgo.zip
mkdir -p "$DEST"

if [ "$VER" = "$LIBXRAY_VERSION" ]; then
  SHA256="$LIBXRAY_SHA256"
else
  # Непиновая версия — только с ЯВНЫМ хэшем: иначе это снова «доверяй сети», что пин и закрывает.
  SHA256="${LIBXRAY_SHA256_OVERRIDE:-}"
  if [ -z "$SHA256" ]; then
    echo "Для версии $VER задай LIBXRAY_SHA256_OVERRIDE=<sha256 zip> — без хэша не качаю" >&2
    exit 1
  fi
fi

ASSET="https://github.com/XTLS/libXray/releases/download/$VER/libxray-apple-cgo.zip"
echo "libXray $VER"
echo "качаем: $ASSET"
curl -fSL "$ASSET" -o "$ZIP"
# Проверка ДО распаковки: битый/подменённый артефакт не должен попасть в дерево сборки.
if command -v shasum >/dev/null 2>&1; then
  echo "$SHA256  $ZIP" | shasum -a 256 -c -
else
  echo "$SHA256  $ZIP" | sha256sum -c -
fi
unzip -o -q "$ZIP" -d /tmp/libxray-apple
find /tmp/libxray-apple -name "LibXray.xcframework" -maxdepth 3 -type d | head -1 | xargs -I{} cp -R {} "$DEST/"
ls "$DEST/LibXray.xcframework" && echo "OK: $DEST/LibXray.xcframework"
echo "Теперь в Xcode: перетащи $DEST/LibXray.xcframework в таргет PacketTunnel (Embed & Sign)."

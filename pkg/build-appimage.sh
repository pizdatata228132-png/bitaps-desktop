#!/usr/bin/env bash
# Упаковка Linux-сборки Flutter в один файл AppImage (двойной клик → запуск)
set -e

APPDIR=AppDir
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
cp -r build/linux/x64/release/bundle/* "$APPDIR/usr/bin/"

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/bin/lib:$LD_LIBRARY_PATH"
exec "$HERE/usr/bin/bitaps_vpn" "$@"
EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/bitaps.desktop" <<'EOF'
[Desktop Entry]
Name=bitaps VPN
Exec=bitaps_vpn
Icon=bitaps
Type=Application
Categories=Network;
EOF

cp assets/icon.png "$APPDIR/bitaps.png"

# appimagetool закреплён по SHA-256, как и движок xray: «continuous» — подвижная цель, и
# подменённый упаковщик вшил бы чужой код в раздаваемый AppImage. Ломаемся при смене апстрима —
# это и есть точка проверки: обновить хэш осознанно, посмотрев, что поменялось у AppImage.
APPIMAGETOOL_SHA256="95cbe7cce9717fce90c484e34052ee7c7f1d7635b33c12525b4776826a7d29b6"
wget -q "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" -O appimagetool
echo "$APPIMAGETOOL_SHA256  appimagetool" | sha256sum -c -
chmod +x appimagetool
ARCH=x86_64 ./appimagetool --appimage-extract-and-run "$APPDIR" bitaps-x86_64.AppImage

ls -la bitaps-x86_64.AppImage

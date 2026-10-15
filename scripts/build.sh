#!/bin/bash
# Compila Eco y arma Eco.app. Con --install la deja en ~/Applications y la abre.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Eco
BIN_DIR=$(swift build -c release --show-bin-path)
APP=build/Eco.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Eco" "$APP/Contents/MacOS/Eco"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ícono de la app: se dibuja con el mismo código de la app (estilo oscuro, el que viene por defecto).
ICONSET=$(mktemp -d)/AppIcon.iconset
"$BIN_DIR/Eco" --render-iconset "$ICONSET" dark
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

./scripts/signing.sh sign "$APP"
echo "Listo: $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x Eco 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Eco.app"
  cp -R "$APP" "$HOME/Applications/Eco.app"
  open "$HOME/Applications/Eco.app"
  echo "Instalada en ~/Applications/Eco.app"
fi

#!/bin/bash
# Firma Eco con un certificado local fijo, guardado en un llavero propio.
# Así macOS reconoce la app como la misma en cada compilación y no vuelve a pedir los permisos.
set -euo pipefail

IDENTITY="Eco Local Signing"
KEYCHAIN="$HOME/Library/Keychains/eco-signing.keychain-db"
KEYCHAIN_PASSWORD="eco-local-signing"
OPENSSL=/usr/bin/openssl

create_identity() {
  local tmp
  tmp=$(mktemp -d)
  cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 7300 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/cert.cnf" 2>/dev/null
  "$OPENSSL" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/eco.p12" -passout pass:"$KEYCHAIN_PASSWORD" -name "$IDENTITY" 2>/dev/null

  # Crear el llavero sin dejarlo en la lista de búsqueda del usuario.
  local previous
  previous=$(security list-keychains -d user | tr -d '"')
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  # shellcheck disable=SC2086
  security list-keychains -d user -s $previous
  security set-keychain-settings "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security import "$tmp/eco.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
  rm -rf "$tmp"
}

sign() {
  local app="$1"
  [ -f "$KEYCHAIN" ] || create_identity
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  if codesign --force --deep --timestamp=none --keychain "$KEYCHAIN" --sign "$IDENTITY" "$app" 2>/dev/null; then
    echo "Firmada con \"$IDENTITY\"."
  else
    echo "No se pudo usar el certificado local, se firma sin certificado (macOS pedirá los permisos de nuevo)." >&2
    codesign --force --deep --sign - "$app"
  fi
}

case "${1:-}" in
  sign) sign "$2" ;;
  *) echo "Uso: $0 sign <ruta a Eco.app>" >&2; exit 1 ;;
esac

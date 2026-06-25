#!/usr/bin/env bash
# gen-certs.sh — dev mTLS material for Chain Bridge.
#
# Generates a local dev CA, the Chain Bridge server cert, and one client cert
# per SPIFFE identity from the ServiceRole table
# (gridtokenx-blockchain-core/src/auth.rs). The SPIFFE URI rides in the client
# cert's URI SAN; Chain Bridge's PeerCertLayer extracts it to derive the
# caller's ServiceRole.
#
# This static CA is a dev stand-in for SPIRE-issued SVIDs in production.
# ca.key never leaves infra/certs/ and must never be mounted into containers.
#
# Usage: scripts/gen-certs.sh [--force]
#   --force  regenerate everything, even certs that are still valid
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="$ROOT_DIR/infra/certs"
CLIENT_DIR="$CERT_DIR/clients"
DAYS_CA=3650
DAYS_LEAF=825
RENEW_WINDOW_SECS=2592000 # regenerate when < 30 days left
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# Prefer Homebrew OpenSSL 3.x (macOS system LibreSSL lacks -addext)
OPENSSL=openssl
if [[ -x /opt/homebrew/opt/openssl@3/bin/openssl ]]; then
    OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl
fi
if ! "$OPENSSL" version | grep -q "OpenSSL 3"; then
    echo "ERROR: need OpenSSL 3.x for -addext (found: $("$OPENSSL" version)). brew install openssl@3" >&2
    exit 1
fi

# Docker bind-mounts of formerly-nonexistent files leave directory artifacts
for stray in "$CERT_DIR/server.crt" "$CERT_DIR/server.key"; do
    if [[ -d "$stray" ]]; then
        echo "Removing stray directory artifact: $stray"
        rm -rf "$stray"
    fi
done

mkdir -p "$CLIENT_DIR"

# usable <cert> — true when cert exists and has > RENEW_WINDOW_SECS left
usable() {
    [[ $FORCE -eq 0 && -f "$1" ]] && "$OPENSSL" x509 -in "$1" -checkend "$RENEW_WINDOW_SECS" >/dev/null 2>&1
}

# --- CA ---------------------------------------------------------------------
if usable "$CERT_DIR/ca.crt"; then
    echo "ca.crt: still valid, skipping (use --force to regenerate)"
else
    echo "Generating dev CA"
    "$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$CERT_DIR/ca.key"
    "$OPENSSL" req -new -x509 -key "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" \
        -days "$DAYS_CA" -sha256 \
        -subj "/O=GridTokenX Dev/CN=GridTokenX Dev CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"
    # New CA invalidates every existing leaf
    rm -f "$CERT_DIR/server.crt" "$CERT_DIR/server.key" "$CLIENT_DIR"/*.crt "$CLIENT_DIR"/*.key
fi

# issue_leaf <crt> <key> <subject-CN> <SAN> <EKU>
issue_leaf() {
    local crt="$1" key="$2" cn="$3" san="$4" eku="$5"
    local csr
    csr="$(mktemp)"
    "$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$key"
    "$OPENSSL" req -new -key "$key" -out "$csr" -subj "/O=GridTokenX Dev/CN=$cn"
    "$OPENSSL" x509 -req -in "$csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
        -CAcreateserial -out "$crt" -days "$DAYS_LEAF" -sha256 \
        -extfile <(printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=%s\nsubjectAltName=%s\n' "$eku" "$san")
    rm -f "$csr"
    chmod 600 "$key"
}

# --- Chain Bridge server cert -------------------------------------------------
if usable "$CERT_DIR/server.crt"; then
    echo "server.crt: still valid, skipping"
else
    echo "Generating Chain Bridge server cert"
    issue_leaf "$CERT_DIR/server.crt" "$CERT_DIR/server.key" "chain-bridge" \
        "DNS:localhost,DNS:chain-bridge,IP:127.0.0.1" "serverAuth"
fi

# --- Aggregator Bridge IoT-gateway server cert --------------------------------
# Serves TLS on the IoT gateway (:4010) so meter telemetry (DLMS/COSEM REST) is
# encrypted in transit. Separate from the Chain Bridge cert so its SAN can carry
# the aggregator-bridge hostname without touching chain-bridge mTLS.
if usable "$CERT_DIR/aggregator-bridge.crt"; then
    echo "aggregator-bridge.crt: still valid, skipping"
else
    echo "Generating Aggregator Bridge IoT-gateway server cert"
    issue_leaf "$CERT_DIR/aggregator-bridge.crt" "$CERT_DIR/aggregator-bridge.key" \
        "aggregator-bridge" \
        "DNS:localhost,DNS:aggregator-bridge,IP:127.0.0.1" "serverAuth"
fi

# --- Client certs (one per SPIFFE identity; auth.rs ServiceRole table) --------
# filename:spiffe-uri
IDENTITIES=(
    "apisix:spiffe://gridtokenx.th/prod/apisix"
    "iam-service:spiffe://gridtokenx.th/prod/iam-service"
    "trading-service-api:spiffe://gridtokenx.th/prod/trading-service/api"
    "trading-service-matcher:spiffe://gridtokenx.th/prod/trading-service/matcher"
    "aggregator-bridge:spiffe://gridtokenx.th/prod/aggregator-bridge"
    "smartmeter-simulator:spiffe://gridtokenx.th/prod/smartmeter-simulator"
    "settlement-service:spiffe://gridtokenx.th/prod/settlement-service"
    "reporting-service:spiffe://gridtokenx.th/prod/reporting-service"
    "admin:spiffe://gridtokenx.th/prod/admin"
)

for entry in "${IDENTITIES[@]}"; do
    name="${entry%%:*}"
    uri="${entry#*:}"
    crt="$CLIENT_DIR/$name.crt"
    if usable "$crt"; then
        echo "clients/$name.crt: still valid, skipping"
    else
        echo "Generating client cert: $name ($uri)"
        issue_leaf "$crt" "$CLIENT_DIR/$name.key" "$name" "URI:$uri" "clientAuth"
    fi
done

chmod 600 "$CERT_DIR/ca.key" 2>/dev/null || true

echo
echo "Done. Layout:"
echo "  $CERT_DIR/ca.crt              — trust anchor (mount into clients + server)"
echo "  $CERT_DIR/ca.key              — dev CA key (NEVER mount into containers)"
echo "  $CERT_DIR/server.{crt,key}    — Chain Bridge server (SAN: localhost, chain-bridge, 127.0.0.1)"
echo "  $CERT_DIR/aggregator-bridge.{crt,key} — Aggregator Bridge IoT gateway (SAN: localhost, aggregator-bridge, 127.0.0.1)"
echo "  $CLIENT_DIR/<svc>.{crt,key}   — per-SPIFFE-identity client certs"

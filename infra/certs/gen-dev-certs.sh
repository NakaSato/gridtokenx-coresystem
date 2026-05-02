#!/bin/bash
set -e

# Configuration
CERT_DIR="infra/certs"
CA_KEY="$CERT_DIR/ca.key"
CA_CRT="$CERT_DIR/ca.crt"
DAYS=3650

mkdir -p "$CERT_DIR"

echo "Creating Certificate Authority..."
openssl genrsa -out "$CA_KEY" 4096
openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days $DAYS -out "$CA_CRT" \
  -subj "/C=TH/ST=Bangkok/L=Bangkok/O=GridTokenX/CN=GridTokenX CA"

# Function to generate a certificate
gen_cert() {
  local name=$1
  local san=$2
  local key="$CERT_DIR/$name.key"
  local csr="$CERT_DIR/$name.csr"
  local crt="$CERT_DIR/$name.crt"
  local ext="$CERT_DIR/$name.ext"

  echo "Generating certificate for $name..."

  openssl genrsa -out "$key" 2048
  
  # Create extension file for SAN
  echo "subjectAltName = $san" > "$ext"

  openssl req -new -key "$key" -out "$csr" -subj "/C=TH/ST=Bangkok/L=Bangkok/O=GridTokenX/CN=$name"

  openssl x509 -req -in "$csr" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$crt" -days $DAYS -sha256 -extfile "$ext"

  rm "$csr" "$ext"
}

# 1. Server Certificate
echo "Generating Server Certificate..."
gen_cert "server" "DNS:chain-bridge,DNS:noti-service,DNS:localhost,IP:127.0.0.1"

# 2. Client Certificates with SPIFFE SANs
# Note: SPIFFE SAN is URI:spiffe://...
echo "Generating Client Certificates..."

gen_cert "oracle-bridge-client"    "URI:spiffe://gridtokenx.th/prod/oracle-bridge"
gen_cert "trading-matcher-client"  "URI:spiffe://gridtokenx.th/prod/trading-service/matcher"
gen_cert "trading-api-client"      "URI:spiffe://gridtokenx.th/prod/trading-service/api"
gen_cert "iam-service-client"      "URI:spiffe://gridtokenx.th/prod/iam-service"
gen_cert "settlement-client"       "URI:spiffe://gridtokenx.th/prod/settlement-service"
gen_cert "admin-client"            "URI:spiffe://gridtokenx.th/prod/admin"

# Generic client for testing if needed
gen_cert "client" "URI:spiffe://gridtokenx.th/prod/generic-client"

echo "✅ Certificates generated in $CERT_DIR"

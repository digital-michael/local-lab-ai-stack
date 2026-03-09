#!/usr/bin/env bash
# scripts/generate-tls.sh — Generate a local self-signed CA and server certificate
#
# Creates:
#   $AI_STACK_DIR/configs/tls/ca.crt         — local CA certificate (trust this in browsers)
#   $AI_STACK_DIR/configs/tls/ca.key         — local CA private key (keep secure)
#   $AI_STACK_DIR/configs/tls/server.crt     — server certificate (signed by local CA)
#   $AI_STACK_DIR/configs/tls/server.key     — server private key
#   $AI_STACK_DIR/configs/tls/server.pem     — server cert + key bundle (for Traefik)
#
# The certificate covers localhost and the hostnames used in Traefik routing.
# Validity: 825 days (max accepted by most browsers for local CAs).
#
# Usage:
#   generate-tls.sh                           # default: localhost + common SANs
#   DOMAIN=home.lan generate-tls.sh          # add *.home.lan SANs
#   generate-tls.sh --force                  # regenerate even if certs exist
#
# After running:
#   1. Trust ca.crt in your OS / browser certificate store
#   2. Restart Traefik: systemctl --user restart traefik.service
#
# Environment:
#   AI_STACK_DIR   Base directory (default: $HOME/ai-stack)
#   DOMAIN         Deploy domain (default: localhost)

set -euo pipefail

AI_STACK_DIR="${AI_STACK_DIR:-$HOME/ai-stack}"
TLS_DIR="$AI_STACK_DIR/configs/tls"
DOMAIN="${DOMAIN:-localhost}"
FORCE=false
VALIDITY_DAYS=825
CA_VALIDITY_DAYS=3650   # 10 years for the local CA

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --help|-h)
            echo "Usage: $(basename "$0") [--force]"
            echo "  --force  Regenerate certificates even if they already exist"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

if ! command -v openssl &>/dev/null; then
    echo "ERROR: openssl is required. Install with: sudo dnf install -y openssl" >&2
    exit 1
fi

mkdir -p "$TLS_DIR"

if [[ -f "$TLS_DIR/server.crt" ]] && [[ "$FORCE" == "false" ]]; then
    echo "Certificates already exist in $TLS_DIR"
    echo "Use --force to regenerate."
    echo ""
    echo "Files:"
    ls -lh "$TLS_DIR/"
    exit 0
fi

# ---------------------------------------------------------------------------
# Determine SANs based on domain
# ---------------------------------------------------------------------------

# Always include localhost and 127.0.0.1
SANS="DNS:localhost,DNS:*.localhost,IP:127.0.0.1,IP:::1"

if [[ "$DOMAIN" != "localhost" ]]; then
    SANS="${SANS},DNS:${DOMAIN},DNS:*.${DOMAIN}"

    # Add the specific service subdomains
    for svc in auth webui grafana flowise prometheus; do
        SANS="${SANS},DNS:${svc}.${DOMAIN}"
    done
fi

# Always add the service subdomains for localhost
for svc in auth webui grafana flowise prometheus; do
    SANS="${SANS},DNS:${svc}.localhost"
done

echo "Generating local CA and server certificate"
echo "  TLS_DIR : $TLS_DIR"
echo "  DOMAIN  : $DOMAIN"
echo "  SANs    : $SANS"
echo "  Validity: $VALIDITY_DAYS days (CA: $CA_VALIDITY_DAYS days)"
echo ""

# ---------------------------------------------------------------------------
# Step 1 — Generate local CA key and certificate
# ---------------------------------------------------------------------------

echo "[1/4] Generating local CA key..."
openssl genrsa -out "$TLS_DIR/ca.key" 4096
chmod 600 "$TLS_DIR/ca.key"

echo "[2/4] Generating local CA certificate..."
openssl req -new -x509 \
    -key "$TLS_DIR/ca.key" \
    -out "$TLS_DIR/ca.crt" \
    -days "$CA_VALIDITY_DAYS" \
    -subj "/CN=AI Stack Local CA/O=AI Stack/C=US" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"

# ---------------------------------------------------------------------------
# Step 2 — Generate server key and CSR
# ---------------------------------------------------------------------------

echo "[3/4] Generating server key and CSR..."
openssl genrsa -out "$TLS_DIR/server.key" 4096
chmod 600 "$TLS_DIR/server.key"

# Generate CSR
openssl req -new \
    -key "$TLS_DIR/server.key" \
    -out "$TLS_DIR/server.csr" \
    -subj "/CN=${DOMAIN}/O=AI Stack/C=US"

# ---------------------------------------------------------------------------
# Step 3 — Sign server certificate with local CA
# ---------------------------------------------------------------------------

echo "[4/4] Signing server certificate with local CA..."

# Write the SAN extension file
cat > "$TLS_DIR/server_ext.cnf" <<EOF
[v3_req]
subjectAltName = ${SANS}
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
basicConstraints = CA:FALSE
EOF

openssl x509 -req \
    -in "$TLS_DIR/server.csr" \
    -CA "$TLS_DIR/ca.crt" \
    -CAkey "$TLS_DIR/ca.key" \
    -CAcreateserial \
    -out "$TLS_DIR/server.crt" \
    -days "$VALIDITY_DAYS" \
    -extensions v3_req \
    -extfile "$TLS_DIR/server_ext.cnf"

# Bundle cert + key for tools that expect a PEM bundle
cat "$TLS_DIR/server.crt" "$TLS_DIR/server.key" > "$TLS_DIR/server.pem"
chmod 600 "$TLS_DIR/server.pem"

# Cleanup temporaries
rm -f "$TLS_DIR/server.csr" "$TLS_DIR/server_ext.cnf" "$TLS_DIR/ca.srl"

# ---------------------------------------------------------------------------
# Result summary
# ---------------------------------------------------------------------------

echo ""
echo "TLS certificates generated successfully:"
ls -lh "$TLS_DIR/"

echo ""
echo "Certificate details:"
openssl x509 -noout -subject -issuer -dates -ext subjectAltName \
    -in "$TLS_DIR/server.crt"

echo ""
echo "Next steps:"
echo ""
echo "  1. Trust the local CA in your browser / OS:"
echo "     Linux: sudo cp $TLS_DIR/ca.crt /etc/pki/ca-trust/source/anchors/"
echo "            sudo update-ca-trust"
echo "     macOS: sudo security add-trusted-cert -d -r trustRoot \\"
echo "                -k /Library/Keychains/System.keychain $TLS_DIR/ca.crt"
echo ""
echo "  2. Verify the Traefik TLS dynamic config references server.crt and server.key:"
echo "     cat $AI_STACK_DIR/configs/traefik/dynamic/tls.yaml"
echo ""
echo "  3. Restart Traefik to load the new certificate:"
echo "     systemctl --user restart traefik.service"

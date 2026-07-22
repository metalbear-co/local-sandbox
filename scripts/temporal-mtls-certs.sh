#!/usr/bin/env bash
# Generates a throwaway CA plus server and client certificates for the Temporal
# mTLS test front (task temporal:mtls:deploy).
#
# The server certificate carries the SAN of the in-cluster nginx service so the
# operator's rustls client can verify it; "localhost" is included so `openssl
# s_client` checks through a port-forward also verify.
#
# Everything is written to .certs/temporal-mtls/ (gitignored). Re-running
# regenerates the whole set, so certs and secrets stay consistent as long as
# temporal:mtls:deploy is used to apply them.
set -euo pipefail

OUT_DIR="${1:-$(git rev-parse --show-toplevel)/.certs/temporal-mtls}"
SERVICE_DNS="temporal-mtls.temporal.svc.cluster.local"
DAYS=30

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

cat > ca.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
CN = temporal-mtls-test-ca
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
  -keyout ca.key -out ca.crt -config ca.cnf

cat > server.ext <<EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${SERVICE_DNS}, DNS:localhost
EOF
openssl req -newkey rsa:2048 -nodes \
  -keyout server.key -out server.csr -subj "/CN=${SERVICE_DNS}"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days "$DAYS" -out server.crt -extfile server.ext

cat > client.ext <<'EOF'
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EOF
openssl req -newkey rsa:2048 -nodes \
  -keyout client.key -out client.csr -subj "/CN=mirrord-operator"
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days "$DAYS" -out client.crt -extfile client.ext

rm -f server.csr client.csr ca.cnf server.ext client.ext ca.srl
echo "Temporal mTLS test certs written to $OUT_DIR"

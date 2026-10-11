#!/bin/sh
# Creates, on the first start, a small certificate authority and a certificate
# for Trino, so that tokens only ever travel to Trino over https.
# The CA's private key is deleted once Trino's certificate is signed.
set -eu
cd /certs
if [ -s trino.pem ] && [ -s ca.crt ]; then
  echo "certificates already present"
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 825 -sha256 \
  -subj "/CN=akko-sandbox demo CA" -keyout ca.key -out ca.crt \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

openssl req -newkey rsa:2048 -nodes -sha256 -subj "/CN=trino" \
  -keyout trino.key -out trino.csr

cat > trino.ext <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:trino,DNS:localhost,IP:127.0.0.1
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
openssl x509 -req -in trino.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 825 -sha256 -extfile trino.ext -out trino.crt

# Trino reads its key and certificate from one PEM file.
cat trino.key trino.crt > trino.pem
rm -f ca.key ca.srl trino.key trino.csr trino.ext

# Trino runs as uid 1000; everyone else only needs the public CA.
chown 1000:1000 trino.pem
chmod 0400 trino.pem
chmod 0444 ca.crt trino.crt
echo "certificate authority and Trino certificate created"

#!/bin/sh
# Creates, on the first start, a small certificate authority and certificates
# for Trino and Keycloak, so that tokens only ever travel over https between the
# MCP server, Keycloak's token endpoint and Trino. Also draws the MCP server's
# client secret at Keycloak, at random: none is written in the repository.
# The CA's private key is deleted once the certificates are signed: a volume that
# lacks one of the files, such as one made before the gateway variant, gets them
# all anew.
set -eu
cd /certs
if [ -s trino.pem ] && [ -s keycloak.crt ] && [ -s mcp-client.secret ] \
  && [ -s gateway.pem ] && [ -s gateway-admin.secret ] && [ -s gateway-session.pub ]; then
  echo "certificates already present"
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 825 -sha256 \
  -subj "/CN=akko-sandbox demo CA" -keyout ca.key -out ca.crt \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

sign() { # name, subjectAltName
  openssl req -newkey rsa:2048 -nodes -sha256 -subj "/CN=$1" -keyout "$1.key" -out "$1.csr"
  cat > "$1.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$2
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
  openssl x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 825 -sha256 -extfile "$1.ext" -out "$1.crt"
  rm -f "$1.csr" "$1.ext"
}
sign trino "DNS:trino,DNS:localhost,IP:127.0.0.1"
sign keycloak "DNS:keycloak,DNS:localhost,IP:127.0.0.1"
# Used only by the Trino Gateway variant (gateway/compose.gateway.yaml).
sign gateway "DNS:gateway,DNS:localhost,IP:127.0.0.1"

# The MCP server's client secret at Keycloak, read by both at start.
openssl rand -hex 24 > mcp-client.secret
# The gateway variant only: the password of the gateway's admin account, and
# the key pair that signs its login sessions.
openssl rand -hex 24 > gateway-admin.secret
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out gateway-session.key
openssl pkey -in gateway-session.key -pubout -out gateway-session.pub

# Trino reads its key and certificate from one PEM file.
cat trino.key trino.crt > trino.pem
cat gateway.key gateway.crt > gateway.pem
rm -f ca.key ca.srl trino.key gateway.key gateway.crt

# Trino and Keycloak run as uid 1000, the MCP server as uid 10001: the secret is
# readable by both, which a real deployment would keep in a secret store instead.
# The gateway's admin password is not readable by the MCP server.
chown 1000:1000 trino.pem gateway.pem keycloak.key keycloak.crt \
  gateway-admin.secret gateway-session.key gateway-session.pub
chmod 0400 trino.pem gateway.pem keycloak.key gateway-admin.secret gateway-session.key
chmod 0444 ca.crt trino.crt keycloak.crt mcp-client.secret gateway-session.pub
echo "certificate authority, Trino, Keycloak and gateway certificates, secrets created"

#!/usr/bin/env fish
# Makes the TLS certificate of the local development server: https://localhost:8643.
# The official Bitwarden app accepts HTTPS servers only, and it must trust the certificate.
#
# Output in .local-dependencies/dev-tls (never tracked):
#   ca.pem             a certificate authority limited to "localhost" and 127.0.0.1
#   localhost.pem      the server certificate, signed by that authority
#   localhost-key.pem  the server key
# The key of the authority is deleted at once, so nobody can sign another certificate with it.
set -l root (path resolve (path dirname (status filename))/../..)
set -l directory "$root/.local-dependencies/dev-tls"
set -l openssl /usr/bin/openssl

if test -e "$directory/localhost.pem"
    echo "The certificate exists. Remove $directory to make a new one."
    exit 0
end
mkdir -p "$directory"; or exit 1
cd "$directory"; or exit 1

printf '%s\n' \
    '[req]' 'distinguished_name = name' 'prompt = no' 'x509_extensions = authority' \
    '[name]' 'CN = PassVault development (localhost only)' \
    '[authority]' \
    'basicConstraints = critical, CA:TRUE, pathlen:0' \
    'keyUsage = critical, keyCertSign' \
    'subjectKeyIdentifier = hash' \
    'nameConstraints = critical, permitted;DNS:localhost, permitted;IP:127.0.0.1/255.255.255.255' \
    > ca.cnf; or exit 1
printf '%s\n' \
    '[req]' 'distinguished_name = name' 'prompt = no' \
    '[name]' 'CN = localhost' \
    '[server]' \
    'basicConstraints = critical, CA:FALSE' \
    'keyUsage = critical, digitalSignature' \
    'extendedKeyUsage = serverAuth' \
    'subjectAltName = DNS:localhost, IP:127.0.0.1' \
    'authorityKeyIdentifier = keyid' \
    > server.cnf; or exit 1

$openssl ecparam -name prime256v1 -genkey -noout -out ca-key.pem; or exit 1
$openssl req -x509 -new -key ca-key.pem -sha256 -days 365 -config ca.cnf -out ca.pem; or exit 1
$openssl ecparam -name prime256v1 -genkey -noout -out localhost-key.pem; or exit 1
$openssl req -new -key localhost-key.pem -config server.cnf -out server.csr; or exit 1
$openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -sha256 -days 365 \
    -extfile server.cnf -extensions server -out localhost.pem 2>/dev/null; or exit 1
rm -f ca-key.pem ca.srl server.csr ca.cnf server.cnf; or exit 1
chmod 600 localhost-key.pem; or exit 1
$openssl verify -CAfile ca.pem localhost.pem >/dev/null; or exit 1

echo "Certificate made in $directory"
echo 'To let apps on this Mac trust it, run this yourself (macOS asks for your password):'
echo "  security add-trusted-cert -r trustRoot -p ssl -k ~/Library/Keychains/login.keychain-db $directory/ca.pem"

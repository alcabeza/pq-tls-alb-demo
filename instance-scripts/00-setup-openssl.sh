#!/usr/bin/env bash
# 00 - Make sure an OpenSSL >= 3.5 is available (ML-KEM hybrid groups). Run as root at first boot.
# Recent Amazon Linux 2023 releases ship OpenSSL 3.5; otherwise 3.5.x is built from source into /opt/openssl35.
set -u
DEMO_DIR="${DEMO_DIR:-/opt/pq-alb-demo}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.9}"
ENV_OUT="$DEMO_DIR/openssl.env"

ver_ok() { [ "$(printf '%s\n3.5.0\n' "$1" | sort -V | head -1)" = "3.5.0" ]; }
current() { openssl version 2>/dev/null | awk '{print $2}'; }

echo "== openssl: system version $(current)"
if ! ver_ok "$(current)"; then
  echo "== openssl: trying to update the system package"
  dnf -y --releasever=latest update openssl || true
fi

if ver_ok "$(current)"; then
  echo "OPENSSL_BIN=$(command -v openssl)" > "$ENV_OUT"
  echo "== openssl: using system OpenSSL $(current)"
  exit 0
fi

echo "== openssl: building OpenSSL $OPENSSL_VERSION from source (takes a few minutes)"
dnf -y install gcc make perl-core zlib-devel \
  || dnf -y install gcc make perl perl-FindBin perl-IPC-Cmd perl-Text-Template perl-File-Compare perl-File-Copy perl-Data-Dumper zlib-devel \
  || exit 1
tmp="$(mktemp -d)"
cd "$tmp" || exit 1
curl -fsSL -o openssl.tar.gz \
  "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" || exit 1
tar -xzf openssl.tar.gz
cd "openssl-${OPENSSL_VERSION}" || exit 1
./Configure --prefix=/opt/openssl35 --openssldir=/opt/openssl35/ssl no-docs no-tests \
  "-Wl,-rpath,/opt/openssl35/lib64" "-Wl,-rpath,/opt/openssl35/lib" || exit 1
make -j"$(nproc)" || exit 1
make install_sw || exit 1
echo "OPENSSL_BIN=/opt/openssl35/bin/openssl" > "$ENV_OUT"
/opt/openssl35/bin/openssl version

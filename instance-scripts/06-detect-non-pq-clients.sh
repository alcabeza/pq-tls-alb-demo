#!/usr/bin/env bash
# 06 - Detection instead of blocking: which clients connected WITHOUT a post-quantum key exchange?
#   bash 06-detect-non-pq-clients.sh
#   PQ_PATTERN='mlkem|ml-kem' bash 06-detect-non-pq-clients.sh
# Reads the ALB connection logs, keeps connections to the PQ listeners (PQ_PORT and TLS13_PORT) and counts, per
# client IP: hybrid, classical (handshake completed without ML-KEM) and no TLS (refused or plain TCP probe).
# A connection counts as hybrid when tls_keyexchange matches PQ_PATTERN (case-insensitive, default
# 'mlkem|ml-kem|kyber'). The "classical" column is the list of clients to migrate before you tighten anything.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
load_env

PQ_PATTERN="${PQ_PATTERN:-mlkem|ml-kem|kyber}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
PREFIX="$LOG_PREFIX/AWSLogs/$ACCOUNT/elasticloadbalancing/$AWS_REGION/"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/gz"
aws s3 cp "s3://$LOG_BUCKET/$PREFIX" "$WORK/gz/" --recursive --exclude '*' --include '*conn_log_*.log.gz' --only-show-errors; find "$WORK/gz" -mindepth 2 -name '*.gz' -exec mv -t "$WORK/gz" {} +
if ! ls "$WORK"/gz/*.gz >/dev/null 2>&1; then
  echo "No connection log yet (delivery every ~5 minutes). Run script 03, wait, retry."; exit 3
fi
gunzip -c "$WORK"/gz/*.gz > "$WORK/all.log"

# fields: 2 client_ip, 4 listener_port, 5 tls_protocol, 6 tls_cipher, 13 tls_keyexchange
# Three outcomes per connection to a PQ listener:
#   hybrid     : tls_keyexchange matches PQ_PATTERN
#   classical  : TLS handshake completed WITHOUT ML-KEM (the clients to migrate)
#   no TLS     : no cipher and no key exchange logged ("-"): refused handshake or a plain TCP probe
awk -v p1="$PQ_PORT" -v p2="$TLS13_PORT" -v pat="$PQ_PATTERN" '
  ($4==p1 || $4==p2) {
    k = $2; ips[k] = 1
    if (tolower($13) ~ pat) h[k]++
    else if ($13 == "-" && $6 == "-") f[k]++
    else { c[k]++; why[k] = $5 " / " $13 }
  }
  END {
    printf "%-16s %8s %10s %8s   %s\n", "client_ip", "hybrid", "classical", "no TLS", "last classical (tls / key exchange)"
    for (k in ips) printf "%-16s %8d %10d %8d   %s\n", k, h[k], c[k], f[k], (c[k] ? why[k] : "-")
  }' "$WORK/all.log" | { read -r head; echo "$head"; sort; }

read -r TOTAL HYB CLA NOTLS <<<"$(awk -v p1="$PQ_PORT" -v p2="$TLS13_PORT" -v pat="$PQ_PATTERN" '
  ($4==p1 || $4==p2) { t++; if (tolower($13) ~ pat) h++; else if ($13=="-" && $6=="-") f++; else c++ }
  END { print t+0, h+0, c+0, f+0 }' "$WORK/all.log")"
echo
echo "Connections to PQ listeners: $TOTAL   hybrid: $HYB   classical (completed): $CLA   no TLS (refused or probe): $NOTLS"
if [ "$CLA" -gt 0 ]; then
  echo "The $CLA classical connection(s) are not protected against 'harvest now, decrypt later' even though the policy is PQ."
  echo "The load balancer did not block them, and cannot. Upgrade the client library or TLS terminator."
else
  echo "Every completed handshake used a hybrid exchange."
fi
echo "(Script 03 deliberately produces classical and refused connections: they are expected to appear above.)"

#!/usr/bin/env bash
# 05 - Compare the cost of a new TLS connection: classical vs hybrid post-quantum key exchange.
#   bash 05-benchmark-handshake.sh
#   ITERATIONS=300 WARMUP=20 bash 05-benchmark-handshake.sh
# Each sample = one full `openssl s_client` run (process start + TCP + TLS handshake). The process start cost is
# the same for both cases, so the difference is meaningful; absolute values are not pure handshake times.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
load_env

ITERATIONS="${ITERATIONS:-200}"
WARMUP="${WARMUP:-20}"
OUT="${OUTDIR:-/var/tmp/pq-alb-handshake-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
openssl_ok || { echo "OpenSSL >= 3.5 is required. Run 01-verify-install.sh."; exit 1; }

one() { # port groups -> prints elapsed ms
  local s e
  s=$(date +%s%N)
  timeout 15 "$OPENSSL" s_client -connect "$ALB_DNS:$1" -servername "${SNI_NAME:-pq-demo.example.internal}" \
    -tls1_3 -groups "$2" </dev/null >/dev/null 2>&1
  e=$(date +%s%N)
  awk -v a="$s" -v b="$e" 'BEGIN{printf "%.3f\n", (b-a)/1000000}'
}

echo "Target: $ALB_DNS   iterations: $ITERATIONS   warmup: $WARMUP"
probe "$PQ_PORT" "X25519MLKEM768:X25519";      echo "check: PQ listener negotiates     -> $PROBE_GROUP"
[ "$PROBE_GROUP" = "X25519MLKEM768" ] || { echo "The PQ listener did not negotiate ML-KEM: run script 03 first."; exit 1; }
probe "$CLASSIC_PORT" "X25519MLKEM768:X25519"; echo "check: classical listener negotiates -> $PROBE_GROUP"

for _ in $(seq 1 "$WARMUP"); do one "$PQ_PORT" "X25519MLKEM768:X25519" >/dev/null; one "$CLASSIC_PORT" "X25519" >/dev/null; done

: > "$OUT/pq.txt"; : > "$OUT/classic.txt"
for _ in $(seq 1 "$ITERATIONS"); do        # alternate to cancel out drift
  one "$PQ_PORT" "X25519MLKEM768:X25519" >> "$OUT/pq.txt"
  one "$CLASSIC_PORT" "X25519" >> "$OUT/classic.txt"
done

read -r pm p50 p95 p99 pmax <<<"$(stats < "$OUT/pq.txt")"
read -r cm c50 c95 c99 cmax <<<"$(stats < "$OUT/classic.txt")"
echo
printf '%-34s %8s %8s %8s %8s %8s\n' "case (ms)" mean p50 p95 p99 max
printf '%-34s %8s %8s %8s %8s %8s\n' "classical X25519 (port $CLASSIC_PORT)" "$cm" "$c50" "$c95" "$c99" "$cmax"
printf '%-34s %8s %8s %8s %8s %8s\n' "hybrid X25519MLKEM768 (port $PQ_PORT)" "$pm" "$p50" "$p95" "$p99" "$pmax"
echo
awk -v a="$p50" -v b="$c50" 'BEGIN{ printf "p50 difference: %+.2f ms (ratio %.2fx)\n", a-b, (b>0 ? a/b : 0) }'
awk -v a="$p95" -v b="$c95" 'BEGIN{ printf "p95 difference: %+.2f ms (ratio %.2fx)\n", a-b, (b>0 ? a/b : 0) }'
echo "Raw samples: $OUT/pq.txt and $OUT/classic.txt"

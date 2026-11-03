#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts (not run directly).

DEMO_DIR="${DEMO_DIR:-/opt/pq-alb-demo}"
PASS=0; FAIL=0; WARN=0

load_env() {
  set -a
  # shellcheck disable=SC1091
  [ -r "$DEMO_DIR/demo.env" ] && . "$DEMO_DIR/demo.env"
  # shellcheck disable=SC1091
  [ -r "$DEMO_DIR/openssl.env" ] && . "$DEMO_DIR/openssl.env"
  set +a
  OPENSSL="${OPENSSL_BIN:-openssl}"
}

pass()    { PASS=$((PASS + 1)); echo "[PASS] $1"; }
fail()    { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; [ -n "${2:-}" ] && echo "       $2"; return 0; }
warn()    { WARN=$((WARN + 1)); echo "[WARN] $1"; [ -n "${2:-}" ] && echo "       $2"; return 0; }
section() { echo; echo "== $1 =="; }

# true when the selected OpenSSL is 3.5 or later (needed for ML-KEM hybrid groups)
openssl_ok() {
  local ver
  ver="$("$OPENSSL" version 2>/dev/null | awk '{print $2}')"
  ver="${ver%%-*}"
  [ -n "$ver" ] && [ "$(printf '%s\n3.5.0\n' "$ver" | sort -V | head -1)" = "3.5.0" ]
}

# probe <port> <groups> [tls flag, default -tls1_3]
# Runs one handshake against the load balancer. Sets PROBE_OK (1 handshake completed), PROBE_GROUP
# (negotiated group, "(none)" if unknown) and PROBE_OUT.
probe() {
  local out flag="${3:--tls1_3}" gopt=()
  [ -n "$2" ] && gopt=(-groups "$2")
  out="$(timeout 15 "$OPENSSL" s_client -connect "$ALB_DNS:$1" -servername "${SNI_NAME:-pq-demo.example.internal}" \
          "$flag" "${gopt[@]}" </dev/null 2>&1)"
  PROBE_OK=0
  if printf '%s\n' "$out" | grep -q 'Cipher is' && ! printf '%s\n' "$out" | grep -q 'Cipher is (NONE)'; then PROBE_OK=1; fi
  # OpenSSL prints the group as "Negotiated TLS1.3 group: X" (hybrid groups) or "Server/Peer Temp Key: X, n bits"
  # (classical groups), depending on the version. Both forms are accepted.
  PROBE_GROUP="$(printf '%s\n' "$out" | sed -nE 's/^Negotiated TLS1\.3 group: *//p; s/^(Server|Peer) Temp Key: *([A-Za-z0-9_-]+).*/\2/p' | head -1)"
  if [ "$PROBE_OK" -eq 0 ]; then PROBE_GROUP="(none)"; elif [ -z "$PROBE_GROUP" ]; then PROBE_GROUP="(unknown)"; fi
  PROBE_OUT="$out"
}

# stats: reads one number per line on stdin, prints "mean p50 p95 p99 max"
stats() {
  sort -n | awk '{a[NR]=$1; s+=$1}
    function pct(p,  i){ i=int(p/100*NR); if(i<p/100*NR) i++; if(i<1)i=1; if(i>NR)i=NR; return a[i] }
    END{ if(NR==0){print "nan nan nan nan nan"; exit}
         printf "%.2f %.2f %.2f %.2f %.2f\n", s/NR, pct(50), pct(95), pct(99), a[NR] }'
}

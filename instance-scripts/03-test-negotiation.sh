#!/usr/bin/env bash
# 03 - Prove what a security policy blocks and what it does not. One handshake per case.
#   bash 03-test-negotiation.sh
# Port PQ_PORT    : PQ policy, TLS 1.2 + 1.3
# Port TLS13_PORT : PQ policy, TLS 1.3 only
# Port CLASSIC_PORT : classical policy (control)
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
load_env

openssl_ok || { echo "OpenSSL >= 3.5 is required (found: $("$OPENSSL" version 2>&1)). Run 01-verify-install.sh."; exit 1; }
echo "OpenSSL: $("$OPENSSL" version)"
echo "Target : $ALB_DNS  (PQ $PQ_PORT, PQ TLS1.3-only $TLS13_PORT, classical $CLASSIC_PORT)"

# expect_group <label> <port> <groups> <expected group> [tls flag]   handshake must succeed with this group
expect_group() {
  probe "$2" "$3" "${5:--tls1_3}"
  if [ "$PROBE_OK" -eq 1 ] && [ "$PROBE_GROUP" = "$4" ]; then pass "$1 -> $PROBE_GROUP"
  else fail "$1" "expected $4, got $PROBE_GROUP (handshake ok=$PROBE_OK)"; printf '%s\n' "$PROBE_OUT" | grep -iE 'group|temp key|Protocol|Cipher is' | head -6 | sed 's/^/       | /'; fi
}
# expect_ok <label> <port> <groups> <tls flag>   handshake must succeed (group not checked)
expect_ok() {
  probe "$2" "$3" "$4"
  if [ "$PROBE_OK" -eq 1 ]; then pass "$1 -> connected (classical, no ML-KEM possible)"
  else fail "$1" "handshake was refused"; fi
}
# expect_refused <label> <port> <groups> <tls flag>   handshake must be refused
expect_refused() {
  probe "$2" "$3" "$4"
  if [ "$PROBE_OK" -eq 0 ]; then pass "$1 -> REFUSED by the load balancer"
  else fail "$1" "connection succeeded ($PROBE_GROUP), expected a refusal"; fi
}

section "1. PQ policy, TLS 1.2 + 1.3 (port $PQ_PORT)"
expect_group "Client offers X25519MLKEM768 + X25519 " "$PQ_PORT" "X25519MLKEM768:X25519" "X25519MLKEM768"
expect_group "Client offers SecP256r1MLKEM768       " "$PQ_PORT" "SecP256r1MLKEM768" "SecP256r1MLKEM768"
expect_group "Client offers SecP384r1MLKEM1024      " "$PQ_PORT" "SecP384r1MLKEM1024" "SecP384r1MLKEM1024"
expect_group "Client offers X25519 only (not PQ)    " "$PQ_PORT" "X25519" "X25519"
expect_ok    "TLS 1.2 client                        " "$PQ_PORT" "" "-tls1_2"

section "2. PQ policy, TLS 1.3 only (port $TLS13_PORT)"
expect_group "Client offers X25519MLKEM768 + X25519 " "$TLS13_PORT" "X25519MLKEM768:X25519" "X25519MLKEM768"
expect_group "TLS 1.3 client offers X25519 only     " "$TLS13_PORT" "X25519" "X25519"
expect_refused "TLS 1.2 client                      " "$TLS13_PORT" "" "-tls1_2"

section "3. Classical policy (port $CLASSIC_PORT), the control"
expect_group "Client offers X25519MLKEM768 + X25519 (silent fallback)" "$CLASSIC_PORT" "X25519MLKEM768:X25519" "X25519"
expect_refused "Client offers X25519MLKEM768 only (no shared group)  " "$CLASSIC_PORT" "X25519MLKEM768" "-tls1_3"

section "What the policy can and cannot block"
cat <<'TXT'
  BLOCKED by the policy : TLS versions and cipher suites the policy does not offer (TLS 1.2 on port 9443).
  NOT blocked           : a TLS 1.3 client that does not offer ML-KEM. It connects with X25519, on every
                          PQ policy. A PQ policy adds a capability, it does not enforce it.
  So to know who is still classical, read the connection logs: run 04, then 06.
TXT

section "Summary"
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then echo "NEGOTIATION AS EXPECTED"; exit 0; else echo "$FAIL CASE(S) NOT AS EXPECTED"; exit 1; fi

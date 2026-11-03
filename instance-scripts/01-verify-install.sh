#!/usr/bin/env bash
# 01 - Check that the test client instance is correctly set up. Run on the instance.
#   bash 01-verify-install.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
load_env

section "1. Configuration"
for v in ALB_DNS ALB_ARN AWS_REGION LOG_BUCKET LOG_PREFIX PQ_PORT CLASSIC_PORT TLS13_PORT; do
  [ -n "${!v:-}" ] && pass "demo.env defines $v (${!v})" || fail "demo.env defines $v"
done
[ "$FAIL" -eq 0 ] || { echo; echo "Cannot continue without the configuration."; exit 1; }

section "2. Tools"
if openssl_ok; then
  pass "OpenSSL >= 3.5 available: $("$OPENSSL" version) ($(command -v "$OPENSSL"))"
else
  fail "OpenSSL >= 3.5 available" "found: $("$OPENSSL" version 2>&1). See /var/log/pq-alb-userdata.log (script 00)"
fi
if "$OPENSSL" list -kem-algorithms 2>/dev/null | grep -qi 'mlkem'; then
  pass "This OpenSSL lists ML-KEM"
else
  warn "This OpenSSL lists ML-KEM" "'openssl list -kem-algorithms' shows no ML-KEM entry"
fi
command -v aws >/dev/null 2>&1 && pass "AWS CLI installed: $(aws --version 2>&1 | head -1)" || fail "AWS CLI installed"
command -v curl >/dev/null 2>&1 && pass "curl installed" || fail "curl installed"

section "3. Credentials"
ID="$(aws sts get-caller-identity --query Arn --output text 2>&1)"
case "$ID" in *assumed-role*) pass "Instance role credentials work: $ID" ;; *) fail "Instance role credentials work" "$ID" ;; esac

section "4. Network path to the load balancer"
if getent hosts "$ALB_DNS" >/dev/null 2>&1; then
  pass "$ALB_DNS resolves to $(getent hosts "$ALB_DNS" | awk '{print $1}' | tr '\n' ' ')"
else
  fail "$ALB_DNS resolves"
fi
for p in "$PQ_PORT" "$CLASSIC_PORT" "$TLS13_PORT"; do
  if timeout 5 bash -c "exec 3<>/dev/tcp/$ALB_DNS/$p" 2>/dev/null; then
    pass "TCP port $p reachable"
  else
    fail "TCP port $p reachable" "check the load balancer security group and listener"
  fi
done

section "5. Setup log"
if [ -s /var/log/pq-alb-userdata.log ]; then
  pass "Setup log present (/var/log/pq-alb-userdata.log)"
else
  warn "Setup log present" "/var/log/pq-alb-userdata.log missing"
fi
[ -e /var/log/pq-alb-demo.done ] && pass "Setup completion marker present" || warn "Setup completion marker present" "setup may still be running"

section "Summary"
echo "passed: $PASS   failed: $FAIL   warnings: $WARN"
if [ "$FAIL" -eq 0 ]; then echo "INSTALLATION COMPLETE"; exit 0; else echo "INSTALLATION INCOMPLETE ($FAIL failure(s))"; exit 1; fi

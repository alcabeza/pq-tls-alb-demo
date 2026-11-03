#!/usr/bin/env bash
# 02 - Check how the load balancer is configured: which TLS security policy each listener uses,
#      what the policies contain, and whether connection logs are enabled. Read-only.
#   bash 02-verify-alb-policy.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
load_env

section "1. Listeners and security policies"
LST="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
        --query 'Listeners[].[Port,Protocol,SslPolicy]' --output text 2>&1)" || { fail "DescribeListeners" "$LST"; exit 1; }
echo "$LST" | awk '{printf "  port %-6s %-6s %s\n", $1, $2, $3}'
PQ_POLICY="$(echo "$LST" | awk -v p="$PQ_PORT" '$1==p {print $3}')"
CL_POLICY="$(echo "$LST" | awk -v p="$CLASSIC_PORT" '$1==p {print $3}')"
T13_POLICY="$(echo "$LST" | awk -v p="$TLS13_PORT" '$1==p {print $3}')"

[ -n "$PQ_POLICY" ] && pass "Listener on port $PQ_PORT exists (policy $PQ_POLICY)" || fail "Listener on port $PQ_PORT exists"
case "$PQ_POLICY" in *PQ*) pass "Port $PQ_PORT policy name contains PQ (hybrid post-quantum)" ;; *) fail "Port $PQ_PORT policy name contains PQ" "got: $PQ_POLICY" ;; esac
[ -n "$CL_POLICY" ] && pass "Listener on port $CLASSIC_PORT exists (policy $CL_POLICY)" || fail "Listener on port $CLASSIC_PORT exists"
case "$CL_POLICY" in *PQ*) fail "Port $CLASSIC_PORT policy is classical (control)" "got a PQ policy: $CL_POLICY" ;; *) pass "Port $CLASSIC_PORT policy is classical (control)" ;; esac

[ -n "$T13_POLICY" ] && pass "Listener on port $TLS13_PORT exists (policy $T13_POLICY)" || fail "Listener on port $TLS13_PORT exists"
case "$T13_POLICY" in *PQ*1-3*|*1-3*PQ*) pass "Port $TLS13_PORT policy is a TLS 1.3 only PQ policy" ;; *) fail "Port $TLS13_PORT policy is a TLS 1.3 only PQ policy" "got: $T13_POLICY" ;; esac

section "2. Policy contents"
for pol in "$PQ_POLICY" "$T13_POLICY" "$CL_POLICY"; do
  [ -n "$pol" ] || continue
  echo "-- $pol"
  PROTO="$(aws elbv2 describe-ssl-policies --names "$pol" --query 'SslPolicies[0].SslProtocols' --output text 2>&1 | tr '\t' ' ')"
  NCIPH="$(aws elbv2 describe-ssl-policies --names "$pol" --query 'length(SslPolicies[0].Ciphers)' --output text 2>&1)"
  echo "   protocols: $PROTO"
  echo "   ciphers  : $NCIPH"
done
echo
echo "Note: the list of key exchange groups is not part of the API output. AWS documents that PQ policies offer"
echo "X25519MLKEM768, SecP256r1MLKEM768 and SecP384r1MLKEM1024 next to classical groups; script 03 tests it for real."

section "3. Connection logs"
ATTR="$(aws elbv2 describe-load-balancer-attributes --load-balancer-arn "$ALB_ARN" \
        --query 'Attributes[?starts_with(Key, `connection_logs`)].[Key,Value]' --output text 2>&1)" || { fail "DescribeLoadBalancerAttributes" "$ATTR"; ATTR=""; }
echo "$ATTR" | awk '{printf "  %s = %s\n", $1, $2}'
echo "$ATTR" | grep -q 'connection_logs.s3.enabled[[:space:]]*true' && pass "Connection logs are enabled" || fail "Connection logs are enabled"
echo "$ATTR" | grep -q "connection_logs.s3.bucket[[:space:]]*$LOG_BUCKET" && pass "Connection logs go to $LOG_BUCKET" || fail "Connection logs go to $LOG_BUCKET"
aws s3api head-bucket --bucket "$LOG_BUCKET" >/dev/null 2>&1 && pass "Log bucket is readable from this instance" || fail "Log bucket is readable from this instance"

section "Summary"
echo "passed: $PASS   failed: $FAIL   warnings: $WARN"
if [ "$FAIL" -eq 0 ]; then echo "ALB POLICY CONFIGURATION OK"; exit 0; else echo "ALB POLICY CONFIGURATION HAS $FAIL FAILURE(S)"; exit 1; fi

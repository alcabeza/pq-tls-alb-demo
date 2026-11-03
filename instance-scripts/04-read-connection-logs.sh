#!/usr/bin/env bash
# 04 - Read the ALB connection logs from S3 and summarize the key exchange seen by the load balancer.
#   bash 04-read-connection-logs.sh            # read what is there now
#   WAIT_MINUTES=10 bash 04-read-connection-logs.sh   # poll until entries show up (delivery is every ~5 min)
# Run script 03 first so that there are connections to look at.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
load_env

WAIT_MINUTES="${WAIT_MINUTES:-0}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
PREFIX="$LOG_PREFIX/AWSLogs/$ACCOUNT/elasticloadbalancing/$AWS_REGION/"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

fetch() {
  rm -rf "$WORK/gz" "$WORK/all.log"; mkdir -p "$WORK/gz"
  aws s3 cp "s3://$LOG_BUCKET/$PREFIX" "$WORK/gz/" --recursive --exclude '*' --include '*conn_log_*.log.gz' --only-show-errors; find "$WORK/gz" -mindepth 2 -name '*.gz' -exec mv -t "$WORK/gz" {} +
  if ls "$WORK"/gz/*.gz >/dev/null 2>&1; then gunzip -c "$WORK"/gz/*.gz > "$WORK/all.log"; fi
  [ -s "$WORK/all.log" ]
}

echo "Bucket : s3://$LOG_BUCKET/$PREFIX"
deadline=$(( $(date +%s) + WAIT_MINUTES * 60 ))
until fetch; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo
    echo "No connection log entries yet. The load balancer delivers a file every 5 minutes: run script 03, then"
    echo "retry in a few minutes, or use WAIT_MINUTES=10 to wait."
    exit 3
  fi
  echo "  waiting for the first log file..."; sleep 30
done

echo "Files  : $(find "$WORK/gz" -name '*.gz' | wc -l)   entries: $(wc -l < "$WORK/all.log")"

# Fields (documented order): 1 timestamp 2 client_ip 3 client_port 4 listener_port 5 tls_protocol 6 tls_cipher
# 7 tls_handshake_latency(s) ... 11 tls_verify_status 12 conn_trace_id 13 tls_keyexchange 14 elb 15 ip_address
section "1. Connections by listener port and key exchange"
awk '{ k=$4 "\t" $5 "\t" $13; n[k]++; if ($7 != "-") { s[k]+=$7; c[k]++ } }
     END { printf "%-8s %-9s %-22s %6s %s\n", "port", "tls", "tls_keyexchange", "count", "avg handshake (ms)";
           for (k in n) { split(k, f, "\t");
             printf "%-8s %-9s %-22s %6d %s\n", f[1], f[2], f[3], n[k], (c[k] ? sprintf("%.1f", s[k]/c[k]*1000) : "-") } }' \
  "$WORK/all.log" | { read -r head; echo "$head"; sort; }

section "2. Last 10 entries (time, port, tls, cipher, handshake s, key exchange)"
tail -n 10 "$WORK/all.log" | awk '{printf "%s  %-5s %-8s %-28s %-7s %s\n", $1, $4, $5, $6, $7, $13}'

section "3. Check"
PQ_SEEN="$(awk -v p="$PQ_PORT" '$4==p {print $13}' "$WORK/all.log" | sort -u | tr '\n' ' ')"
CL_SEEN="$(awk -v p="$CLASSIC_PORT" '$4==p {print $13}' "$WORK/all.log" | sort -u | tr '\n' ' ')"
echo "key exchange values seen on port $PQ_PORT      : ${PQ_SEEN:-none}"
echo "key exchange values seen on port $CLASSIC_PORT : ${CL_SEEN:-none}"
if [ "$(printf '%s\n%s\n' "$PQ_SEEN" "$CL_SEEN" | tr ' ' '\n' | sed '/^$/d' | sort -u | wc -l)" -ge 2 ]; then
  echo "The log shows different key exchange values for the two listeners: compare them with script 03."
else
  echo "Only one kind of value seen so far: run script 03, wait for the next delivery and read again."
fi
echo "(The exact strings logged for classical and post-quantum exchanges are shown above as AWS writes them.)"

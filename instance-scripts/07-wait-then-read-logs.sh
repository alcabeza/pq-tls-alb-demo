#!/usr/bin/env bash
# 07 - Wait for the next connection log delivery, then read the logs (04) and list classical clients (06).
#   bash 07-wait-then-read-logs.sh                      # pause 5 minutes, then run 04 and 06
#   WAIT_BEFORE_MINUTES=8 bash 07-wait-then-read-logs.sh
# Script 04 then polls for up to POLL_MINUTES (default 10) in case the first file is still late.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAUSE="${WAIT_BEFORE_SECONDS:-$(( ${WAIT_BEFORE_MINUTES:-5} * 60 ))}"
POLL="${POLL_MINUTES:-10}"

echo "Waiting $((PAUSE / 60)) min $((PAUSE % 60)) s for the ALB to deliver its next connection log file (started $(date +%H:%M:%S))."
left="$PAUSE"
while [ "$left" -gt 0 ]; do
  step=$(( left < 30 ? left : 30 ))
  sleep "$step"; left=$(( left - step ))
  [ "$left" -gt 0 ] && printf '  %d:%02d left\n' $((left / 60)) $((left % 60))
done

echo; echo "################ 04 - connection logs ################"
WAIT_MINUTES="$POLL" bash "$DIR/04-read-connection-logs.sh"; rc4=$?
echo; echo "################ 06 - clients without ML-KEM ################"
bash "$DIR/06-detect-non-pq-clients.sh"; rc6=$?
[ "$rc4" -ne 0 ] && exit "$rc4"
exit "$rc6"

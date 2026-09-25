#!/usr/bin/env bash
#
# Generates a realistic traffic mix against the demo app so that the Grafana
# panels, the HPA and the alert rules have something to react to.
#
#   ./scripts/generate-load.sh [duration_seconds] [workers]
#   BASE_URL=http://localhost ./scripts/generate-load.sh 120 8
#
# Exits non-zero if any request came back 5xx — a load generator that hides
# server errors is worse than none.
#
# Keeps to bash 3.2 features: macOS still ships that as /bin/bash.

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
DURATION="${1:-60}"
WORKERS="${2:-4}"
SLOW_EVERY="${SLOW_EVERY:-10}"   # every Nth request burns 300ms to stress p95
SLOW_MS="${SLOW_MS:-300}"
FAST_MS="${FAST_MS:-40}"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

# Fail early with a readable message instead of 500 lines of connection errors.
if ! curl -fsS --max-time 3 "$BASE_URL/healthz" >/dev/null 2>&1; then
  echo "ERROR: $BASE_URL/healthz is not reachable." >&2
  echo "Is the stack up?  docker compose up -d" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
PIDS=""

cleanup() {
  # Ctrl+C must not leave curl loops running in the background.
  if [ -n "$PIDS" ]; then kill $PIDS 2>/dev/null || true; fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

worker() {
  local id="$1" out="$WORKDIR/w$1.out" n=0
  local deadline=$(( $(date +%s) + DURATION ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    n=$(( n + 1 ))
    # Route template mix: the label cardinality stays bounded no matter how
    # many different ?ms= values we send.
    curl -s -o /dev/null -w '%{http_code}\n' "$BASE_URL/" >>"$out"
    curl -s -o /dev/null -w '%{http_code}\n' "$BASE_URL/api/work?ms=$FAST_MS" >>"$out"
    if [ $(( n % SLOW_EVERY )) -eq 0 ]; then
      curl -s -o /dev/null -w '%{http_code}\n' "$BASE_URL/api/work?ms=$SLOW_MS" >>"$out"
    fi
    if [ $(( n % 25 )) -eq 0 ]; then
      # Unknown path: proves the "unmatched" label works and feeds the 4xx series.
      curl -s -o /dev/null -w '%{http_code}\n' "$BASE_URL/no-such-route" >>"$out"
    fi
  done
}

echo "target   : $BASE_URL"
echo "duration : ${DURATION}s | workers: $WORKERS | every ${SLOW_EVERY}th request: ${SLOW_MS}ms"
echo

started=$(date +%s)
i=1
while [ "$i" -le "$WORKERS" ]; do
  worker "$i" &
  PIDS="$PIDS $!"
  i=$(( i + 1 ))
done

# Progress line so a 2-minute run does not look like a hang. Only on a tty:
# in CI logs a carriage-returned counter is unreadable noise.
if [ -t 1 ]; then
  while kill -0 ${PIDS%% *} 2>/dev/null; do
    left=$(( DURATION - ( $(date +%s) - started ) ))
    [ "$left" -lt 0 ] && left=0
    printf '\r  running... %ss left ' "$left"
    sleep 2
  done
  printf '\r%*s\r' 30 ''
fi
wait $PIDS 2>/dev/null || true

elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -eq 0 ] && elapsed=1

cat "$WORKDIR"/*.out > "$WORKDIR/all.out"
total=$(wc -l < "$WORKDIR/all.out" | tr -d ' ')
errors=$(grep -c '^5' "$WORKDIR/all.out" || true)

echo "requests : $total in ${elapsed}s  (~$(( total / elapsed )) rps)"
echo "by status:"
sort "$WORKDIR/all.out" | uniq -c | sort -rn | sed 's/^/  /'

# Best effort: read back the percentile the SLO is defined on, so the script
# reports the same number the dashboard, the alert and k6 use.
if command -v python3 >/dev/null && curl -fsS --max-time 3 "$PROM_URL/-/ready" >/dev/null 2>&1; then
  q='histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{job="app"}[1m])))'
  p95=$(curl -fsSG --max-time 5 --data-urlencode "query=$q" "$PROM_URL/api/v1/query" \
        | python3 -c 'import json,sys;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else "")' 2>/dev/null || true)
  if [ -n "$p95" ]; then
    verdict=$(python3 -c "print('OK' if float('$p95') < 0.2 else 'ABOVE SLO')")
    printf 'p95      : %.3fs (SLO 0.200s) -> %s\n' "$p95" "$verdict"
  fi
fi

if [ "$errors" -gt 0 ]; then
  echo
  echo "FAILED: $errors server errors (5xx) during the run" >&2
  exit 1
fi

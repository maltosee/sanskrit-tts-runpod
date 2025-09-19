#!/usr/bin/env bash
set -euo pipefail

# --- Config (tweak if needed) ---
SUPERVISOR_CONF=/etc/supervisor/supervisord.conf
SUPERVISOR_SOCK=/var/run/supervisor.sock
MIN_SPACING_SECS=60        # >= 60s between TTS starts
FINAL_LB_DELAY_SECS=150    # wait after final TTS is healthy before LB start
HEALTH_TIMEOUT=4           # seconds per curl probe
HEALTH_RETRY_INTERVAL=2    # seconds between probes
MAX_HEALTH_WAIT=60         # give up after this many seconds per worker
SUP_SOCKET_WAIT=30         # wait up to N seconds for socket to appear
# programs and ports (match supervisord.conf)
declare -a PROGRAMS=( "tts_8888:8888" "tts_8889:8889" "tts_8000:8000" )

# --- Helpers ---
log() { echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - $*"; }

# Ensure authoritative config exists
if [ ! -f "$SUPERVISOR_CONF" ]; then
  echo "ERROR: supervisord config not found at $SUPERVISOR_CONF"
  exit 1
fi

# Convert CRLF -> LF if dos2unix available (guard against Windows CRLF in repo)
if command -v dos2unix >/dev/null 2>&1; then
  dos2unix -q "$SUPERVISOR_CONF" || true
fi

# Remove stale socket if present
rm -f "$SUPERVISOR_SOCK" || true

log "Starting supervisord (config: $SUPERVISOR_CONF)..."
/usr/bin/supervisord -c "$SUPERVISOR_CONF" &
SUP_PID=$!

# Wait for socket file to appear
log "Waiting for supervisord socket..."
count=0
while [ ! -S "$SUPERVISOR_SOCK" ] && [ $count -lt $SUP_SOCKET_WAIT ]; do
  sleep 1
  count=$((count+1))
done

if [ ! -S "$SUPERVISOR_SOCK" ]; then
  log "ERROR: supervisord socket not available after ${SUP_SOCKET_WAIT}s"
  ps aux | grep supervisord || true
  # Dump supervisord stderr if available (best-effort)
  exit 1
fi
log "Supervisord socket ready"

# Wait until supervisorctl can talk to supervisord (retry loop)
log "Testing supervisorctl connectivity..."
for i in $(seq 1 8); do
  if /usr/bin/supervisorctl -s "unix://$SUPERVISOR_SOCK" status >/dev/null 2>&1; then
    log "supervisorctl connectivity confirmed"
    break
  fi
  log "supervisorctl cannot connect yet (attempt $i/8), retrying..."
  sleep 1
done

if ! /usr/bin/supervisorctl -s "unix://$SUPERVISOR_SOCK" status >/dev/null 2>&1; then
  log "ERROR: supervisorctl still cannot connect after retries"
  ps aux | grep supervisord || true
  exit 1
fi

# start a program and wait for its /health
start_and_wait() {
  prog="$1"   # e.g. tts_8888
  port="$2"   # e.g. 8888

  log "Starting $prog (port $port)..."
  /usr/bin/supervisorctl -s "unix://$SUPERVISOR_SOCK" start "$prog" >/dev/null 2>&1 || true

  # enforce minimum spacing between program starts if LAST_STARTED set
  if [ -n "${LAST_STARTED:-}" ]; then
    elapsed=$(( $(date +%s) - LAST_STARTED ))
    if [ $elapsed -lt $MIN_SPACING_SECS ]; then
      wait_for=$(( MIN_SPACING_SECS - elapsed ))
      log "Enforcing minimum spacing: sleeping $wait_for s"
      sleep $wait_for
    fi
  fi

  # Poll health endpoint until OK or timeout
  started_at=$(date +%s)
  deadline=$(( started_at + MAX_HEALTH_WAIT ))
  while true; do
    now=$(date +%s)
    if [ $now -ge $deadline ]; then
      log "ERROR: health probe timeout for $prog (port $port) after ${MAX_HEALTH_WAIT}s"
      /usr/bin/supervisorctl -s "unix://$SUPERVISOR_SOCK" status "$prog" || true
      exit 1
    fi

    if curl -s --max-time $HEALTH_TIMEOUT "http://127.0.0.1:${port}/health" | grep -q -E "200|healthy|ok"; then
      log "$prog (port $port) is healthy"
      break
    else
      log "Waiting for $prog (port $port) health..."
      sleep $HEALTH_RETRY_INTERVAL
    fi
  done

  LAST_STARTED=$(date +%s)
}

# Sequentially start TTS programs
for entry in "${PROGRAMS[@]}"; do
  prog="${entry%%:*}"
  port="${entry##*:}"
  start_and_wait "$prog" "$port"
done

log "All TTS instances healthy. Enforcing final LB delay ${FINAL_LB_DELAY_SECS}s..."
sleep $FINAL_LB_DELAY_SECS

# Start LB
log "Starting load balancer (lb)..."
/usr/bin/supervisorctl -s "unix://$SUPERVISOR_SOCK" start lb >/dev/null 2>&1 || true

# Keep container alive by waiting on supervisord process
wait $SUP_PID

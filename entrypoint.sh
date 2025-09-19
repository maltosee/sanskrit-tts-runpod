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
#!/usr/bin/env bash
# Very-simple entrypoint restarter
set -euo pipefail

# CONFIG (tweak if desired)
MIN_SPACING_SECS=60
FINAL_LB_DELAY_SECS=150
HEALTH_TIMEOUT=4
HEALTH_RETRY_INTERVAL=2
MAX_HEALTH_WAIT=60

MONITOR_INTERVAL=5
MAX_RESTARTS=5    # stop attempting after this many restarts for a process

# Process definitions: name|cmd|health_port
PROCS=(
  "tts_8888|python3 /workspace/direct_tts_server.py --port 8888|8888"
  "tts_8889|python3 /workspace/direct_tts_server.py --port 8889|8889"
  "tts_8000|python3 /workspace/direct_tts_server.py --port 8000|8000"
)
LB_NAME="lb"
LB_CMD="node /workspace/tts_load_balancer.js"

declare -A PID
declare -A RESTART_COUNT
declare -A DISABLED

log(){ printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"; }

start_proc_bg() {
  local name="$1"; shift
  local cmd="$*"
  log "START -> $name : $cmd"
  # start in background inheriting stdout/stderr
  bash -c "$cmd" &
  PID["$name"]=$!
  log "PID ${PID[$name]} for $name"
}

is_running() {
  local name="$1"
  local pid="${PID[$name]:-}"
  if [ -z "$pid" ]; then return 1; fi
  if kill -0 "$pid" 2>/dev/null; then return 0; else return 1; fi
}

wait_for_health() {
  local port="$1"
  local deadline=$(( $(date +%s) + MAX_HEALTH_WAIT ))
  while true; do
    if curl -s --max-time $HEALTH_TIMEOUT "http://127.0.0.1:${port}/health" | grep -q -E "200|healthy|ok"; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    sleep $HEALTH_RETRY_INTERVAL
  done
}

attempt_restart_simple() {
  local name="$1"; shift
  local cmd="$*"
  RESTART_COUNT["$name"]=$(( ${RESTART_COUNT["$name"]:-0} + 1 ))
  if [ "${RESTART_COUNT["$name"]}" -gt "$MAX_RESTARTS" ]; then
    log "ERROR: $name exceeded MAX_RESTARTS (${RESTART_COUNT["$name"]}). Disabling further restarts."
    DISABLED["$name"]=1
    return 1
  fi
  log "RESTART -> $name (attempt ${RESTART_COUNT["$name"]}/${MAX_RESTARTS})"
  start_proc_bg "$name" "$cmd"
  return 0
}

cleanup() {
  log "Entrypoint shutting down; killing children"
  for n in "${!PID[@]}"; do
    pid=${PID[$n]}
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  # brief grace
  sleep 1
}
trap cleanup EXIT

# ---- Startup sequence: TTS in order ----
last_start=0
for entry in "${PROCS[@]}"; do
  IFS='|' read -r name cmd port <<< "$entry"
  # spacing
  if [ "$last_start" -ne 0 ]; then
    elapsed=$(( $(date +%s) - last_start ))
    if [ "$elapsed" -lt "$MIN_SPACING_SECS" ]; then
      wait_for=$(( MIN_SPACING_SECS - elapsed ))
      log "Enforcing spacing: sleeping ${wait_for}s before starting $name"
      sleep "$wait_for"
    fi
  fi

  start_proc_bg "$name" "$cmd"

  log "Waiting for $name health on port $port..."
  if wait_for_health "$port"; then
    log "$name healthy"
  else
    log "ERROR: $name did not become healthy within ${MAX_HEALTH_WAIT}s. Exiting."
    exit 1
  fi

  last_start=$(date +%s)
done

log "All TTS healthy. Waiting final LB delay ${FINAL_LB_DELAY_SECS}s"
sleep "$FINAL_LB_DELAY_SECS"

# Start LB
start_proc_bg "$LB_NAME" "$LB_CMD"

# ---- Monitor loop: simple restart logic ----
log "Entering monitor loop (interval ${MONITOR_INTERVAL}s)"
while true; do
  sleep "$MONITOR_INTERVAL"
  # check TTS processes
  for entry in "${PROCS[@]}"; do
    IFS='|' read -r name cmd port <<< "$entry"
    if [ "${DISABLED[$name]:-0}" -eq 1 ]; then
      continue
    fi
    if ! is_running "$name"; then
      log "Detected $name not running"
      attempt_restart_simple "$name" "$cmd"
      # after restart, give it a moment before health-check
      sleep 2
      if ! is_running "$name"; then
        log "Warning: $name restart did not stay up"
      fi
    fi
  done

  # check LB
  if [ "${DISABLED[$LB_NAME]:-0}" -ne 1 ]; then
    if ! is_running "$LB_NAME"; then
      log "Detected $LB_NAME not running"
      attempt_restart_simple "$LB_NAME" "$LB_CMD"
      sleep 1
      if ! is_running "$LB_NAME"; then
        log "Warning: $LB_NAME restart did not stay up"
      fi
    fi
  fi
done

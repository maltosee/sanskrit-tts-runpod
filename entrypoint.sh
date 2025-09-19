#!/usr/bin/env bash
set -euo pipefail

# Timeouts
TTS_WARMUP_TIMEOUT=240  # 4 minutes per TTS
LB_TIMEOUT=120         # 2 minutes for LB
HEALTH_CHECK_INTERVAL=5
MONITOR_INTERVAL=10

declare -A PID
declare -A TTS_RESTARTED

log() { printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"; }

start_tts_and_wait() {
  local port="$1"
  local name="tts_${port}"
  
  log "Starting $name"
  python3 /workspace/direct_tts_server.py --port "$port" &
  PID["$name"]=$!
  log "PID ${PID[$name]} for $name"
  
  log "Waiting for $name health on port $port..."
  local deadline=$(($(date +%s) + TTS_WARMUP_TIMEOUT))
  while [ $(date +%s) -lt $deadline ]; do
    if curl -s --max-time 3 "http://127.0.0.1:${port}/health" | grep -q "healthy" 2>/dev/null; then
      log "$name healthy"
      return 0
    fi
    sleep $HEALTH_CHECK_INTERVAL
  done
  
  log "ERROR: $name did not become healthy within ${TTS_WARMUP_TIMEOUT}s"
  return 1
}

restart_tts_once() {
  local port="$1"
  local name="tts_${port}"
  
  if [ "${TTS_RESTARTED[$name]:-0}" -eq 1 ]; then
    log "$name already restarted once, giving up"
    return 1
  fi
  
  log "Restarting $name (one attempt only)"
  TTS_RESTARTED["$name"]=1
  
  # Kill old process (GPU cleanup handled by atexit in Python)
  local old_pid="${PID[$name]:-}"
  if [ -n "$old_pid" ]; then
    log "Killing old $name process $old_pid"
    kill "$old_pid" 2>/dev/null || true
    sleep 3  # Give process time to clean up
  fi
  
  start_tts_and_wait "$port"
}

start_lb() {
  log "Starting load balancer"
  node /workspace/tts_load_balancer.js &
  PID["lb"]=$!
  log "PID ${PID[lb]} for load balancer"
  
  # Wait for LB to be responsive
  log "Waiting for load balancer health..."
  local deadline=$(($(date +%s) + LB_TIMEOUT))
  while [ $(date +%s) -lt $deadline ]; do
    if curl -s --max-time 3 "http://127.0.0.1:80/health" >/dev/null 2>&1; then
      log "Load balancer healthy"
      return 0
    fi
    sleep $HEALTH_CHECK_INTERVAL
  done
  
  log "ERROR: Load balancer failed to start within ${LB_TIMEOUT}s"
  return 1
}

restart_lb() {
  local attempts="${LB_RESTART_ATTEMPTS:-0}"
  if [ "$attempts" -ge 3 ]; then
    log "Load balancer exceeded 3 restart attempts, giving up"
    return 1
  fi
  
  LB_RESTART_ATTEMPTS=$((attempts + 1))
  log "Restarting load balancer (attempt ${LB_RESTART_ATTEMPTS}/3)"
  
  # Kill old process
  local old_pid="${PID[lb]:-}"
  if [ -n "$old_pid" ]; then
    log "Killing old load balancer process $old_pid"
    kill "$old_pid" 2>/dev/null || true
    sleep 2
  fi
  
  start_lb
}

is_running() {
  local name="$1"
  local pid="${PID[$name]:-}"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

cleanup() {
  log "Entrypoint shutting down; killing children"
  for name in "${!PID[@]}"; do
    local pid="${PID[$name]}"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  sleep 2  # Give processes time to clean up
}
trap cleanup EXIT

# Sequential TTS startup
log "Starting TTS instances sequentially..."
for port in 8888 8889 8000; do
  if ! start_tts_and_wait "$port"; then
    log "Failed to start TTS on port $port, exiting"
    exit 1
  fi
  sleep 5  # Brief pause between TTS starts
done

log "All TTS instances ready. Starting load balancer..."
if ! start_lb; then
  log "Failed to start load balancer, exiting"
  exit 1
fi

log "All services started successfully. Entering monitor loop (interval ${MONITOR_INTERVAL}s)"

# Monitor and restart loop
LB_RESTART_ATTEMPTS=0
while true; do
  sleep $MONITOR_INTERVAL
  
  # Check TTS instances
  for port in 8888 8889 8000; do
    name="tts_${port}"
    if ! is_running "$name"; then
      log "Detected $name not running"
      if restart_tts_once "$port"; then
        log "$name restarted successfully"
      else
        log "$name restart failed permanently - continuing with remaining instances"
      fi
    fi
  done
  
  # Check load balancer
  if ! is_running "lb"; then
    log "Detected load balancer not running"
    if restart_lb; then
      log "Load balancer restarted successfully"
    else
      log "Load balancer restart failed permanently - service degraded"
    fi
  fi
done
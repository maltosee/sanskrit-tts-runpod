#!/usr/bin/env bash
set -euo pipefail

MIN_SPACING_SECS=60       # >=60s between TTS starts
FINAL_LB_DELAY_SECS=150   # wait after final TTS is healthy before LB start
HEALTH_TIMEOUT=4          # curl timeout per probe (seconds)
HEALTH_RETRY_INTERVAL=2   # seconds between probes
MAX_HEALTH_WAIT=60        # give up after this many seconds per worker

echo "Starting supervisord..."
/usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf &
SUP_PID=$!

# helper: start program and wait for health
start_and_wait() {
  prog="$1"
  port="$2"
  echo "Starting $prog (port $port)..."
  /usr/bin/supervisorctl start "$prog"

  # enforce minimum spacing if LAST_STARTED exists
  if [ -n "${LAST_STARTED:-}" ]; then
    elapsed=$(( $(date +%s) - LAST_STARTED ))
    if [ $elapsed -lt $MIN_SPACING_SECS ]; then
      wait_for=$(( MIN_SPACING_SECS - elapsed ))
      echo "Enforcing spacing: sleeping $wait_for seconds..."
      sleep $wait_for
    fi
  fi

  started_at=$(date +%s)
  deadline=$(( started_at + MAX_HEALTH_WAIT ))

  while true; do
    now=$(date +%s)
    if [ $now -ge $deadline ]; then
      echo "ERROR: health probe timeout for $prog (port $port) after ${MAX_HEALTH_WAIT}s"
      /usr/bin/supervisorctl status "$prog"
      exit 1
    fi

    # probe health quickly; expect small 200/JSON containing healthy/ok
    if curl -s --max-time $HEALTH_TIMEOUT "http://127.0.0.1:${port}/health" | grep -q -E "200|healthy|ok"; then
      echo "$prog (port $port) is healthy"
      break
    else
      echo "Waiting for $prog (port $port) health..."
      sleep $HEALTH_RETRY_INTERVAL
    fi
  done

  LAST_STARTED=$(date +%s)
}

# sequentially start workers
start_and_wait "tts_8888" 8888
start_and_wait "tts_8889" 8889
start_and_wait "tts_8000" 8000

echo "All TTS healthy. Enforcing final LB delay ${FINAL_LB_DELAY_SECS}s..."
sleep $FINAL_LB_DELAY_SECS

echo "Starting LB..."
/usr/bin/supervisorctl start lb

# Wait for supervisord so container doesn't exit
wait $SUP_PID

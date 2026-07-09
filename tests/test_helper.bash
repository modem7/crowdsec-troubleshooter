#!/usr/bin/env bash
# test_helper.bash — shared by every .bats file in this directory.
#
# start_mock_lapi <port> <python-handler-body> starts a throwaway
# http.server-based mock in the background and waits for it to be ready.
# stop_mock_lapi <port> kills it. This is the same pattern used for manual
# smoke-testing during development — now codified so it runs in CI on every
# push instead of only when someone remembers to do it by hand.

MOCK_PIDS=()

start_mock_lapi() {
  local port="$1"
  local handler="$2"
  python3 -c "
import http.server, threading, sys
class H(http.server.BaseHTTPRequestHandler):
${handler}
    def log_message(self, *a): pass
srv = http.server.HTTPServer(('127.0.0.1', ${port}), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
import time
while True: time.sleep(1)
" &
  MOCK_PIDS+=("$!")
  # wait for the port to actually be listening rather than a fixed sleep
  for _ in $(seq 1 20); do
    if curl -s -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null; then break; fi
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then exec 3>&-; break; fi
    sleep 0.1
  done
}

stop_mock_lapi() {
  for pid in "${MOCK_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  MOCK_PIDS=()
}

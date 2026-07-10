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
  # wait for the port to actually be listening rather than a fixed sleep.
  # fd 9, not 3: bats reserves fd 3 as its own TAP-output channel in the
  # test process. The raw-connect probe below opened fd 3 inside a
  # subshell (correctly scoped — closes automatically on subshell exit)
  # but then also ran `exec 3>&-` *outside* it, unconditionally, which
  # doesn't touch the subshell's fd at all — it closes the outer shell's
  # real fd 3, i.e. bats' own reporting channel, causing a "Bad file
  # descriptor" failure the next time bats tried to report this test's
  # result. Only reproduced when the primary curl check missed on its
  # first pass (server not listening yet) and fell through to this probe —
  # caught by a new test in test_live_block.bats hitting that timing
  # window, not by reading the code. Fixed by using a non-reserved fd and
  # dropping the redundant, harmful outer close.
  for _ in $(seq 1 20); do
    if curl -s -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null; then break; fi
    if (exec 9<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then break; fi
    sleep 0.1
  done
}

stop_mock_lapi() {
  for pid in "${MOCK_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  MOCK_PIDS=()
}

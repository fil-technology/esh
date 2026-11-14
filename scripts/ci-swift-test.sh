#!/usr/bin/env bash
# Runs `swift test` with a hard wall-clock limit for CI.
#
# A hang in the test process (e.g. a cooperative thread blocked forever) otherwise burns the whole job
# timeout and leaves a log that only says "started" with no hint of where it is stuck. On timeout this
# script prints every thread's backtrace of the still-running test processes, kills them, and fails.
#
# Usage: scripts/ci-swift-test.sh <timeout-seconds> [swift test arguments...]
set -uo pipefail

limit="${1:?usage: ci-swift-test.sh <timeout-seconds> [swift test args...]}"
shift

swift test "$@" &
test_pid=$!

elapsed=0
while kill -0 "$test_pid" 2>/dev/null; do
  if (( elapsed >= limit )); then
    echo "::error::swift test $* exceeded ${limit}s; dumping test-process backtraces and failing."
    # The test bundle runs in a child process (xctest or swiftpm-testing-helper), not in `swift test` itself.
    for pid in $(pgrep -f 'swiftpm-testing-helper|xctest|PackageTests' || true); do
      echo "===== backtraces for pid $pid: $(ps -o command= -p "$pid" | cut -c1-200) ====="
      # CI runners allow passwordless sudo; fall back to an unprivileged attach, then to `sample`.
      { sudo -n lldb --batch -p "$pid" -o 'thread backtrace all' 2>&1 \
          || lldb --batch -p "$pid" -o 'thread backtrace all' 2>&1 \
          || sample "$pid" 3 2>&1; } | head -n 6000 || true
    done
    pkill -TERM -P "$test_pid" 2>/dev/null || true
    kill -TERM "$test_pid" 2>/dev/null || true
    sleep 5
    pkill -KILL -f 'swiftpm-testing-helper|xctest' 2>/dev/null || true
    kill -KILL "$test_pid" 2>/dev/null || true
    exit 124
  fi
  sleep 5
  elapsed=$(( elapsed + 5 ))
done

wait "$test_pid"

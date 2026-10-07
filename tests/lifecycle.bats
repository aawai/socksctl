#!/usr/bin/env bats

load test_helper

setup() {
  setup_sandbox
  write_v2_profile p
  mkdir -p "$SANDBOX/fakebin"
  export PATH="$SANDBOX/fakebin:$PATH"
  export SOCKSCTL_START_TIMEOUT=1
  export SOCKSCTL_STOP_TIMEOUT=2
  export SOCKSCTL_POLL_INTERVAL=0.1
  export FAKE_CHILD_FILE="$SANDBOX/children"
  export FAKE_SPAWN_COUNT="$SANDBOX/spawns"
  : >"$FAKE_CHILD_FILE"
  : >"$FAKE_SPAWN_COUNT"

  cat >"$SANDBOX/fakebin/autossh" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'spawn\n' >>"$FAKE_SPAWN_COUNT"
pid=$$
start_id=$((100000 + pid))
child=$((200000 + pid))
dir="$SOCKSCTL_PROC_ROOT/$pid"
mkdir -p "$dir"
rm -f "$dir/exe"
ln -s "$0" "$dir/exe"
printf 'autossh\n' >"$dir/comm"
printf 'SOCKSCTL_PROFILE=%s\0AUTOSSH_GATETIME=%s\0' "${SOCKSCTL_PROFILE:-}" "${AUTOSSH_GATETIME:-}" >"$dir/environ"
{
  printf '%s (autossh) S' "$pid"
  for i in $(seq 1 18); do printf ' 0'; done
  printf ' %s\n' "$start_id"
} >"$dir/stat"
printf '%s %s\n' "$pid" "$child" >>"$FAKE_CHILD_FILE"
cleanup() {
  rm -rf "$dir"
  awk -v p="$pid" '$1 != p' "$FAKE_CHILD_FILE" >"$FAKE_CHILD_FILE.tmp" 2>/dev/null || true
  mv -f "$FAKE_CHILD_FILE.tmp" "$FAKE_CHILD_FILE" 2>/dev/null || true
}
trap 'cleanup; exit 0' TERM INT
trap 'cleanup' EXIT
if [[ "${FAKE_EXIT_EARLY:-0}" == 1 ]]; then
  sleep 0.4
  exit 0
fi
while :; do sleep 1; done
EOF

  cat >"$SANDBOX/fakebin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$SANDBOX/fakebin/pgrep" <<'EOF'
#!/usr/bin/env bash
pid=""
while (($#)); do
  if [[ "$1" == "-P" ]]; then
    pid="$2"
    shift 2
  else
    shift
  fi
done
[[ -n "$pid" ]] || exit 1
awk -v p="$pid" '$1 == p {print $2}' "$FAKE_CHILD_FILE"
EOF

  cat >"$SANDBOX/fakebin/ss" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_READY:-1}" == 1 ]] || exit 0
child="$(tail -n 1 "$FAKE_CHILD_FILE" 2>/dev/null | awk '{print $2}')"
[[ -n "$child" ]] || exit 0
printf 'LISTEN 0 128 127.0.0.1:18080 0.0.0.0:* users:(("ssh",pid=%s,fd=4))\n' "$child"
EOF

  cat >"$SANDBOX/fakebin/nc" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_NC_READY:-1}" == 1 ]]
EOF
  chmod +x "$SANDBOX/fakebin/"*
}

teardown() {
  if [[ -f "$XDG_STATE_HOME/socksctl/p.state" ]]; then
    local pid
    pid="$(sed -n 's/^PID=//p' "$XDG_STATE_HOME/socksctl/p.state" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  fi
  teardown_sandbox
}

@test "start reaches READY only after owned listener and stop removes verified runtime state" {
  export FAKE_READY=1
  run "$SUT" start p
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tunnel READY"* ]]
  [ -f "$XDG_STATE_HOME/socksctl/p.state" ]
  grep -qx 'PHASE=READY' "$XDG_STATE_HOME/socksctl/p.state"
  [ "$(wc -l <"$FAKE_SPAWN_COUNT")" -eq 1 ]

  local pid
  pid="$(sed -n 's/^PID=//p' "$XDG_STATE_HOME/socksctl/p.state")"
  kill -0 "$pid"

  run "$SUT" stop p
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_STATE_HOME/socksctl/p.state" ]
  [ -f "$XDG_STATE_HOME/socksctl/p.lock" ]
}

@test "new start timeout terminates only its MATCH supervisor and cleans state" {
  export FAKE_READY=0
  run "$SUT" start p
  [ "$status" -eq 1 ]
  [ ! -e "$XDG_STATE_HOME/socksctl/p.state" ]
  [ "$(wc -l <"$FAKE_SPAWN_COUNT")" -eq 1 ]
}

@test "existing DEGRADED start waits without spawning a second autossh" {
  export FAKE_READY=1
  run "$SUT" start p
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$FAKE_SPAWN_COUNT")" -eq 1 ]

  export FAKE_READY=0
  run "$SUT" start p
  [ "$status" -eq 1 ]
  [ "$(wc -l <"$FAKE_SPAWN_COUNT")" -eq 1 ]
  [ -f "$XDG_STATE_HOME/socksctl/p.state" ]

  run "$SUT" stop p
  [ "$status" -eq 0 ]
}

@test "process early exit after state creation is operational failure and state is cleaned" {
  export FAKE_READY=0
  export FAKE_EXIT_EARLY=1
  run "$SUT" start p
  [ "$status" -eq 1 ]
  [ ! -e "$XDG_STATE_HOME/socksctl/p.state" ]
}

@test "UNKNOWN identity refuses a second start and preserves state" {
  export FAKE_READY=1
  run "$SUT" start p
  [ "$status" -eq 0 ]
  local pid
  pid="$(sed -n 's/^PID=//p' "$XDG_STATE_HOME/socksctl/p.state")"
  rm -f "$SOCKSCTL_PROC_ROOT/$pid/stat"

  run "$SUT" start p
  [ "$status" -eq 4 ]
  [ -f "$XDG_STATE_HOME/socksctl/p.state" ]
  [ "$(wc -l <"$FAKE_SPAWN_COUNT")" -eq 1 ]

  kill "$pid" 2>/dev/null || true
  rm -rf "$SOCKSCTL_PROC_ROOT/$pid"
  rm -f "$XDG_STATE_HOME/socksctl/p.state"
}

@test "restart takes one outer lock and does not deadlock" {
  export FAKE_READY=1
  run "$SUT" start p
  [ "$status" -eq 0 ]

  run "$SUT" restart p
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$FAKE_SPAWN_COUNT")" -eq 2 ]

  run "$SUT" stop p
  [ "$status" -eq 0 ]
}

@test "concurrent starts for one profile spawn only one autossh" {
  export FAKE_READY=1

  "$SUT" start p >"$SANDBOX/start-one.log" 2>&1 &
  local first=$!
  "$SUT" start p >"$SANDBOX/start-two.log" 2>&1 &
  local second=$!

  wait "$first"
  wait "$second"
  [ "$(wc -l <"$FAKE_SPAWN_COUNT")" -eq 1 ]

  run "$SUT" stop p
  [ "$status" -eq 0 ]
}

@test "remove running profile does not recursively acquire the lock" {
  export FAKE_READY=1
  run "$SUT" start p
  [ "$status" -eq 0 ]

  run env SOCKSCTL_ASSUME_YES=1 "$SUT" remove p
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_CONFIG_HOME/socksctl/profiles/p.conf" ]
  [ ! -e "$XDG_STATE_HOME/socksctl/p.state" ]
  [ -f "$XDG_STATE_HOME/socksctl/p.lock" ]
}

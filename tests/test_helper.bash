SUT="${BATS_TEST_DIRNAME}/../socksctl"

setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export XDG_CONFIG_HOME="$SANDBOX/config"
  export XDG_STATE_HOME="$SANDBOX/state"
  export SOCKSCTL_PROC_ROOT="$SANDBOX/proc"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME/socksctl/profiles" "$XDG_STATE_HOME/socksctl" "$SOCKSCTL_PROC_ROOT"
}

teardown_sandbox() {
  if [[ -n "${RUNNING_FAKE_PID:-}" ]]; then
    kill "$RUNNING_FAKE_PID" 2>/dev/null || true
  fi
  rm -rf "$SANDBOX"
}

write_v2_profile() {
  local name="$1"
  local listen_host="${2:-127.0.0.1}"
  local listen_port="${3:-18080}"
  local client_host="${4:-127.0.0.1}"
  local client_port="${5:-18080}"
  local auto="${6:-none}"
  cat >"$XDG_CONFIG_HOME/socksctl/profiles/$name.conf" <<EOF
PROFILE_VERSION=2
HOST=example.com
USER_NAME=ubuntu
SSH_PORT=22
KEY=
LISTEN_HOST=$listen_host
LISTEN_PORT=$listen_port
CLIENT_HOST=$client_host
CLIENT_PORT=$client_port
AUTO_ACTIVATE=$auto
EOF
  chmod 600 "$XDG_CONFIG_HOME/socksctl/profiles/$name.conf"
}

make_fake_proc() {
  local pid="$1" profile="$2" start_id="$3"
  local dir="$SOCKSCTL_PROC_ROOT/$pid"
  mkdir -p "$dir" "$SANDBOX/bin"
  : >"$SANDBOX/bin/autossh"
  rm -f "$dir/exe"
  ln -s "$SANDBOX/bin/autossh" "$dir/exe"
  printf 'autossh\n' >"$dir/comm"
  printf 'SOCKSCTL_PROFILE=%s\0' "$profile" >"$dir/environ"
  {
    printf '%s (autossh) S' "$pid"
    local i
    for i in $(seq 1 18); do printf ' 0'; done
    printf ' %s\n' "$start_id"
  } >"$dir/stat"
}

write_runtime_state() {
  local name="$1" pid="$2" start_id="$3" phase="${4:-READY}"
  cat >"$XDG_STATE_HOME/socksctl/$name.state" <<EOF
PID=$pid
PROCESS_START_ID=$start_id
STARTED_AT=2026-10-07T00:00:00Z
PHASE=$phase
HOST=example.com
USER_NAME=ubuntu
SSH_PORT=22
KEY=
LISTEN_HOST=127.0.0.1
LISTEN_PORT=18080
CLIENT_HOST=127.0.0.1
CLIENT_PORT=18080
AUTO_ACTIVATE=none
EOF
  chmod 600 "$XDG_STATE_HOME/socksctl/$name.state"
}

make_ready_stubs() {
  local child_pid="${1:-200}"
  mkdir -p "$SANDBOX/fakebin"
  cat >"$SANDBOX/fakebin/pgrep" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$child_pid"
EOF
  cat >"$SANDBOX/fakebin/ss" <<EOF
#!/usr/bin/env bash
printf '%s\n' 'LISTEN 0 128 127.0.0.1:18080 0.0.0.0:* users:(("ssh",pid=$child_pid,fd=4))'
EOF
  cat >"$SANDBOX/fakebin/nc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$SANDBOX/fakebin/"*
  export PATH="$SANDBOX/fakebin:$PATH"
}

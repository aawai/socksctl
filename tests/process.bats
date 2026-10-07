#!/usr/bin/env bats

load test_helper

setup() {
  setup_sandbox
  export SOCKSCTL_LIB_ONLY=1
  # shellcheck disable=SC1090
  source "$SUT"
}

teardown() {
  teardown_sandbox
}

@test "process identity returns MATCH, MISMATCH and UNKNOWN distinctly" {
  make_fake_proc 123 p 4242

  [ "$(process_identity p 123 4242)" = "MATCH" ]
  [ "$(process_identity p 123 4243)" = "MISMATCH" ]
  [ "$(process_identity other 123 4242)" = "MISMATCH" ]

  rm -f "$SOCKSCTL_PROC_ROOT/123/stat"
  [ "$(process_identity p 123 4242)" = "UNKNOWN" ]

  rm -rf "$SOCKSCTL_PROC_ROOT/123"
  [ "$(process_identity p 123 4242)" = "MISSING" ]
}

@test "UNKNOWN stop fails closed and preserves runtime state" {
  write_v2_profile p
  write_runtime_state p 123 4242 READY
  mkdir -p "$SOCKSCTL_PROC_ROOT/123"
  # PID exists, but stat/exe/environ cannot be verified => UNKNOWN.

  run _stop_locked p
  [ "$status" -eq 4 ]
  [ -f "$XDG_STATE_HOME/socksctl/p.state" ]
}

@test "MISMATCH stop cleans stale state without killing reused PID" {
  write_v2_profile p
  write_runtime_state p 123 4242 READY
  make_fake_proc 123 p 9999

  run _stop_locked p
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_STATE_HOME/socksctl/p.state" ]
  [ -d "$SOCKSCTL_PROC_ROOT/123" ]
}

@test "readiness requires listener ownership by the current ssh child" {
  write_v2_profile p
  write_runtime_state p 123 4242 READY
  make_fake_proc 123 p 4242
  make_ready_stubs 200

  tunnel_state_for p
  [ "$TUNNEL_STATE" = "READY" ]
  [ "$IDENTITY_STATE" = "MATCH" ]

  cat >"$SANDBOX/fakebin/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'LISTEN 0 128 127.0.0.1:18080 0.0.0.0:* users:(("ssh",pid=201,fd=4))'
EOF
  chmod +x "$SANDBOX/fakebin/ss"
  tunnel_state_for p
  [ "$TUNNEL_STATE" = "DEGRADED" ]
}

@test "autossh with no listener is DEGRADED" {
  write_v2_profile p
  write_runtime_state p 123 4242 READY
  make_fake_proc 123 p 4242
  make_ready_stubs 200
  cat >"$SANDBOX/fakebin/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$SANDBOX/fakebin/ss"

  tunnel_state_for p
  [ "$TUNNEL_STATE" = "DEGRADED" ]
}

@test "lock timeout returns exit 4 and lock file remains stable" {
  write_v2_profile p
  export LOCK_TIMEOUT=0.1
  local lock="$XDG_STATE_HOME/socksctl/p.lock"
  : >"$lock"
  exec 9>"$lock"
  flock 9

  run with_profile_lock p true
  [ "$status" -eq 4 ]
  [ -f "$lock" ]

  flock -u 9
  exec 9>&-
}

@test "runtime config drift ignores activation-only changes" {
  write_v2_profile p
  write_runtime_state p 123 4242 READY
  make_fake_proc 123 p 4242
  make_ready_stubs 200

  load_profile p
  load_runtime_state p
  tunnel_config_drift
  activation_config_drift

  CLIENT_HOST="127.0.0.2"
  tunnel_config_drift
  run activation_config_drift
  [ "$status" -ne 0 ]

  LISTEN_PORT=18081
  run tunnel_config_drift
  [ "$status" -ne 0 ]
}

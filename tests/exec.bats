#!/usr/bin/env bats

load test_helper

setup() {
  setup_sandbox
  write_v2_profile p
  write_runtime_state p 123 4242 READY
  make_fake_proc 123 p 4242
  make_ready_stubs 200
}

teardown() {
  teardown_sandbox
}

@test "exec sets SOCKS env in child and leaves parent env unchanged" {
  export ALL_PROXY="parent"
  run "$SUT" exec p -- bash -c '
    [[ "$all_proxy" == "socks5h://127.0.0.1:18080" ]]
    [[ "$ALL_PROXY" == "$all_proxy" ]]
    [[ "$socks_proxy" == "$all_proxy" ]]
    [[ "$SOCKS_PROXY" == "$all_proxy" ]]
    [[ "$no_proxy" == "localhost,127.0.0.1,::1,.local" ]]
    [[ -z "${HTTP_PROXY-}" ]]
  '
  [ "$status" -eq 0 ]
  [ "$ALL_PROXY" = "parent" ]
}

@test "exec passes through child exit code" {
  run "$SUT" exec p -- bash -c 'exit 42'
  [ "$status" -eq 42 ]
}

@test "exec returns 127 for command not found" {
  run "$SUT" exec p -- definitely-not-a-command
  [ "$status" -eq 127 ]
}

@test "exec requires explicit double dash" {
  run "$SUT" exec p bash -c true
  [ "$status" -eq 2 ]
}

@test "exec returns 125 when tunnel is not READY" {
  rm -f "$XDG_STATE_HOME/socksctl/p.state"
  run "$SUT" exec p -- true
  [ "$status" -eq 125 ]
}

@test "exec returns 125 when client endpoint is unreachable" {
  cat >"$SANDBOX/fakebin/nc" <<'EOF'
#!/usr/bin/env bash
# readiness probe (listener) succeeds once, client probe can be forced to fail
if [[ "${FAKE_CLIENT_FAIL:-0}" == 1 ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$SANDBOX/fakebin/nc"
  export FAKE_CLIENT_FAIL=1
  run "$SUT" exec p -- true
  [ "$status" -eq 125 ]
}

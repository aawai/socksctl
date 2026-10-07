#!/usr/bin/env bats

load test_helper

setup() {
  setup_sandbox
  mkdir -p "$SANDBOX/fakebin"
  "$SUT" shell-init bash >"$SANDBOX/init.sh"

  cat >"$SANDBOX/fakebin/socksctl" <<'EOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  machine)
    case "${2:-}" in
      current) printf '%s\n' "${FAKE_CURRENT:-p}" ;;
      tunnel-state)
        printf '%s\n' "${FAKE_TUNNEL_STATE:-READY}"
        if [[ "${FAKE_TUNNEL_STATE:-READY}" == UNKNOWN ]]; then exit 4; fi
        exit 0
        ;;
      activation)
        profile="${3:-p}"
        auto="${FAKE_AUTO:-shell}"
        if [[ "$profile" == q ]]; then
          printf '%s\n%s\n%s\n' "$auto" 127.0.0.1 18081
        else
          printf '%s\n%s\n%s\n' "$auto" 127.0.0.1 18080
        fi
        ;;
      *) exit 2 ;;
    esac
    ;;
  start|stop|stop-all)
    exit "${FAKE_BACKEND_RC:-0}"
    ;;
  restart)
    exit "${FAKE_RESTART_RC:-0}"
    ;;
  status|list)
    printf 'active=%s\n' "${SOCKSCTL_CALLER_ACTIVE_PROFILE:-}"
    ;;
  *)
    exit 0
    ;;
esac
EOF

  cat >"$SANDBOX/fakebin/nc" <<'EOF'
#!/usr/bin/env bash
exit "${FAKE_NC_RC:-0}"
EOF
  chmod +x "$SANDBOX/fakebin/"*
}

teardown() {
  teardown_sandbox
}

@test "activate/deactivate restores unset, unexported, exported and empty values exactly" {
  run env PATH="$SANDBOX/fakebin:$PATH" INIT="$SANDBOX/init.sh" bash -c '
    set -e
    set -u
    unset all_proxy
    ALL_PROXY=""
    export -n ALL_PROXY
    export socks_proxy=""
    export SOCKS_PROXY="before"
    http_proxy="plain"
    export -n http_proxy
    unset HTTP_PROXY https_proxy HTTPS_PROXY ftp_proxy FTP_PROXY no_proxy NO_PROXY

    # shellcheck disable=SC1090
    source "$INIT"
    socksctl activate p

    [[ "$all_proxy" == "socks5h://127.0.0.1:18080" ]]
    [[ "$ALL_PROXY" == "$all_proxy" ]]
    [[ "$SOCKSCTL_ACTIVE_PROFILE" == p ]]
    ! env | grep -q "^SOCKSCTL_ACTIVE_PROFILE="

    socksctl deactivate

    ! declare -p all_proxy >/dev/null 2>&1
    d="$(declare -p ALL_PROXY)"
    [[ "$d" != declare\ -x* ]]
    [[ "$ALL_PROXY" == "" ]]
    d="$(declare -p socks_proxy)"
    [[ "$d" == declare\ -x* ]]
    [[ "$socks_proxy" == "" ]]
    d="$(declare -p SOCKS_PROXY)"
    [[ "$d" == declare\ -x* ]]
    [[ "$SOCKS_PROXY" == before ]]
    d="$(declare -p http_proxy)"
    [[ "$d" != declare\ -x* ]]
    [[ "$http_proxy" == plain ]]
    ! declare -p SOCKSCTL_ACTIVE_PROFILE >/dev/null 2>&1
  '
  if [ "$status" -ne 0 ]; then echo "RESTORE ERROR (status=$status): $output" >&3; fi
  [ "$status" -eq 0 ]
}

@test "profile switch keeps the first snapshot until final deactivate" {
  run env PATH="$SANDBOX/fakebin:$PATH" INIT="$SANDBOX/init.sh" bash -c '
    set -e
    export ALL_PROXY=original
    source "$INIT"
    socksctl activate p
    [[ "$ALL_PROXY" == "socks5h://127.0.0.1:18080" ]]
    socksctl activate q
    [[ "$ALL_PROXY" == "socks5h://127.0.0.1:18081" ]]
    [[ "$SOCKSCTL_ACTIVE_PROFILE" == q ]]
    socksctl deactivate
    [[ "$ALL_PROXY" == original ]]
  '
  [ "$status" -eq 0 ]
}

@test "readonly managed variable fails preflight with no partial shell mutation" {
  run env PATH="$SANDBOX/fakebin:$PATH" INIT="$SANDBOX/init.sh" bash -c '
    set -e
    readonly HTTP_PROXY=locked
    export ALL_PROXY=before
    source "$INIT"
    if socksctl activate p; then exit 90; fi
    [[ "$HTTP_PROXY" == locked ]]
    [[ "$ALL_PROXY" == before ]]
    [[ "${SOCKSCTL_ACTIVE_PROFILE-}" == "" ]]
  '
  [ "$status" -eq 0 ]
}


@test "apply failure rolls back transaction and clears a first failed snapshot" {
  run env PATH="$SANDBOX/fakebin:$PATH" INIT="$SANDBOX/init.sh" bash -c '
    set -e
    export ALL_PROXY=before
    source "$INIT"
    __socksctl_assign_exported() {
      local var="$1" value="$2"
      if [[ "$var" == SOCKS_PROXY ]]; then
        return 1
      fi
      printf -v "$var" "%s" "$value"
      export "$var"
    }
    if socksctl activate p; then exit 91; fi
    [[ "$ALL_PROXY" == before ]]
    [[ "${SOCKSCTL_ACTIVE_PROFILE-}" == "" ]]
    [[ "$__SOCKSCTL_SNAPSHOT_VALID" -eq 0 ]]

    ALL_PROXY=changed
    __socksctl_assign_exported() {
      local var="$1" value="$2"
      printf -v "$var" "%s" "$value"
      export "$var"
    }
    socksctl activate p
    socksctl deactivate
    [[ "$ALL_PROXY" == changed ]]
  '
  [ "$status" -eq 0 ]
}

@test "AUTO_ACTIVATE none leaves shell unchanged while shell mode activates" {
  run env PATH="$SANDBOX/fakebin:$PATH" INIT="$SANDBOX/init.sh" FAKE_AUTO=none bash -c '
    set -e
    export ALL_PROXY=before
    source "$INIT"
    socksctl start p
    [[ "$ALL_PROXY" == before ]]
    [[ "${SOCKSCTL_ACTIVE_PROFILE-}" == "" ]]
  '
  [ "$status" -eq 0 ]

  run env PATH="$SANDBOX/fakebin:$PATH" INIT="$SANDBOX/init.sh" FAKE_AUTO=shell bash -c '
    set -e
    export ALL_PROXY=before
    source "$INIT"
    socksctl start p
    [[ "$ALL_PROXY" == "socks5h://127.0.0.1:18080" ]]
    [[ "$SOCKSCTL_ACTIVE_PROFILE" == p ]]
  '
  if [ "$status" -ne 0 ]; then echo "AUTO_ACTIVATE shell failure (status=$status): $output" >&3; fi
  [ "$status" -eq 0 ]
}

@test "auto activation failure leaves READY tunnel but rolls shell back and returns 1" {
  run env PATH="$SANDBOX/fakebin:$PATH" INIT="$SANDBOX/init.sh" FAKE_AUTO=shell FAKE_NC_RC=1 bash -c '
    set -e
    export ALL_PROXY=before
    source "$INIT"
    set +e
    socksctl start p
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    [[ "$ALL_PROXY" == before ]]
    [[ "${SOCKSCTL_ACTIVE_PROFILE-}" == "" ]]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tunnel READY, shell activation failed"* ]]
}

@test "stop active profile deactivates; stop other profile does not" {
  run env PATH="$SANDBOX/fakebin:$PATH" INIT="$SANDBOX/init.sh" bash -c '
    set -e
    export ALL_PROXY=before
    source "$INIT"
    socksctl activate p
    socksctl stop q
    [[ "$SOCKSCTL_ACTIVE_PROFILE" == p ]]
    [[ "$ALL_PROXY" == "socks5h://127.0.0.1:18080" ]]
    socksctl stop p
    [[ "$ALL_PROXY" == before ]]
    [[ "${SOCKSCTL_ACTIVE_PROFILE-}" == "" ]]
  '
  [ "$status" -eq 0 ]
}

@test "restart active failure deactivates and successful restart reapplies" {
  run env PATH="$SANDBOX/fakebin:$PATH" INIT="$SANDBOX/init.sh" FAKE_RESTART_RC=1 bash -c '
    set -e
    export ALL_PROXY=before
    source "$INIT"
    socksctl activate p
    set +e
    socksctl restart p
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    [[ "$ALL_PROXY" == before ]]
    [[ "${SOCKSCTL_ACTIVE_PROFILE-}" == "" ]]
  '
  [ "$status" -eq 0 ]

  run env PATH="$SANDBOX/fakebin:$PATH" INIT="$SANDBOX/init.sh" FAKE_RESTART_RC=0 bash -c '
    set -e
    export ALL_PROXY=before
    source "$INIT"
    socksctl activate p
    socksctl restart p
    [[ "$SOCKSCTL_ACTIVE_PROFILE" == p ]]
    [[ "$ALL_PROXY" == "socks5h://127.0.0.1:18080" ]]
    socksctl deactivate
    [[ "$ALL_PROXY" == before ]]
  '
  [ "$status" -eq 0 ]
}

@test "stop-all deactivates and generated shell init works under set -u" {
  run env PATH="$SANDBOX/fakebin:$PATH" INIT="$SANDBOX/init.sh" bash -c '
    set -e
    set -u
    export ALL_PROXY=before
    source "$INIT"
    socksctl activate p
    socksctl stop-all
    [[ "$ALL_PROXY" == before ]]
    [[ "${SOCKSCTL_ACTIVE_PROFILE-}" == "" ]]
  '
  [ "$status" -eq 0 ]
}

@test "child shell does not inherit a false ACTIVE marker" {
  run env PATH="$SANDBOX/fakebin:$PATH" INIT="$SANDBOX/init.sh" bash -c '
    set -e
    source "$INIT"
    socksctl activate p
    bash -c "[[ -z \"\${SOCKSCTL_ACTIVE_PROFILE-}\" ]]"
  '
  [ "$status" -eq 0 ]
}

@test "status wrapper passes the shell-local marker only for the backend query" {
  run env PATH="$SANDBOX/fakebin:$PATH" INIT="$SANDBOX/init.sh" bash -c '
    set -e
    source "$INIT"
    socksctl activate p
    out="$(socksctl status p)"
    [[ "$out" == "active=p" ]]
    ! env | grep -q "^SOCKSCTL_ACTIVE_PROFILE="
  '
  [ "$status" -eq 0 ]
}

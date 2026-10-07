#!/usr/bin/env bats

load test_helper

setup() {
  setup_sandbox
}

teardown() {
  teardown_sandbox
}

@test "legacy v1 maps listener/client and disables auto activation" {
  cat >"$XDG_CONFIG_HOME/socksctl/profiles/legacy.conf" <<'EOF'
HOST=example.com
USER_NAME=ubuntu
SSH_PORT=22
KEY=''
BIND=0.0.0.0
PORT=18080
EOF

  run "$SUT" show legacy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Profile Version: 1 (legacy mapped in memory)"* ]]
  [[ "$output" == *"Listen:          0.0.0.0:18080"* ]]
  [[ "$output" == *"Client Proxy:    socks5h://127.0.0.1:18080"* ]]
  [[ "$output" == *"Auto Activate:   none"* ]]
}

@test "v2 parser never executes profile values" {
  local marker="$SANDBOX/executed"
  cat >"$XDG_CONFIG_HOME/socksctl/profiles/safe.conf" <<EOF
PROFILE_VERSION=2
HOST=\$(touch $marker)
USER_NAME=ubuntu
SSH_PORT=22
KEY=
LISTEN_HOST=127.0.0.1
LISTEN_PORT=18080
CLIENT_HOST=127.0.0.1
CLIENT_PORT=18080
AUTO_ACTIVATE=none
EOF
  run "$SUT" show safe
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "v2 parser rejects unknown and duplicate keys" {
  write_v2_profile bad
  printf 'SURPRISE=value\n' >>"$XDG_CONFIG_HOME/socksctl/profiles/bad.conf"
  run "$SUT" show bad
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown key SURPRISE"* ]]

  write_v2_profile dup
  printf 'HOST=second.example\n' >>"$XDG_CONFIG_HOME/socksctl/profiles/dup.conf"
  run "$SUT" show dup
  [ "$status" -eq 2 ]
  [[ "$output" == *"duplicate key HOST"* ]]
}

@test "validation rejects invalid ports and auto activation values" {
  local value
  for value in 0 65536 -1 abc ""; do
    write_v2_profile badport
    python3 - "$XDG_CONFIG_HOME/socksctl/profiles/badport.conf" "$value" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
v=sys.argv[2]
s=p.read_text().replace("LISTEN_PORT=18080", "LISTEN_PORT="+v)
p.write_text(s)
PY
    run "$SUT" show badport
    [ "$status" -eq 2 ]
  done

  write_v2_profile badauto
  sed -i 's/AUTO_ACTIVATE=none/AUTO_ACTIVATE=always/' "$XDG_CONFIG_HOME/socksctl/profiles/badauto.conf"
  run "$SUT" show badauto
  [ "$status" -eq 2 ]
}

@test "validation rejects empty required text fields" {
  write_v2_profile bad
  sed -i 's/USER_NAME=ubuntu/USER_NAME=/' "$XDG_CONFIG_HOME/socksctl/profiles/bad.conf"
  run "$SUT" show bad
  [ "$status" -eq 2 ]

  write_v2_profile bad
  sed -i 's/LISTEN_HOST=127.0.0.1/LISTEN_HOST=/' "$XDG_CONFIG_HOME/socksctl/profiles/bad.conf"
  run "$SUT" show bad
  [ "$status" -eq 2 ]
}

@test "IPv6 bind and SOCKS URI formatting are bracketed" {
  write_v2_profile v6 "::" 18080 "::1" 18080 shell
  run "$SUT" show v6
  [ "$status" -eq 0 ]
  [[ "$output" == *"Listen:          [::]:18080"* ]]
  [[ "$output" == *"Client Proxy:    socks5h://[::1]:18080"* ]]
}

@test "legacy edit/save migrates to v2 without changing start behavior" {
  cat >"$XDG_CONFIG_HOME/socksctl/profiles/legacy.conf" <<'EOF'
HOST=example.com
USER_NAME=ubuntu
SSH_PORT=22
KEY=''
BIND=127.0.0.1
PORT=18080
EOF
  printf 'legacy\n' >"$XDG_CONFIG_HOME/socksctl/current"

  run bash -c 'printf "\n\n\n\n\n\n\n\n\n" | "$1" edit legacy' _ "$SUT"
  [ "$status" -eq 0 ]
  grep -qx 'PROFILE_VERSION=2' "$XDG_CONFIG_HOME/socksctl/profiles/legacy.conf"
  grep -qx 'AUTO_ACTIVATE=none' "$XDG_CONFIG_HOME/socksctl/profiles/legacy.conf"
}

@test "new profile inherits only user ssh-port key and listen-host and suggests fresh port" {
  write_v2_profile base 127.0.0.1 18080 127.0.0.1 19000 none
  printf 'base\n' >"$XDG_CONFIG_HOME/socksctl/current"

  run bash -c 'printf "new.example\n\n\n\n\n\n\n\n\n" | "$1" add child' _ "$SUT"
  [ "$status" -eq 0 ]
  local file="$XDG_CONFIG_HOME/socksctl/profiles/child.conf"
  grep -qx 'HOST=new.example' "$file"
  grep -qx 'USER_NAME=ubuntu' "$file"
  grep -qx 'SSH_PORT=22' "$file"
  grep -qx 'LISTEN_HOST=127.0.0.1' "$file"
  grep -qx 'LISTEN_PORT=18081' "$file"
  grep -qx 'CLIENT_PORT=18081' "$file"
  grep -qx 'AUTO_ACTIVATE=shell' "$file"
}

@test "current updates atomically and remove-current picks first remaining profile" {
  write_v2_profile zeta 127.0.0.1 18082 127.0.0.1 18082 none
  write_v2_profile alpha 127.0.0.1 18081 127.0.0.1 18081 none
  write_v2_profile current 127.0.0.1 18080 127.0.0.1 18080 none

  run "$SUT" use current
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$XDG_CONFIG_HOME/socksctl/current")" = "600" ]

  run "$SUT" remove current
  [ "$status" -eq 0 ]
  [ "$(cat "$XDG_CONFIG_HOME/socksctl/current")" = "alpha" ]
  [ -f "$XDG_STATE_HOME/socksctl/current.lock" ]
}

@test "profile name cannot traverse outside the profiles directory" {
  write_v2_profile p
  cp "$XDG_CONFIG_HOME/socksctl/profiles/p.conf" "$XDG_CONFIG_HOME/socksctl/escape.conf"

  run "$SUT" show ../escape
  [ "$status" -eq 2 ]
  run "$SUT" use ../escape
  [ "$status" -eq 2 ]
}

@test "CLI rejects extra arguments" {
  write_v2_profile p
  run "$SUT" show p extra
  [ "$status" -eq 2 ]
}

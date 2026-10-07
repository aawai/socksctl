# socksctl

`socksctl` is a Linux/Bash manager for **SOCKS5 over SSH**. It runs one `autossh` supervisor per profile, verifies that the expected `ssh -D` listener is actually owned by that supervisor's current SSH child, and optionally activates the SOCKS endpoint in the calling Bash shell.

It is intentionally **not** a transparent proxy. It does not configure TUN, nftables/iptables/TPROXY, desktop proxy settings, system-wide proxy settings, or force applications that ignore proxy environment variables through SOCKS.

## 1. Tunnel, Listener, Client, and Auto Activation

A profile has four separate concepts:

- **Tunnel** — the SSH/autossh lifecycle.
- **Listener** — the address passed to `ssh -D`.
- **Client endpoint** — the SOCKS endpoint used by `socksctl test`, `socksctl exec`, and shell activation.
- **Auto activation** — whether a successful `socksctl start` should activate the current Bash shell.

The central rule is:

```text
LISTEN_HOST != CLIENT_HOST
```

They may have the same value, but they have different meanings and are never inferred from one another at runtime.

A v2 profile is:

```text
PROFILE_VERSION=2
HOST=203.0.113.10
USER_NAME=ubuntu
SSH_PORT=22
KEY=/home/user/.ssh/id_ed25519
LISTEN_HOST=127.0.0.1
LISTEN_PORT=18080
CLIENT_HOST=127.0.0.1
CLIENT_PORT=18080
AUTO_ACTIVATE=shell
```

`AUTO_ACTIVATE` accepts only `none` or `shell`. It controls what happens after `start` reaches `READY`; it does not disable explicit `activate`, `exec`, or `test`.

## 2. Linux / Bash dependencies

Supported runtime:

```text
Linux
Bash >= 4
OpenSSH client
autossh
util-linux flock
procps (ps, pgrep)
iproute2 (ss)
nc / netcat
```

The script also uses standard Linux userland tools such as `grep`, `awk`, `od`, `readlink`, `mktemp`, `mv`, and `chmod`.

Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y \
  bash openssh-client autossh util-linux procps iproute2 netcat-openbsd
```

`curl` is optional and required only for `socksctl test`.

Private keys with passphrases must already be available through `ssh-agent`; background autossh is started with `BatchMode=yes` and cannot prompt interactively.

## 3. Installation

```bash
git clone https://github.com/aawai/socksctl.git
cd socksctl
sudo install -m 755 socksctl /usr/local/bin/socksctl
```

Check the CLI:

```bash
socksctl help
```

Configuration and runtime data follow XDG paths:

```text
~/.config/socksctl/
├── current
└── profiles/
    └── <profile>.conf

~/.local/state/socksctl/
├── <profile>.state
├── <profile>.lock
└── <profile>.log
```

Directories are mode `700`; profile/current/runtime/log/lock files are mode `600`.

## 4. Bash integration

To let `socksctl` modify the **current** shell, add this once to `~/.bashrc`:

```bash
eval "$(socksctl shell-init bash)"
```

Reload Bash:

```bash
source ~/.bashrc
```

The generated wrapper calls the backend with `command socksctl ...`, so it does not recurse into itself.

Direct executable invocation cannot modify its parent shell:

```bash
/usr/local/bin/socksctl activate local
```

That form exits with code `2` and tells you to install shell integration.

Shell activation affects only the current shell and child processes started after activation.

## 5. Local profile

Create a profile:

```bash
socksctl add local
```

Recommended values:

```text
SSH Host: 203.0.113.10
SSH User [ubuntu]:
SSH Port [22]:
Private Key: ~/.ssh/id_ed25519
Listen Host [127.0.0.1]:
Listen Port [18080]:
Client Host [127.0.0.1]:
Client Port [18080]:
Auto Activate [shell]:
```

Start it:

```bash
socksctl start local
```

With Bash integration and `AUTO_ACTIVATE=shell`, a successful `READY` start exports:

```text
all_proxy
ALL_PROXY
socks_proxy
SOCKS_PROXY
no_proxy
NO_PROXY
```

using:

```text
socks5h://127.0.0.1:18080
```

and unsets protocol-specific `HTTP/HTTPS/FTP` proxy variables while active.

Default `NO_PROXY` is:

```text
localhost,127.0.0.1,::1,.local
```

Override it with `SOCKSCTL_NO_PROXY`.

## 6. Docker-only profile

A listener intended for containers can use a Docker bridge address without changing the host shell:

```text
PROFILE_VERSION=2
HOST=203.0.113.10
USER_NAME=ubuntu
SSH_PORT=22
KEY=
LISTEN_HOST=172.18.0.1
LISTEN_PORT=18080
CLIENT_HOST=172.18.0.1
CLIENT_PORT=18080
AUTO_ACTIVATE=none
```

Then:

```bash
socksctl start docker
```

starts and verifies the tunnel but leaves the calling shell unchanged.

Non-loopback listeners produce a security warning during interactive create/edit because reachability depends on routing and firewall rules.

## 7. Wildcard listener + local client

A wildcard listener and a local client endpoint are deliberately separate:

```text
LISTEN_HOST=0.0.0.0
LISTEN_PORT=18080
CLIENT_HOST=127.0.0.1
CLIENT_PORT=18080
AUTO_ACTIVATE=shell
```

The SSH bind is:

```text
0.0.0.0:18080
```

but shell activation uses:

```text
socks5h://127.0.0.1:18080
```

It never generates `socks5h://0.0.0.0:18080`.

Wildcard listeners (`0.0.0.0`, `::`, `*`) require explicit confirmation during interactive create/edit because they can expose an unauthenticated SOCKS listener on all matching interfaces.

IPv6 is bracketed correctly:

```text
LISTEN_HOST=::
CLIENT_HOST=::1
```

becomes:

```text
ssh -D [::]:18080
socks5h://[::1]:18080
```

## 8. Multiple profiles

Different profiles may run concurrently:

```bash
socksctl start proxy-a
socksctl start proxy-b
socksctl start docker
```

List them:

```bash
socksctl list
```

Columns distinguish:

```text
NAME
TUNNEL
DEFAULT
SHELL
LISTEN
CLIENT
AUTO
```

`current` means only the default CLI profile. It is not the shell's active profile.

New profiles inherit only:

```text
USER_NAME
SSH_PORT
KEY
LISTEN_HOST
```

They do **not** inherit:

```text
HOST
LISTEN_PORT
CLIENT_HOST
CLIENT_PORT
AUTO_ACTIVATE
```

Port suggestions start at `18080` and choose the first port not already configured by another v1/v2 profile.

## 9. Activate / deactivate

With Bash integration:

```bash
socksctl activate [profile]
socksctl deactivate
```

Explicit activation is allowed even when `AUTO_ACTIVATE=none`.

Before changing the shell, activation verifies:

1. tunnel state is `READY`;
2. client host/port metadata is valid;
3. the client endpoint accepts a TCP connection;
4. managed proxy variables are not readonly.

The wrapper snapshots each managed variable as one of:

```text
unset
set-unexported
exported
```

plus its exact value, including the empty string.

Activation is transactional. A partial apply restores the shell to the state at the beginning of that activation attempt. Switching from profile A to B does not overwrite the original pre-A snapshot; final `deactivate` restores the exact environment from before A.

`SOCKSCTL_ACTIVE_PROFILE` is shell-local and is **not exported**.

## 10. Command-scoped `exec`

Run one command through a profile without modifying the parent shell:

```bash
socksctl exec local -- curl https://api.ipify.org
```

The `--` delimiter is mandatory.

`exec`:

- requires an existing `READY` tunnel;
- verifies the current `CLIENT_HOST:CLIENT_PORT`;
- clears HTTP/HTTPS/FTP proxy variables in the child;
- sets `ALL_PROXY`/`SOCKS_PROXY` and lowercase equivalents;
- passes through the child exit code;
- returns `127` when the child command is not found;
- returns `125` when a profile/tunnel/client precondition fails;
- never starts the tunnel implicitly.

This works only for programs that honor these proxy environment variables. No `LD_PRELOAD` interception is used.

## 11. Tunnel states: READY / DEGRADED / UNKNOWN

The tunnel state model is:

```text
STOPPED
STARTING
READY
DEGRADED
UNKNOWN
```

`READY` requires all of the following:

1. runtime PID identity is `MATCH`;
2. exactly one current `ssh` child exists under the autossh supervisor;
3. `ss -H -ltnp` shows the expected listener address/port;
4. that listener socket belongs to the discovered SSH child PID;
5. a TCP probe to the listener endpoint succeeds.

An alive autossh PID alone is never considered ready.

`DEGRADED` means autossh identity is still valid but the current SSH child/listener is not ready, for example while autossh is reconnecting.

`UNKNOWN` means a runtime PID exists but process identity cannot be verified due to `/proc` read failures or similar uncertainty. It fails closed:

- runtime state is preserved;
- no PID is killed;
- no second autossh is started;
- start/stop/restart return exit `4`.

## 12. Edit and restart-required

Editing a running profile is allowed:

```bash
socksctl edit local
```

Tunnel fields are:

```text
HOST
USER_NAME
SSH_PORT
KEY
LISTEN_HOST
LISTEN_PORT
```

Changing any of them does not restart automatically. `status` reports:

```text
Tunnel Config:      CHANGED
Restart Required:   yes
```

until:

```bash
socksctl restart local
```

Activation-only fields are:

```text
CLIENT_HOST
CLIENT_PORT
AUTO_ACTIVATE
```

Changing those does not require tunnel restart. The next `activate`, `exec`, or `test` uses the new client configuration.

If the current shell is already active, editing does not mutate that shell immediately; run:

```bash
socksctl activate local
```

to reapply the current activation metadata.

## 13. v1 migration

Legacy profiles without `PROFILE_VERSION` remain readable:

```text
HOST=...
USER_NAME=...
SSH_PORT=...
KEY=...
BIND=...
PORT=...
```

They map in memory as:

```text
BIND -> LISTEN_HOST
PORT -> LISTEN_PORT
CLIENT_PORT -> LISTEN_PORT
AUTO_ACTIVATE -> none
```

Client host mapping:

```text
0.0.0.0 -> 127.0.0.1
*       -> 127.0.0.1
::      -> ::1
other   -> LISTEN_HOST
```

A v1 profile is not rewritten by `start`. The next `edit`/save writes v2.

For migration compatibility only, v1 still uses the historical Bash `%q` loader. **v2 is never sourced or eval'd.** Its parser accepts only the v2 allowlist, rejects unknown/duplicate keys, and treats values as data.

## 14. Runtime state and process identity

Each running profile has:

```text
~/.local/state/socksctl/<profile>.state
```

It records the actual startup snapshot, including:

```text
PID
PROCESS_START_ID
STARTED_AT
HOST
USER_NAME
SSH_PORT
KEY
LISTEN_HOST
LISTEN_PORT
```

and activation metadata for status drift reporting.

`PROCESS_START_ID` is `/proc/<pid>/stat` starttime. The supervisor also receives:

```text
SOCKSCTL_PROFILE=<profile>
```

in its initial environment.

Process identity is exactly one of:

```text
MATCH
MISSING
MISMATCH
UNKNOWN
```

`MATCH` requires:

- the PID exists;
- starttime matches;
- `/proc/<pid>/comm` identifies `autossh`;
- `/proc/<pid>/exe` identifies `autossh`;
- `/proc/<pid>/environ` contains the exact profile marker.

`MISSING` and `MISMATCH` are safe stale-state cases and never cause an unrelated PID to be killed. `UNKNOWN` is non-destructive and returns exit `4`.

Each profile has a stable lock:

```text
~/.local/state/socksctl/<profile>.lock
```

`start`, `stop`, `restart`, and `remove` acquire it once with `flock`. Restart and remove call internal locked helpers rather than recursively acquiring the same lock.

Default lock timeout:

```text
SOCKSCTL_LOCK_TIMEOUT=5
```

## 15. Multi-shell limitation

Activation state is per shell.

If Terminal A and Terminal B both activate `proxy-a`, and A runs:

```bash
socksctl stop proxy-a
```

A can deactivate itself. It cannot mutate the already-running parent shell in Terminal B.

B therefore retains its old proxy environment until B runs another wrapper command. `status`/`list` from B can report that its shell is active while the tunnel is no longer `READY`:

```text
WARNING: active shell points to a non-READY tunnel
```

This is expected shell process semantics, not a global environment bug.

## 16. Security

- Default listener is loopback-only.
- Non-loopback listeners are visibly warned during create/edit.
- Wildcard listeners require explicit interactive confirmation.
- socksctl does not add SOCKS authentication.
- Profile/current/runtime/log/lock files are mode `600`.
- Config/state directories are mode `700`.
- Profile/current/runtime writes use a same-directory temporary file followed by atomic rename.
- `stop` never kills a PID based only on a saved integer.
- `StrictHostKeyChecking=accept-new` is used; review your SSH host-key policy before deployment.
- Background SSH uses `BatchMode=yes`; keep passphrases in `ssh-agent`.

## 17. Troubleshooting

Inspect one profile:

```bash
socksctl status local
```

Inspect all profiles:

```bash
socksctl list
```

View autossh logs:

```bash
socksctl logs local
```

End-to-end SOCKS test:

```bash
socksctl test local
```

`test` is intentionally separate from readiness. Readiness only verifies local listener ownership/connectivity and does not access the public Internet.

Common states:

```text
STOPPED   no verified supervisor
STARTING  newly created supervisor is waiting for listener readiness
READY     verified supervisor + SSH child + owned listener + TCP probe
DEGRADED  verified supervisor exists but listener is not ready
UNKNOWN   PID exists but process identity cannot be safely verified
```

Default start timeout:

```text
SOCKSCTL_START_TIMEOUT=15
```

Autossh runs with:

```text
-M 0
AUTOSSH_GATETIME=0
ServerAliveInterval=30
ServerAliveCountMax=3
ExitOnForwardFailure=yes
ConnectTimeout=10
TCPKeepAlive=yes
StrictHostKeyChecking=accept-new
BatchMode=yes
```

`AUTOSSH_GATETIME=0` lets autossh retry within socksctl's own readiness deadline instead of introducing a second startup policy.

## 18. CLI and exit codes

```text
socksctl start [profile]
socksctl stop [profile]
socksctl restart [profile]
socksctl stop-all
socksctl add [profile]
socksctl edit [profile]
socksctl remove <profile>
socksctl use <profile>
socksctl list
socksctl status [profile]
socksctl show [profile]
socksctl test [profile]
socksctl logs [profile]
socksctl exec <profile> -- <command> [args...]
socksctl activate [profile]
socksctl deactivate
socksctl shell-init bash
```

Argument arity is strict; extra or missing arguments are not silently ignored.

Exit codes:

```text
0    success
1    operational/readiness/activation failure
2    CLI/config validation or shell-integration-required
3    required dependency missing
4    state/lock/process-identity conflict
125  exec precondition failure
127  exec child command not found
```

Once `exec` successfully launches its child, the child's exit status is propagated.

## Development and CI

The test suite uses Bats and fake `/proc`/autossh/ssh/`ss`/`pgrep` commands to exercise failure modes without requiring a real SSH endpoint.

CI runs:

```bash
bash -n socksctl
shellcheck socksctl
bats tests/
```

The generated Bash integration is tested in normal Bash and under `set -u`, including exact environment restoration, profile switching, readonly preflight, transactional rollback, non-exported active marker, start/stop/restart/stop-all behavior, process identity, listener ownership, lock timeout, and `exec` exit-code behavior.

# Kiro Sandbox

A bubblewrap-based confinement wrapper for [Kiro CLI](https://kiro.dev/cli/).

## Files in this distribution

| File | Purpose |
|---|---|
| `kiro-sandbox` | Main wrapper. Replaces direct `kiro-cli` invocation. |
| `kiro-sandbox-shell` | Drops you into a bash shell inside the same sandbox view. Useful for debugging and inspection. |
| `kiro-sandbox-test` | Automated probe runner that asserts the sandbox actually confines what it claims to. Runs ~20 probes and exits non-zero if any leak. |
| `kiro-sandbox-seccomp` | Python helper that emits a compiled BPF seccomp filter to stdout. Called automatically by `kiro-sandbox`. |
| `agents/sandbox-default.json` | Sample Kiro agent definition with audit-logging hooks pre-configured. Optional, copy into your sandbox `~/.kiro/agents/`. |
| `ansible/deploy.yml` | Ansible playbook for fleet deployment to multiple hosts. |
| `install.sh` | Local installer. Copies scripts to `~/.local/bin` and verifies dependencies. |

## What it does

`kiro-sandbox` runs `kiro-cli` inside a [bubblewrap](https://github.com/containers/bubblewrap)
sandbox built from scratch on a tmpfs root. Kiro can see:

- `/usr`, `/etc`, `/opt` (read-only system tree)
- A dedicated isolated `$HOME` at `~/.local/share/kiro-sandbox/home/`
  where auth tokens, settings, agents, and chat history live
- `~/.aws/` (optional, read-write so SSO token cache works)
- `~/.gitconfig` (read-only, optional)
- The current working directory (read-write, bound at its real path)
- The network (sharing the host's network namespace)

Kiro CLI cannot see:

- `~/.ssh`, `~/.gnupg`, `~/.password-store`, browser profiles
- `~/.bash_history`, shell history, dotfiles in your real `$HOME`
- Any project directory other than the one you launched from
- Any other user's home directory
- `/root` or anything that requires elevated privileges

Defenses applied (in order of layers):

1. **Filesystem isolation** via mount namespace and explicit bind mounts
2. **User namespace** with all caps dropped (`--cap-drop ALL`)
3. **`--disable-userns`** + `--assert-userns-disabled` so no nested
   user namespaces can be created from inside
4. **PID, IPC, UTS, cgroup** namespaces fresh for the sandbox
5. **`--new-session`** to block TIOCSTI keystroke injection (CVE-2017-5226)
6. **`--die-with-parent`** so the sandbox terminates with the wrapper
7. **`--clearenv`** with explicit env whitelist
8. **Seccomp BPF filter** denying ~50 dangerous syscalls (see below)

## Seccomp filter

When `python3-libseccomp` is available, `kiro-sandbox` automatically
compiles a BPF filter via `kiro-sandbox-seccomp` and feeds it to bwrap
through a file descriptor. The filter is a deny-list with default
ALLOW. The denied syscalls fall into these categories:

- **Kernel keyring**: `keyctl`, `add_key`, `request_key`
- **Exploit primitives**: `userfaultfd`
- **eBPF**: `bpf` (root-only, defense in depth)
- **Module loading**: `init_module`, `finit_module`, `delete_module`,
  `create_module`, `query_module`, `get_kernel_syms`
- **Kernel re-execution / power**: `kexec_load`, `kexec_file_load`,
  `reboot`
- **Swap**: `swapon`, `swapoff`
- **Legacy I/O**: `iopl`, `ioperm`
- **Mount manipulation** (already denied by namespace, explicit
  for cleaner errors and forward compat): `mount`, `umount`, `umount2`,
  `pivot_root`, `chroot`, `move_mount`, `open_tree`, `mount_setattr`,
  `fsmount`, `fsopen`, `fspick`, `fsconfig`
- **Hostname/domainname**: `sethostname`, `setdomainname`
- **Old/unused**: `sysfs`, `_sysctl`, `uselib`, `ustat`, `vm86`,
  `vm86old`, `nfsservctl`, `kcmp`, `lookup_dcookie`
- **Process introspection**: `ptrace`, `process_vm_readv`,
  `process_vm_writev`
- **Performance counters**: `perf_event_open`
- **Process accounting**: `acct`
- **Time manipulation**: `clock_settime`, `clock_adjtime`,
  `settimeofday`, `stime`, `adjtimex`
- **File handles**: `name_to_handle_at`, `open_by_handle_at`
- **Quota**: `quotactl`, `quotactl_fd`
- **Argument-filtered**:
  - `ioctl(_, TIOCSTI, _)` (terminal injection)
  - `clone` and `unshare` with `CLONE_NEWUSER` flag

Without `python3-libseccomp` installed, the wrapper warns and runs
without the seccomp filter (other defenses still apply). To install:

```sh
# Fedora, RHEL, Amazon Linux 2023
sudo dnf install -y python3 python3-libseccomp

# Debian, Ubuntu
sudo apt-get install -y python3 python3-seccomp
```

To explicitly disable the filter (for debugging): `KIRO_SANDBOX_SECCOMP=0`.

To audit what the filter blocks on your system, run the generator
directly and watch the stderr output:

```sh
kiro-sandbox-seccomp > /dev/null
```

You can also inspect the BPF program with `seccomp-tools` (gem):

```sh
kiro-sandbox-seccomp > /tmp/filter.bpf
seccomp-tools disasm /tmp/filter.bpf
```

## Threat model

Designed to defend against:

1. Prompt injection that hijacks Kiro into running destructive commands.
   Damage is bounded to the project dir and the sandboxed home.
2. Exfiltration of unrelated secrets like SSH keys, GPG keys, browser
   cookies, password manager databases (they are not in the sandbox view).
3. Cross-project contamination: a hijack in one project cannot read or
   modify a different project's files.
4. Kernel exploit chains that depend on rare/dangerous syscalls
   (`userfaultfd`, `bpf`, `keyctl`, `perf_event_open`, etc.).
5. TIOCSTI keystroke injection at the host shell.
6. Module loading, kernel re-execution, mount manipulation, and other
   kernel-level escalation.

Not designed to defend against:

1. Network-level exfiltration of project files or AWS credentials.
   Kiro needs internet by default. Set `KIRO_SANDBOX_NO_NET=1` and
   `KIRO_SANDBOX_NO_AWS=1` for stricter confinement, at the cost of
   breaking most of Kiro's functionality.
2. Kernel exploits that don't depend on the syscalls we deny.
3. Side-channel attacks against other processes on the host.

## Requirements

- Linux kernel with user namespaces enabled (`CONFIG_USER_NS=y`).
  Standard on Fedora, Ubuntu 18.04+, Debian 11+, Arch, AL2023.
  Verify: `unshare --user --pid echo ok` (prints `ok` on success)
- `bubblewrap` package
- `kiro-cli` already installed and in `$PATH`
- `python3` and `python3-libseccomp` (optional but recommended for
  the seccomp filter)
- bash 4+

### Installing dependencies

```sh
# Fedora, AL2023, RHEL/Rocky/Alma 9+
sudo dnf install -y bubblewrap python3 python3-libseccomp

# Debian, Ubuntu
sudo apt-get install -y bubblewrap python3 python3-seccomp
```

### Installing kiro-sandbox

```sh
bash install.sh
```

This copies `kiro-sandbox`, `kiro-sandbox-shell`, and
`kiro-sandbox-seccomp` to `~/.local/bin` (override with `PREFIX=...`).

## First-run setup

The sandbox starts with a fresh, empty `~/.kiro`. Log in once:

```sh
kiro-sandbox login
```

This opens the AWS Builder ID device-code flow (which uses your host
browser via stdout, no GUI integration needed). After login, the OAuth
tokens are stored in the sandbox's isolated home and persist across
runs.

Verify:

```sh
kiro-sandbox whoami
```

## Daily usage

Run it the same way you would run `kiro-cli` directly. Just substitute
`kiro-sandbox`:

```sh
cd ~/code/my-project
kiro-sandbox chat
kiro-sandbox chat "review the diff against main"
kiro-sandbox translate "find python files modified this week"
```

The current working directory is bound read-write into the sandbox at
its real path, so paths Kiro sees match what you would type at your
shell. Anything outside that directory is invisible.

## kiro-sandbox-shell

Drops you into a bash shell inside the same sandbox view that Kiro
would see. Useful for:

- Inspecting what Kiro can and cannot reach
- Manually preparing files in the project sandbox
- Verifying the threat model interactively
- Testing whether seccomp denials affect your workflow

```sh
cd ~/code/my-project
kiro-sandbox-shell
```

You will see a prompt like `[kiro-sandbox my-project]$`. From here:

```sh
[kiro-sandbox my-project]$ ls ~/.ssh        # No such file or directory
[kiro-sandbox my-project]$ cat ~/.kiro/...  # sandbox-only contents
[kiro-sandbox my-project]$ keyctl list @s   # Operation not permitted
[kiro-sandbox my-project]$ ptrace ... bash  # Operation not permitted
[kiro-sandbox my-project]$ exit             # leave the sandbox
```

Equivalent to `kiro-sandbox --shell`. All `KIRO_SANDBOX_*` environment
variables are honored.

## Configuration

| Variable | Default | Effect |
|---|---|---|
| `KIRO_SANDBOX_HOME` | `$XDG_DATA_HOME/kiro-sandbox` | Override sandbox state location |
| `KIRO_SANDBOX_NO_NET` | `0` | `1` to drop network namespace (kiro will fail to reach its API) |
| `KIRO_SANDBOX_NO_AWS` | `0` | `1` to not share `~/.aws` |
| `KIRO_SANDBOX_EPHEMERAL` | `0` | `1` for tmpfs `$HOME`, no persistence |
| `KIRO_SANDBOX_SHARE_GIT` | `1` | `0` to not share `~/.gitconfig` |
| `KIRO_SANDBOX_EXTRA_RO` | empty | colon-separated paths to bind read-only |
| `KIRO_SANDBOX_EXTRA_RW` | empty | colon-separated paths to bind read-write |
| `KIRO_SANDBOX_SECCOMP` | `1` | `0` to disable the seccomp filter |
| `KIRO_SANDBOX_VERBOSE` | `0` | `1` to print the assembled bwrap command |

### Examples

Strictest mode (no network, no AWS, ephemeral home, full seccomp,
useful for poking at Kiro behavior with no exfiltration risk):

```sh
KIRO_SANDBOX_NO_NET=1 \
KIRO_SANDBOX_NO_AWS=1 \
KIRO_SANDBOX_EPHEMERAL=1 \
  kiro-sandbox-shell
```

Disable seccomp temporarily for debugging a syscall issue:

```sh
KIRO_SANDBOX_SECCOMP=0 KIRO_SANDBOX_VERBOSE=1 kiro-sandbox chat
```

Expose a shared cache directory across projects (read-write):

```sh
KIRO_SANDBOX_EXTRA_RW="$HOME/.cache/uv:$HOME/.cache/pip" kiro-sandbox chat
```

Give Kiro read-only visibility into a sibling repo for context:

```sh
KIRO_SANDBOX_EXTRA_RO="$HOME/code/shared-libs" kiro-sandbox chat
```

## Verifying the sandbox

The fastest check is `kiro-sandbox-test`, which runs a battery of
probes via `kiro-sandbox --exec` and asserts each access denial:

```sh
$ kiro-sandbox-test
kiro-sandbox-test: using wrapper /home/jdoe/.local/bin/kiro-sandbox

[filesystem confinement]
  PASS  host ~/.ssh is invisible
  PASS  host ~/.gnupg is invisible
  PASS  host ~/.bash_history is invisible
  PASS  host ~/.password-store is invisible
  PASS  /root is unreadable
  PASS  /etc/shadow is unreadable
  PASS  other home directories are not enumerable
  PASS  sandbox HOME is writable
  PASS  /usr is read-only
  PASS  /etc is read-only

[capability and namespace confinement]
  PASS  no CAP_SYS_ADMIN (mount fails)
  PASS  no CAP_SYS_MODULE (modprobe fails)
  PASS  PID namespace isolated (host pid 1 invisible)
  PASS  uid mapping in effect (id is sane)

[seccomp filter, if active]
  seccomp filter: on
  PASS  keyctl(2) denied
  PASS  ptrace(2) denied
  PASS  userfaultfd(2) denied

[positive-path checks]
  PASS  current project dir IS visible
  PASS  DNS works
  PASS  outbound TCP works

20/20 probes passed, 0 failed
```

Add `-v` to print the raw probe output. Add `--no-net-check` for
offline/CI environments where outbound TCP is blocked.

If you prefer to poke around interactively, use `kiro-sandbox-shell`:

```sh
$ kiro-sandbox-shell
[kiro-sandbox ~]$ ls ~/.ssh                 # No such file or directory
[kiro-sandbox ~]$ cat /etc/shadow           # Permission denied
[kiro-sandbox ~]$ keyctl list @s            # Operation not permitted
[kiro-sandbox ~]$ unshare --user echo nope  # Operation not permitted
[kiro-sandbox ~]$ exit
```

If any host data leaks, run with `KIRO_SANDBOX_VERBOSE=1` and inspect
the assembled bwrap command.

## Audit log

Every sandboxed invocation appends a line to:

```
~/.local/share/kiro-sandbox/log/invocations.log
```

Format: ISO timestamp, wrapper PID, mode (run|shell), working dir,
seccomp status, raw argv. Inspect with:

```sh
vim ~/.local/share/kiro-sandbox/log/invocations.log
```

## Audit-logging Kiro's tool calls

The wrapper-level invocation log records when you launched Kiro, but
not what Kiro did once it was running. To capture every shell command,
AWS call, and file write Kiro performs, install the bundled agent
definition that pre-configures Kiro's own hooks system:

```sh
mkdir -p ~/.local/share/kiro-sandbox/home/.kiro/agents
cp agents/sandbox-default.json \
  ~/.local/share/kiro-sandbox/home/.kiro/agents/sandbox-default.json

# Tell Kiro inside the sandbox to use it as default
kiro-sandbox agent set-default sandbox-default

# Pre-create the log path inside the sandbox HOME so hooks can write
mkdir -p ~/.local/share/kiro-sandbox/home/.local/share/kiro-cli/log
touch    ~/.local/share/kiro-sandbox/home/.local/share/kiro-cli/log/tool-calls.log
```

The hooks append a timestamped entry plus the tool's JSON input to:

```
~/.local/share/kiro-sandbox/home/.local/share/kiro-cli/log/tool-calls.log
```

Tail it during a session to watch Kiro work:

```sh
tail -f ~/.local/share/kiro-sandbox/home/.local/share/kiro-cli/log/tool-calls.log
```

The agent also flips Kiro's permission model from the default
(everything pre-approved with checkpoints) to read-only by default,
so write operations require explicit approval. Adjust `tools` and
`allowedTools` in the JSON to taste.

## Limitations and gotchas

1. **Auto-update fails silently.** Kiro CLI tries to auto-update in
   the background. The binary is on a read-only mount, so updates
   fail. Run `kiro-cli update` outside the sandbox occasionally, or
   update via your package manager.

2. **MCP servers run inside the sandbox.** They share its filesystem
   view, capabilities, network access, and seccomp filter. If you
   configure an MCP server that needs filesystem access outside the
   project, add the path via `KIRO_SANDBOX_EXTRA_RO` or
   `KIRO_SANDBOX_EXTRA_RW`.

3. **`sudo`, `su`, `pkexec` will not work** inside the sandbox. The
   user namespace maps only your UID. This is intentional but breaks
   workflows that ask Kiro to run privileged commands.

4. **Job control surprises.** `--new-session` calls `setsid()` which
   detaches from the controlling terminal. Foreground/background
   behavior with `Ctrl-Z`, `bg`, `fg` may differ. This is the
   trade-off for TIOCSTI protection.

5. **Some debugging tools fail.** `strace`, `gdb`, and `perf` need
   `ptrace` and `perf_event_open` which are denied by seccomp. If you
   need them inside the sandbox: `KIRO_SANDBOX_SECCOMP=0`.

6. **Files outside the project dir are invisible to Kiro.** Use
   `KIRO_SANDBOX_EXTRA_RO` to expose specific paths, or run Kiro
   from a parent directory that contains both.

7. **AWS SSO token cache.** SSO writes to `~/.aws/sso/cache/`. If you
   set `KIRO_SANDBOX_NO_AWS=1`, you cannot use SSO. Static credentials
   in `~/.aws/credentials` work either way once bound.

8. **First-run login is per-sandbox.** The isolated home means you log
   in to Kiro once for the sandbox in addition to your existing real
   `~/.kiro` login. This is by design.

9. **`/dev` is shared, not isolated.** We use `--dev` (a fresh devtmpfs
   with `null`, `zero`, `random`, etc.) instead of `--dev-bind /dev /dev`.
   GPU access and similar device-level integrations are unavailable.

10. **clone3 is allowed.** The seccomp filter targets `clone` and
    `unshare` for namespace flags. `clone3` uses a struct argument
    that BPF cannot inspect, so it is allowed unconditionally. This
    means a determined attacker could call `clone3` directly with
    `CLONE_NEWUSER`, but `--disable-userns` already sets
    `max_user_namespaces=0` which prevents the actual namespace
    creation regardless of how it is requested.

## Uninstall

```sh
rm ~/.local/bin/kiro-sandbox{,-shell,-test,-seccomp}
rm -rf ~/.local/share/kiro-sandbox  # removes sandbox state, logs, agents
```

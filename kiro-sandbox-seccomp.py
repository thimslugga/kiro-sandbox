#!/usr/bin/env python3

# kiro-sandbox-seccomp.py - Generate a seccomp BPF filter for kiro-sandbox.
#
# Writes the compiled BPF program to stdout (binary). Designed to be
# fed to bwrap via --seccomp <fd>.
#
# Default action: ALLOW. We deny specific dangerous syscalls with
# EPERM. This is a deny-list filter; combine it with --cap-drop ALL,
# user namespace isolation, and bwrap's filesystem confinement.
#
# Requires the libseccomp Python bindings:
#   Fedora/RHEL/AL2023: dnf install python3-libseccomp
#   Debian/Ubuntu:      apt install python3-seccomp
#   Arch:               pacman -S libseccomp  (Python module included)
#
# Status messages go to stderr, BPF goes to stdout.

import sys

try:
    import seccomp
except ImportError:
    print("kiro-sandbox-seccomp: python3 libseccomp bindings not installed",
          file=sys.stderr)
    print("  Fedora/AL2023: dnf install python3-libseccomp",
          file=sys.stderr)
    print("  Debian/Ubuntu: apt install python3-seccomp",
          file=sys.stderr)
    sys.exit(2)


EPERM = 1

# ----------------------------------------------------------------------
# Categorically denied syscalls (no legitimate use for kiro-cli).
# Unknown syscalls on the current arch/kernel are silently skipped.
# ----------------------------------------------------------------------
DENY_SYSCALLS = [
    # Kernel keyring (info disclosure, lateral movement)
    "keyctl", "add_key", "request_key",

    # Userspace fault handler (common exploit primitive)
    "userfaultfd",

    # eBPF program loading (root-only, defense in depth)
    "bpf",

    # Kernel module loading
    "init_module", "finit_module", "delete_module",
    "create_module", "query_module", "get_kernel_syms",

    # Kernel re-execution / power states
    "kexec_load", "kexec_file_load",
    "reboot",

    # Swap manipulation
    "swapon", "swapoff",

    # I/O port access (legacy)
    "iopl", "ioperm",

    # Mount manipulation. Already blocked by the mount namespace,
    # but explicit denial gives a cleaner EPERM and protects
    # against future kernel changes.
    "mount", "umount", "umount2", "pivot_root", "chroot",
    "move_mount", "open_tree", "mount_setattr",
    "fsmount", "fsopen", "fspick", "fsconfig",

    # Hostname / domainname (UTS namespace also isolates)
    "sethostname", "setdomainname",

    # Misc old, deprecated, unused syscalls
    "sysfs", "_sysctl", "uselib", "ustat",
    "vm86", "vm86old", "nfsservctl", "kcmp",
    "lookup_dcookie",

    # Process introspection (read another process memory)
    "ptrace",
    "process_vm_readv", "process_vm_writev",

    # Performance counters (info disclosure, exploit surface)
    "perf_event_open",

    # Process accounting
    "acct",

    # Time manipulation (could bypass cert validity, JWT exp, etc.)
    "clock_settime", "clock_adjtime", "settimeofday",
    "stime", "adjtimex",

    # Open by handle (can bypass /proc-based path restrictions)
    "name_to_handle_at", "open_by_handle_at",

    # Disk quota
    "quotactl", "quotactl_fd",
]


def build_filter():
    f = seccomp.SyscallFilter(defaction=seccomp.ALLOW)

    denied = 0
    skipped = []
    for sc in DENY_SYSCALLS:
        try:
            f.add_rule(seccomp.ERRNO(EPERM), sc)
            denied += 1
        except (RuntimeError, ValueError):
            skipped.append(sc)

    # Argument-filtered denials below.

    # ioctl(_, TIOCSTI, _): terminal input injection (CVE-2017-5226
    # class). bwrap's --new-session also defends against this; the
    # seccomp rule is defense in depth and protects child processes
    # that may setsid() back.
    TIOCSTI = 0x5412
    try:
        f.add_rule(seccomp.ERRNO(EPERM), "ioctl",
                   seccomp.Arg(1, seccomp.EQ, TIOCSTI))
        denied += 1
    except (RuntimeError, ValueError):
        skipped.append("ioctl[TIOCSTI]")

    # clone/unshare with CLONE_NEWUSER: prevent nested user namespaces.
    # bwrap's --disable-userns is the primary defense (sets
    # max_user_namespaces=0); this rule provides faster, cleaner
    # failure for callers that try.
    CLONE_NEWUSER = 0x10000000
    for sc in ("clone", "unshare"):
        try:
            f.add_rule(seccomp.ERRNO(EPERM), sc,
                       seccomp.Arg(0, seccomp.MASKED_EQ,
                                   CLONE_NEWUSER, CLONE_NEWUSER))
            denied += 1
        except (RuntimeError, ValueError):
            skipped.append(sc + "[CLONE_NEWUSER]")

    return f, denied, skipped


def main():
    f, denied, skipped = build_filter()

    print(f"kiro-sandbox-seccomp.py: {denied} rules installed", file=sys.stderr)
    if skipped:
        print(f"kiro-sandbox-seccomp.py: skipped (unknown on this arch): "
              f"{', '.join(skipped)}", file=sys.stderr)

    f.export_bpf(sys.stdout.buffer)
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()

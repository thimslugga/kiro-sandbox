#!/bin/bash
#set -euo pipefail

# Kiro CLI Sandbox
#
# Requires bubblewrap and seccomp:
#  sudo yum install -y bubblewrap libseccomp
#
# References:
# - https://kiro.dev/docs/cli/
# - https://github.com/jbking/coding-agent-local/tree/main
# - https://github.com/kavehtehrani/kaveh.page/blob/master/data/blog/claude-code-sandbox.mdx
# - https://github.com/georgek/dotfiles/blob/master/scripts/bin/run-opencode
# - https://github.com/georgek/dotfiles/blob/master/scripts/bin/run-claude
# - https://github.com/emsi/claude-desktop/blob/main/claude_sandbox.sh
# - https://github.com/georgek/dotfiles/blob/master/scripts/bin/sandbox


function usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [SANDBOX_NAME] [COMMAND]

Create and run commands in an isolated sandbox environment using bubblewrap.

Arguments:
    SANDBOX_NAME    Name of the sandbox (default: kiro-cli)
    COMMAND         Command to run in sandbox (default: /bin/bash)

Options:
    -h, --help     Show this help message and exit

Examples:
    $(basename "$0")                   # Start default sandbox with bash shell
    $(basename "$0") my-sandbox        # Start custom sandbox with bash shell
    $(basename "$0") my-sandbox ls -l  # Run 'ls -l' in custom sandbox

EOF
    exit 1
}

function command_exists() {
    if ! command -v "\$1" &> /dev/null; then
        echo "ERROR: \$1 not found"
        return 1
    else
        echo "INFO: \$1 found"
        return 0
    fi
}

PROJECT_DIR="$(pwd)"
KIRO_BIN="$(command -v kiro-cli)"
KIRO_PATH="$(readlink -f "$KIRO_BIN")"
KIRO_BIN_DIR="$(dirname "$KIRO_BIN")"
KIRO_INSTALL_DIR="$(dirname "$(dirname "$KIRO_PATH")")"

[[ -n "$KIRO_BIN" ]] || { echo "Error: kiro-cli not found. Aborting."; exit 1; }

# Ensure directories exist
mkdir -p "$HOME/.kiro"/{agents,context,hooks,powers,skills,specs,steering}

BWRAP_CMD=(
  bwrap
)

BWRAP_CMD+=(
    # System binaries and libraries (ro)
    --ro-bind /bin /bin
    --ro-bind /usr /usr
    --ro-bind /lib /lib

    # /lib64 may not exist on all systems
    --ro-bind-try /lib64 /lib64

    # System config (ro)
    --ro-bind /etc/hosts /etc/hosts
    --ro-bind /etc/resolv.conf /etc/resolv.conf
    --ro-bind /etc/passwd /etc/passwd
    --ro-bind /etc/group /etc/group
    --ro-bind /etc/ssl /etc/ssl

    # Local bin dirs
    --ro-bind-try "$HOME/.local/bin" "$HOME/.local/bin"
    --ro-bind-try "$HOME/bin" "$HOME/bin"

    #--ro-bind-try "$HOME/.local/share" "$HOME/.local/share"

    --ro-bind-try "$HOME/.config/git" "$HOME/.config/git"
    --ro-bind-try "$HOME/.gitconfig" "$HOME/.gitconfig"
    --ro-bind-try "$HOME/.ssh" "$HOME/.ssh"
    --ro-bind-try "$HOME/.ssh/known_hosts" "$HOME/.ssh/known_hosts"

    # Development stuff
    --ro-bind-try "$HOME/.config/uv" "$HOME/.config/uv"
    --ro-bind-try "$HOME/.nvm" "$HOME/.nvm"
    --ro-bind-try "$HOME/.rustup" "$HOME/.rustup"

    # Kiro install (ro), kiro config dir ~/.kiro (rw)
    --ro-bind "$KIRO_BIN_DIR" "$KIRO_BIN_DIR"
    --ro-bind "$KIRO_INSTALL_DIR" "$KIRO_INSTALL_DIR"
    --bind-try "$HOME/.kiro" "$HOME/.kiro"

    # ~/.cache dirs (rw)
    --bind-try "$HOME/.cache" "$HOME/.cache"
    --bind-try "$HOME/.cache/uv" "$HOME/.cache/uv"
    --bind-try "$HOME/.cache/pip" "$HOME/.cache/pip"
    --bind-try "$HOME/.npm" "$HOME/.npm"
    --bind-try "$HOME/.cargo" "$HOME/.cargo"

    # Project directory (rw)
    --bind "$PROJECT_DIR" "$PROJECT_DIR"

    # /proc, /dev, /tmp, etc.
    --tmpfs /tmp
    --proc /proc
    --dev /dev

    # Before namespaces
    --setenv HOME "$HOME"

    # namespaces
    --share-net
    --unshare-pid
    --die-with-parent
    --chdir "$PROJECT_DIR"

    # Project
    --ro-bind /dev/null "$PROJECT_DIR/.env"
    --ro-bind /dev/null "$PROJECT_DIR/.env.local"
    --ro-bind /dev/null "$PROJECT_DIR/.env.production"
)

#echo "Project Directory: ${PROJECT_DIR}"
exec "${BWRAP_CMD[@]}" "${KIRO_BIN}" "$@"

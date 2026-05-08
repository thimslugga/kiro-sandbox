#!/bin/bash

# https://access.redhat.com/articles/5946151

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

cat <<'EOF' | tee /etc/sysctl.d/99-local-ns.conf
kernel.unprivileged_userns_clone = 1
kernel.userns_restrict = 0
net.core.bpf_jit_harden = 2
user.max_user_namespaces = 49152

EOF

sysctl --system

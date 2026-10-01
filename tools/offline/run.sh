#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# The stack on a private internal network: one rootless network namespace with no route out,
# where FoundationDB (10.77.0.1) and Uro (10.77.0.2) each run in their own bubblewrap sandbox
# that can write only its own data. A pass means Uro needs nothing past this machine to run.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
mkdir -p "$work/fdb/data" "$work/fdb/logs"
echo "offline:offline@10.77.0.1:4700" > "$work/fdb/fdb.cluster"

# The network: a user and network namespace held open by a sleeper, a dummy interface for the
# two service addresses, and no default route.
unshare --user --map-root-user --net sleep infinity &
holder=$!
trap 'kill $holder $fdb 2>/dev/null || true' EXIT
sleep 1
net() { nsenter --target "$holder" --user --net --preserve-credentials "$@"; }
net ip link set lo up
net ip link add int0 type dummy
net ip addr add 10.77.0.1/24 dev int0
net ip addr add 10.77.0.2/24 dev int0
net ip link set int0 up
net ip route

sandbox() {
  net bwrap --unshare-pid --die-with-parent --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp "$@"
}

sandbox --bind "$work/fdb" "$work/fdb" -- \
  fdbserver -p 10.77.0.1:4700 -C "$work/fdb/fdb.cluster" -d "$work/fdb/data" -L "$work/fdb/logs" &
fdb=$!

sandbox --bind "$here" "$here" --bind "$HOME" "$HOME" --ro-bind "$work/fdb" "$work/fdb" \
  --chdir "$here" -- bash "$here/tools/offline/uro.sh" "$work"

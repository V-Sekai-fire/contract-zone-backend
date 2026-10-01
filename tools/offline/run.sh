#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# The stack on a private internal network: one rootless network namespace with no route out,
# where FoundationDB (10.77.0.1), Uro (10.77.0.2) and the VictoriaMetrics suite (10.77.0.3) each
# run in their own bubblewrap sandbox that can write only its own data. A pass means Uro needs
# nothing past this machine to run.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
victoria=${VICTORIA:-$here/victoria}
work=$(mktemp -d)
obs_pids=""
mkdir -p "$work/fdb/data" "$work/fdb/logs"
echo "offline:offline@10.77.0.1:4700" > "$work/fdb/fdb.cluster"

# The network: a user and network namespace held open by a sleeper, a dummy interface for the
# service addresses, and no default route.
unshare --user --map-root-user --net sleep infinity &
holder=$!
trap 'kill $holder $fdb $obs_pids 2>/dev/null || true' EXIT
sleep 1
net() { nsenter --target "$holder" --user --net --preserve-credentials "$@"; }
net ip link set lo up
net ip link add int0 type dummy
net ip addr add 10.77.0.1/24 dev int0
net ip addr add 10.77.0.2/24 dev int0
net ip addr add 10.77.0.3/24 dev int0
net ip link set int0 up
net ip route

sandbox() {
  net bwrap --unshare-pid --die-with-parent --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp "$@"
}

sandbox --bind "$work/fdb" "$work/fdb" -- \
  fdbserver -p 10.77.0.1:4700 -C "$work/fdb/fdb.cluster" -d "$work/fdb/data" -L "$work/fdb/logs" &
fdb=$!

# Metrics, logs and traces: each store in its own sandbox with its own data directory.
obs() {
  mkdir -p "$work/obs/$1"
  sandbox --bind "$work/obs/$1" "$work/obs/$1" -- "$victoria/$1-prod" \
    -storageDataPath="$work/obs/$1" -httpListenAddr="10.77.0.3:$2" > "$work/obs/$1.log" 2>&1 &
  obs_pids="$obs_pids $!"
}
obs victoria-metrics 8428
obs victoria-logs 9428
obs victoria-traces 10428

sandbox --bind "$here" "$here" --bind "$HOME" "$HOME" --ro-bind "$work/fdb" "$work/fdb" \
  --chdir "$here" -- bash "$here/tools/offline/uro.sh" "$work"

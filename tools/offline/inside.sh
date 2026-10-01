#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# Inside the sandbox: show the WAN is unreachable, start a FoundationDB on loopback, and run
# Uro's suite against it, so a pass means Uro needs nothing past this machine to run.
set -euo pipefail
work=$1

if curl -sS --max-time 5 -o /dev/null https://github.com 2> "$work/wan.txt"; then
  echo "FAIL: github.com answered inside the sandbox"
  exit 1
fi
echo "control: the WAN is unreachable here ($(tr -d '\n' < "$work/wan.txt"))"

mkdir -p "$work/fdb-data" "$work/fdb-logs"
echo "offline:offline@127.0.0.1:4700" > "$work/fdb.cluster"
fdbserver -p 127.0.0.1:4700 -C "$work/fdb.cluster" -d "$work/fdb-data" -L "$work/fdb-logs" &
fdb=$!
trap 'kill $fdb' EXIT
fdbcli -C "$work/fdb.cluster" --exec "configure new single ssd" --timeout 30
until fdbcli -C "$work/fdb.cluster" --exec "status minimal" --timeout 5 | grep -q available; do
  sleep 1
done

export WEFT_FDB_CLUSTER_FILE="$work/fdb.cluster" TEST_DATABASE="file:uro_offline.v1?vfs=weft_fdb"
URO_MIGRATION_POOL=1 mix ecto.migrate
mix run priv/repo/test_seeds.exs
mix test

keys=$(fdbcli -C "$work/fdb.cluster" --exec "getrangekeys weft/db/uro_offline.v1/ weft/db/uro_offline.v10 100" |
  grep -c "weft/db/uro_offline.v1/" || true)
echo "FoundationDB keys under weft/db/uro_offline.v1/ inside the sandbox: $keys"
[ "$keys" -gt 0 ]

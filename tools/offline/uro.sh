#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# Uro's sandbox on the private network: the WAN must be unreachable and fdbserver's files on disk
# untouchable from here, so every write Uro makes goes through sqlite-fdb to 10.77.0.1.
set -euo pipefail
work=$1
cluster="$work/fdb/fdb.cluster"

if curl -sS --max-time 5 -o /dev/null https://github.com 2> /tmp/wan.txt; then
  echo "FAIL: github.com answered on the private network"
  exit 1
fi
echo "control: the WAN is unreachable ($(tr -d '\n' < /tmp/wan.txt))"

if touch "$work/fdb/data/written-by-uro" 2> /dev/null; then
  echo "FAIL: Uro's sandbox can write fdbserver's data directory on disk"
  exit 1
fi
echo "control: fdbserver's files are read-only here; Uro writes only through sqlite-fdb"

fdbcli -C "$cluster" --exec "configure new single ssd" --timeout 30
until fdbcli -C "$cluster" --exec "status minimal" --timeout 5 | grep -q available; do
  sleep 1
done

export WEFT_FDB_CLUSTER_FILE="$cluster" TEST_DATABASE="file:uro_offline.v1?vfs=weft_fdb"
URO_MIGRATION_POOL=1 mix ecto.migrate
mix run priv/repo/test_seeds.exs
mix test

keys=$(fdbcli -C "$cluster" --exec "getrangekeys weft/db/uro_offline.v1/ weft/db/uro_offline.v10 100" |
  grep -c "weft/db/uro_offline.v1/" || true)
echo "keys Uro wrote through sqlite-fdb into FoundationDB at 10.77.0.1: $keys"
[ "$keys" -gt 0 ]

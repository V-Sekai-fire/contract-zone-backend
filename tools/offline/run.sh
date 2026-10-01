#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# Runs inside.sh in a bubblewrap sandbox whose network namespace holds only loopback, so anything
# that reaches past this machine fails. The checkout, a work directory and $HOME stay writable.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
exec bwrap --unshare-net --die-with-parent \
  --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp \
  --bind "$here" "$here" --bind "$work" "$work" --bind "$HOME" "$HOME" \
  --chdir "$here" bash "$here/tools/offline/inside.sh" "$work"

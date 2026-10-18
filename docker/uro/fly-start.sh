#!/bin/sh
# Real production startup for the Burrito-wrapped uro release.
#
# Unlike a mix-based boot (`mix ecto.migrate`), a compiled release has
# no mix tasks at runtime: Uro.Release.migrate/0 (lib/uro/release.ex)
# is the real Phoenix-release pattern for this, invoked here via the
# release's own `eval` command.
set -e

echo "fly-start: running migrations"
/usr/local/bin/uro eval "Uro.Release.migrate()"

echo "fly-start: starting Uro.Endpoint"
exec /usr/local/bin/uro start

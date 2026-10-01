#!/bin/sh
# Run every call in the rx client's godot_uro addon against a running Uro and table what
# came back. The client is the addon as checked out, unmodified; the driver is
# scripts/godot_uro_calls/main.gd.
#
#   scripts/godot_uro_calls.sh --rx <checkout> --godot <binary> --host localhost --port 4443 \
#       --user adminuser --password '...' [--ca cert.pem] [--out results.json] [--expect-register 403]
#
# --rx is a checkout of entities-multiplayer-fabric-rx (feat/rx); the addon and the one
# helper class it needs are copied from it into a scratch project. --ca is a PEM the driver
# trusts instead of the system bundle: the addon speaks TLS only, so a local Uro serves a
# self-signed certificate and this is how the driver accepts it. The planted wrong path at
# the end is the negative control; a run where it records OK is a run that measured nothing.
set -eu

rx=; godot=; host=127.0.0.1; port=4443; user=adminuser; password=; ca=; out=; expect_register=403
while [ $# -gt 0 ]; do
	case $1 in
	--rx) rx=$2; shift 2 ;;
	--godot) godot=$2; shift 2 ;;
	--host) host=$2; shift 2 ;;
	--port) port=$2; shift 2 ;;
	--user) user=$2; shift 2 ;;
	--password) password=$2; shift 2 ;;
	--ca) ca=$2; shift 2 ;;
	--out) out=$2; shift 2 ;;
	--expect-register) expect_register=$2; shift 2 ;;
	*) echo "unknown argument $1" >&2; exit 2 ;;
	esac
done
[ -n "$rx" ] && [ -n "$godot" ] && [ -n "$password" ] || { echo "need --rx, --godot and --password" >&2; exit 2; }
[ -f "$rx/addons/godot_uro/godot_uro_api.gd" ] || { echo "no godot_uro addon under $rx" >&2; exit 2; }

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cp -R "$here/godot_uro_calls/." "$work/"
mkdir -p "$work/addons" "$work/fixtures"
cp -R "$rx/addons/godot_uro" "$work/addons/"
rm -f "$work"/addons/godot_uro/*.uid
cp "$rx/addons/sar_game_framework/generic/helpers/randomization_utilities.gd" "$work/"
# Upload fixtures carry the magic numbers the server checks and nothing else.
{ printf 'glTF'; head -c 4092 /dev/zero; } > "$work/fixtures/avatar.glb"
{ printf 'RSCC'; head -c 4092 /dev/zero; } > "$work/fixtures/map.scn"
if [ -n "$ca" ]; then
	cp "$ca" "$work/ca.pem"
	printf '\n[network]\n\ntls/certificate_bundle_override="res://ca.pem"\n' >> "$work/project.godot"
fi

"$godot" --headless --path "$work" --import > "$work/import.log" 2>&1 || { cat "$work/import.log"; exit 1; }
[ -n "$out" ] || out=$work/results.json
"$godot" --headless --path "$work" -- --host="$host" --port="$port" --user="$user" --password="$password" \
	--out="$out" --expect-register="$expect_register" 2>&1 | grep -E '^[a-z_]+ +(GET|POST|PUT|DELETE)|calls, '

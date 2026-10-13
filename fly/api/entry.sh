set -eu
t=/etc/foundationdb/tls
mkdir -p $t /app/priv/uploads
printf '%s\n' "$FDB_CLUSTER_CONTENT" > /etc/foundationdb/fdb.cluster
printf '%s' "$FDB_TLS_CERT_B64" | base64 -d > $t/cert.pem
printf '%s' "$FDB_TLS_KEY_B64" | base64 -d > $t/key.pem
printf '%s' "$FDB_TLS_CA_B64" | base64 -d > $t/ca.pem
chmod 600 $t/key.pem
export FDB_TLS_CERTIFICATE_FILE=$t/cert.pem FDB_TLS_KEY_FILE=$t/key.pem FDB_TLS_CA_FILE=$t/ca.pem
export FDB_TLS_VERIFY_PEERS="Check.Valid=1,S.CN>=fdb-,S.CN<=.chibifire.com"
until fdbcli --exec "status minimal" --timeout 5 | grep -q available; do echo "waiting for fdb"; sleep 2; done
mix ecto.migrate
exec mix phx.server

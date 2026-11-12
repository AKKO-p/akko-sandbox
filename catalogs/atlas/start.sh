#!/bin/bash
# Starts, in order: HBase in standalone mode (its ZooKeeper on port 2181), Solr in cloud mode
# on that ZooKeeper, Atlas's three indexes (the Solr configuration Atlas ships), then Atlas
# with its embedded Kafka. State lives under /data, inside the container.
#
# TLS: ATLAS_TLS_KEYSTORE (PKCS12), ATLAS_TLS_PASSWORD_FILE, ATLAS_TLS_CA_FILE.
#
# Users come from files, never from the environment:
#   ATLAS_ADMIN_PASSWORD_FILE    the password of admin (role ROLE_ADMIN), who seeds Atlas
#   ATLAS_READER_USER            a read-only account, of the shipped role DATA_SCIENTIST,
#   ATLAS_READER_PASSWORD_FILE   which may only read entities, glossaries and their terms
# Atlas's file-based login stores sha256("<password>{<user>}"), never the password.
set -euo pipefail
: "${ATLAS_ADMIN_PASSWORD_FILE:?}" "${ATLAS_READER_USER:?}" "${ATLAS_READER_PASSWORD_FILE:?}"
: "${ATLAS_HEAP:=768m}" "${HBASE_HEAP:=384m}" "${SOLR_HEAP:=384m}"
mkdir -p /data/hbase /data/zk /data/solr /data/kafka /data/logs /data/run

digest() { printf '%s{%s}' "$(cat "$1")" "$2" | sha256sum | cut -d' ' -f1; }
{
  printf 'admin=ADMIN::%s\n' "$(digest "$ATLAS_ADMIN_PASSWORD_FILE" admin)"
  printf '%s=DATA_SCIENTIST::%s\n' "$ATLAS_READER_USER" "$(digest "$ATLAS_READER_PASSWORD_FILE" "$ATLAS_READER_USER")"
} > "$ATLAS_HOME/conf/users-credentials.properties"
chmod 600 "$ATLAS_HOME/conf/users-credentials.properties"
# The shipped simple authorizer maps no user to DATA_SCIENTIST: the reader gets it by name.
python3 - "$ATLAS_HOME/conf/atlas-simple-authz-policy.json" "$ATLAS_READER_USER" <<'PY'
import json, sys
path, user = sys.argv[1], sys.argv[2]
with open(path) as f:
    policy = json.load(f)
policy.setdefault("userRoles", {})[user] = ["DATA_SCIENTIST"]
with open(path, "w") as f:
    json.dump(policy, f, indent=2)
PY

cat > "$HBASE_HOME/conf/hbase-site.xml" <<XML
<configuration>
  <property><name>hbase.rootdir</name><value>file:///data/hbase</value></property>
  <property><name>hbase.zookeeper.property.dataDir</name><value>/data/zk</value></property>
  <property><name>hbase.cluster.distributed</name><value>false</value></property>
  <property><name>hbase.unsafe.stream.capability.enforce</name><value>false</value></property>
</configuration>
XML
export HBASE_HEAPSIZE="$HBASE_HEAP" HBASE_LOG_DIR=/data/logs HBASE_PID_DIR=/data/run
"$HBASE_HOME/bin/start-hbase.sh"
for _ in $(seq 90); do nc -z localhost 2181 && break; sleep 2; done
nc -z localhost 2181 || { echo "HBase's ZooKeeper did not start" >&2; exit 1; }
for _ in $(seq 60); do nc -z localhost 16020 && break; sleep 2; done

[ -f /data/solr/solr.xml ] || cp "$SOLR_DIR/server/solr/solr.xml" /data/solr/
"$SOLR_DIR/bin/solr" zk mkroot /solr -z localhost:2181 >/dev/null 2>&1 || true
SOLR_LOGS_DIR=/data/logs SOLR_PID_DIR=/data/run \
  "$SOLR_DIR/bin/solr" start -c -z localhost:2181/solr -p 8983 -m "$SOLR_HEAP" -s /data/solr
for c in vertex_index edge_index fulltext_index; do
  "$SOLR_DIR/bin/solr" create -c "$c" -d "$ATLAS_HOME/conf/solr" -shards 1 -replicationFactor 1 >/dev/null 2>&1 || true
done

P="$ATLAS_HOME/conf/atlas-application.properties"
sed -i -e 's#^atlas.graph.storage.hostname=.*#atlas.graph.storage.hostname=localhost#' \
       -e 's#^atlas.graph.index.search.solr.zookeeper-url=.*#atlas.graph.index.search.solr.zookeeper-url=localhost:2181/solr#' \
       -e 's#^atlas.audit.hbase.zookeeper.quorum=.*#atlas.audit.hbase.zookeeper.quorum=localhost:2181#' \
       -e 's#^atlas.kafka.data=.*#atlas.kafka.data=/data/kafka#' "$P"
# Atlas serves https only. The key and certificate come in a PKCS12 file under a password in a
# file, and the CA that signed them goes into a trust store of its own: both are made here, from
# the files the sandbox's certificate authority wrote, and kept under /data (mode 600).
: "${ATLAS_TLS_KEYSTORE:?}" "${ATLAS_TLS_PASSWORD_FILE:?}" "${ATLAS_TLS_CA_FILE:?}"
mkdir -p /data/tls
rm -f /data/tls/keystore.jks /data/tls/truststore.jks /data/tls/credstore.jceks
tls_password=$(cat "$ATLAS_TLS_PASSWORD_FILE")
keytool -importkeystore -noprompt -srckeystore "$ATLAS_TLS_KEYSTORE" -srcstoretype PKCS12 \
  -srcstorepass "$tls_password" -destkeystore /data/tls/keystore.jks -deststoretype JKS \
  -deststorepass "$tls_password" -destkeypass "$tls_password" >/dev/null
keytool -importcert -noprompt -alias ca -file "$ATLAS_TLS_CA_FILE" -keystore /data/tls/truststore.jks \
  -storetype JKS -storepass "$tls_password" >/dev/null
# Atlas reads the passwords of its stores from a Hadoop credential store, not from its
# properties. The war is expanded by cputil.py (which then fails, with no console to ask on);
# the credential shell of the Hadoop jars inside it writes the store.
python3 "$ATLAS_HOME/bin/cputil.py" >/dev/null 2>&1 </dev/null || true
for alias in keystore.password truststore.password password; do
  java -cp "$ATLAS_HOME/server/webapp/atlas/WEB-INF/lib/*" org.apache.hadoop.security.alias.CredentialShell \
    create "$alias" -value "$tls_password" -provider jceks://file/data/tls/credstore.jceks >/dev/null 2>&1 \
    || { echo "could not write $alias to the credential store" >&2; exit 1; }
done
chmod 600 /data/tls/*
sed -i -e '/^atlas\.enableTLS=/d' -e '/^atlas\.server\.https\.port=/d' -e '/^atlas\.rest\.address=/d' \
       -e '/^keystore\.file=/d' -e '/^truststore\.file=/d' -e '/^cert\.stores\.credential\.provider\.path=/d' "$P"
{
  echo
  echo "atlas.enableTLS=true"
  echo "atlas.server.https.port=21000"
  echo "atlas.rest.address=https://localhost:21000"
  echo "keystore.file=/data/tls/keystore.jks"
  echo "truststore.file=/data/tls/truststore.jks"
  echo "cert.stores.credential.provider.path=jceks://file/data/tls/credstore.jceks"
} >> "$P"

# Atlas writes each request it served to audit.log, after the login. With
# ATLAS_LOG_REFUSED_LOGINS=true, Spring Security's Basic login filter also writes each login
# it refused to logins.log, by the exception's message, never a password. Spring logs through
# the Log4j 2 API, which Atlas ships unconfigured (log4j-core 2.17.2 in Atlas 2.4.0's web
# application): this configuration names that one logger, and keeps Log4j 2's default for the
# rest (errors on the console). atlas_start.py adds ATLAS_SERVER_OPTS to its own options.
if [ "${ATLAS_LOG_REFUSED_LOGINS:-false}" = true ]; then
  cat > /data/log4j2-logins.xml <<'XML'
<Configuration status="warn">
  <Appenders>
    <Console name="console" target="SYSTEM_ERR"><PatternLayout pattern="%d %p %c %m%n"/></Console>
    <File name="logins" fileName="/data/logs/logins.log">
      <PatternLayout pattern="%d %m: %ex{short.message}%n" alwaysWriteExceptions="false"/>
    </File>
  </Appenders>
  <Loggers>
    <Logger name="org.springframework.security.web.authentication.www.BasicAuthenticationFilter" level="debug" additivity="false">
      <AppenderRef ref="logins"/>
    </Logger>
    <Root level="error"><AppenderRef ref="console"/></Root>
  </Loggers>
</Configuration>
XML
  export ATLAS_SERVER_OPTS="-Dlog4j2.configurationFile=/data/log4j2-logins.xml"
fi
export MANAGE_LOCAL_HBASE=false MANAGE_LOCAL_SOLR=false MANAGE_LOCAL_ELASTICSEARCH=false \
       HBASE_CONF_DIR="$HBASE_HOME/conf" ATLAS_LOG_DIR=/data/logs ATLAS_PID_DIR=/data/run \
       ATLAS_SERVER_HEAP="-Xms256m -Xmx${ATLAS_HEAP}"
python3 "$ATLAS_HOME/bin/atlas_start.py"
exec tail -n +1 -F /data/logs/application.log

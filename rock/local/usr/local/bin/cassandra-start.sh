#!/usr/bin/env bash
#
# The cassandra pebble service command, run by pebble as the _daemon_ user.
#
# Ported from the official image's entrypoint, which is the configuration
# interface anything written against docker.io/library/cassandra expects:
# CASSANDRA_* in the environment, rendered into cassandra.yaml and
# cassandra-rackdc.properties on the way up. Extra JVM options go through
# JVM_EXTRA_OPTS, which cassandra-env.sh appends to the JVM command line.
#
# https://github.com/docker-library/cassandra/blob/master/5.0/docker-entrypoint.sh

set -e

function _ip_address() {
  # scrape the first non-localhost IP address of the container. In Swarm mode we
  # often get two - the container IP and the shared VIP - and the container IP
  # always comes first.
  ip address | awk '
    $1 != "inet" { next } # only lines with ip addresses
    $NF == "lo" { next } # skip loopback devices
    $2 ~ /^127[.]/ { next } # skip loopback addresses
    $2 ~ /^169[.]254[.]/ { next } # skip link-local addresses
    {
      gsub(/\/.+$/, "", $2)
      print $2
      exit
    }
  '
}

# "sed -i", but without the "mv" it does behind the scenes, which would replace
# a file bind-mounted into the container rather than edit it.
function _sed-in-place() {
  local filename="$1"
  shift
  local tempFile
  tempFile="$(mktemp)"
  sed "$@" "$filename" >"$tempFile"
  cat "$tempFile" >"$filename"
  rm "$tempFile"
}

# The defaults below are unquoted inside the braces on purpose. A default
# written as "${VAR='auto'}" keeps its single quotes - quote removal does not
# reach inside a double-quoted expansion - and Cassandra then refuses to start
# on a listen_address of "'auto'". Upstream writes these without the outer
# quotes, where the inner ones do get removed.
: "${CASSANDRA_RPC_ADDRESS=0.0.0.0}"

: "${CASSANDRA_LISTEN_ADDRESS=auto}"
if [ "$CASSANDRA_LISTEN_ADDRESS" = 'auto' ]; then
  CASSANDRA_LISTEN_ADDRESS="$(_ip_address)"
fi

: "${CASSANDRA_BROADCAST_ADDRESS="$CASSANDRA_LISTEN_ADDRESS"}"

if [ "$CASSANDRA_BROADCAST_ADDRESS" = 'auto' ]; then
  CASSANDRA_BROADCAST_ADDRESS="$(_ip_address)"
fi
: "${CASSANDRA_BROADCAST_RPC_ADDRESS:=$CASSANDRA_BROADCAST_ADDRESS}"

# a node named through --name joins the cluster reachable under that name
if [ -n "${CASSANDRA_NAME:+1}" ]; then
  : "${CASSANDRA_SEEDS:="cassandra"}"
fi
: "${CASSANDRA_SEEDS:="$CASSANDRA_BROADCAST_ADDRESS"}"

_sed-in-place "$CASSANDRA_CONF/cassandra.yaml" \
  -r 's/(- seeds:).*/\1 "'"$CASSANDRA_SEEDS"'"/'

# every key here is settable as CASSANDRA_<KEY>, and left at the value that
# ships in cassandra.yaml when it is not set
for yaml in \
  broadcast_address \
  broadcast_rpc_address \
  cluster_name \
  endpoint_snitch \
  listen_address \
  num_tokens \
  rpc_address \
  start_rpc; do
  var="CASSANDRA_${yaml^^}"
  val="${!var}"
  if [ "$val" ]; then
    _sed-in-place "$CASSANDRA_CONF/cassandra.yaml" \
      -r 's/^(# )?('"$yaml"':).*/\2 '"$val"'/'
  fi
done

for rackdc in dc rack; do
  var="CASSANDRA_${rackdc^^}"
  val="${!var}"
  if [ "$val" ]; then
    _sed-in-place "$CASSANDRA_CONF/cassandra-rackdc.properties" \
      -r 's/^('"$rackdc"'=).*/\1 '"$val"'/'
  fi
done

exec cassandra -f

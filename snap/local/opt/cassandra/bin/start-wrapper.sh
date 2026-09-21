#!/usr/bin/env bash

set -eu

source "${SNAP}"/opt/shared/bin/snap-interfaces.sh

function start_cassandra() {
  exit_if_missing_perm "system-observe"
  exit_if_missing_perm "process-control"
  exit_if_missing_perm "mount-observe"

  echo "Starting Cassandra..."

  "${SNAP}"/usr/bin/setpriv \
    --clear-groups \
    --reuid _daemon_ \
    --regid _daemon_ -- \
    ${SNAP}/opt/cassandra/bin/cassandra -f
}

start_cassandra

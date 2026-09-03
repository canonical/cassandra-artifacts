#!/bin/bash

set -e

# The venv is not found by the interpreter itself - it resolves its prefix from
# the real path of bin/python3, which is a symlink into usr/bin - so the path is
# set here. Globbed rather than spelled out, so that the python version the base
# and the archive carry can change without this breaking.
site_packages=("${SNAP}"/lib/python3.*/site-packages)
if [ ! -d "${site_packages[0]}" ]; then
    echo "no python site-packages in ${SNAP}/lib" >&2
    exit 1
fi

export PYTHONPATH="${site_packages[0]}"

exec "${SNAP}/bin/python3" "${SNAP}/bin/${bin}" "$@"

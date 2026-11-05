#!/bin/sh
set -eu
DECHROME_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec /usr/bin/python3 "$DECHROME_ROOT/scripts/package_release.py" "$@"

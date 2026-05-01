#!/usr/bin/env bash
set -euo pipefail

OUTPUT="./sts2-recover"

gdsdecomp --headless --extract="${1:?Usage: $0 <pck_file>}" --output="$OUTPUT"

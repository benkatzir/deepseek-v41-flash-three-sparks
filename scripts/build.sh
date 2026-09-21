#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $(uname -m) == aarch64 ]] || { echo 'Build on an ARM64 Spark.' >&2; exit 1; }
python3 "$ROOT/scripts/extract_sources.py"
python3 "$ROOT/scripts/verify_sources.py"
exec docker build --platform linux/arm64 --memory 2g --memory-swap 2g \
  -t "${IMAGE:-deepseek-v41-flash-three-sparks:public-v1}" "$ROOT"

#!/usr/bin/env bash
# The subnet-aware three-node ring build used in the original experiment.
# Runs locally on each Spark. Does not change networking or existing workloads.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${CONFIG:-$ROOT/config/cluster.env}
[[ -f "$CONFIG" ]] || { echo 'Create config/cluster.env first.' >&2; exit 1; }
source "$CONFIG"
: "${DATA_DIR:?Set DATA_DIR}"
[[ $(uname -m) == aarch64 ]] || { echo 'Build on an ARM64 Spark.' >&2; exit 1; }
SOURCE=${NCCL_SOURCE_DIR:-$DATA_DIR/nccl}
COMMIT=fab1850acd902672d79ca81c2e7fb8e1848c208c
if [[ ! -d "$SOURCE" ]]; then
  mkdir -p "$(dirname -- "$SOURCE")"
  git init "$SOURCE"
  git -C "$SOURCE" remote add origin https://github.com/zyang-dev/nccl.git
  git -C "$SOURCE" fetch --depth 1 origin "$COMMIT"
  git -C "$SOURCE" checkout --detach FETCH_HEAD
fi
[[ $(git -C "$SOURCE" rev-parse HEAD) == "$COMMIT" ]] || { echo 'Existing NCCL checkout is not the pinned commit; choose a new directory.' >&2; exit 1; }
[[ -z $(git -C "$SOURCE" status --porcelain --untracked-files=no) ]] || { echo 'NCCL tracked sources have local changes.' >&2; exit 1; }
make -C "$SOURCE" -j "${BUILD_JOBS:-2}" src.build \
  "CUDA_HOME=${CUDA_HOME:-/usr/local/cuda}" \
  'NVCC_GENCODE=-gencode=arch=compute_121,code=sm_121'
test -e "$SOURCE/build/lib/libnccl.so.2"
printf 'NCCL 2.29.7 built from %s\nSet NCCL_DIR=%s/build/lib in cluster.env.\n' "$COMMIT" "$SOURCE"

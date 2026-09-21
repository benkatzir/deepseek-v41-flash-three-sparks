#!/usr/bin/env bash
# Rebuild corresponding source into a separate directory. Does not replace
# shipped binaries or change any serving container. New output is unqualified.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 "$ROOT/scripts/extract_sources.py"
python3 "$ROOT/scripts/verify_sources.py"
OUTPUT=${1:?Usage: scripts/rebuild_extensions.sh NEW_EMPTY_OUTPUT_DIRECTORY}
mkdir -p "$OUTPUT"
OUTPUT=$(cd -- "$OUTPUT" && pwd)
[[ -z $(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit) ]] || { echo 'Output must be empty.' >&2; exit 1; }
BASE=lmsysorg/sglang@sha256:b4a4745fab5393dc0aca573fe754b86477f57691c9e971390b21102d3d94ebf9
docker run --rm --entrypoint bash -e PYTHONPATH= -e MAX_JOBS=2 -e TORCH_CUDA_ARCH_LIST=12.1 \
  --mount "type=bind,src=$ROOT/src,dst=/sources,readonly" \
  --mount "type=bind,src=$OUTPUT,dst=/output" "$BASE" -euo pipefail -c '
    cp -r /sources/cuda-exl3-build /output/cuda-exl3-build
    python3 /output/cuda-exl3-build/build_extension.py
    python3 -c "import cuda_exl3,pathlib,shutil; shutil.copytree(pathlib.Path(cuda_exl3.__file__).parent, pathlib.Path(\"/output/cuda_exl3\"))"
    bash /sources/cooperative/component/build.sh /output/cooperative /sources/cooperative
  '
printf '%s\n' 'Rebuilt extensions saved. They are NOT qualified replacements for the shipped binaries.'

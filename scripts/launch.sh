#!/usr/bin/env bash
# One local node only. Run as root; this script never uses SSH or handles passwords.
# Usage: sudo bash scripts/launch.sh RANK [start|stop|status|logs|pack]
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run this local launcher with sudo.'
RANK=${1:?usage: launch.sh 0|1|2 [start|stop|status|logs|pack]}
ACTION=${2:-start}
RECIPE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${CONFIG:-$RECIPE_ROOT/config/cluster.env}
[[ -f "$CONFIG" ]] || die 'Copy config/cluster.env.example to config/cluster.env and edit it first.'
# This is a local administrator-owned shell configuration, never a fetched file.
source "$CONFIG"
[[ ${#NODE_IPS[@]} == 3 && "$RANK" =~ ^[012]$ ]] || die 'Configure exactly three node addresses; rank must be 0, 1 or 2.'
NODE_IP=${NODE_IPS[$RANK]}
[[ "$NODE_IP" != 192.0.2.* ]] || die 'Replace documentation-only example addresses in cluster.env.'
: "${MGMT_IF:?Set the reachable management interface in config/cluster.env}"
: "${DATA_DIR:?Set DATA_DIR in config/cluster.env}"
MASTER_ADDR=${NODE_IPS[0]}

LAB=$DATA_DIR
MODEL_DIR=${MODEL_DIR:-$LAB/models/DeepSeek-V4.1-Flash-native}
ENGRAM_DIR=${ENGRAM_DIR:-$LAB/engram}
STATE_DIR=${STATE_DIR:-$LAB/state/native-rank$RANK}
CACHE_DIR=${CACHE_DIR:-$LAB/cache/native-rank$RANK}
LOG_DIR=${LOG_DIR:-$LAB/logs}
NCCL_DIR=${NCCL_DIR:-$LAB/nccl/build/lib}
IMAGE=${IMAGE:-deepseek-v41-flash-three-sparks:public-v1}
NAME=${NAME:-dsv41-public-rank$RANK}
GPU_MODE=${GPU_MODE:-cdi}
GUARD_MIN_GIB=${GUARD_MIN_GIB:-2}
mkdir -p "$STATE_DIR" "$CACHE_DIR" "$LOG_DIR" "$ENGRAM_DIR"

case "$ACTION" in
  stop)
    docker container inspect "$NAME" >/dev/null 2>&1 || exit 0
    docker stop -t 20 "$NAME"
    docker logs "$NAME" > "$LOG_DIR/$NAME-stopped-$(date -u +%Y%m%dT%H%M%SZ).log" 2>&1 || true
    docker rm "$NAME"
    exit 0 ;;
  status)
    docker inspect --format '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$NAME"
    exit 0 ;;
  logs) docker logs --tail "${LOG_LINES:-100}" -f "$NAME"; exit 0 ;;
  guard)
    # This process owns only the exact container ID passed by start, never another workload.
    CID=${3:?guard requires a container ID}
    LOW=0
    while [[ $(docker inspect -f '{{.State.Running}}' "$CID" 2>/dev/null || true) == true ]]; do
      AVAIL_KIB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
      if (( AVAIL_KIB < GUARD_MIN_GIB * 1048576 )); then LOW=$((LOW + 1)); else LOW=0; fi
      if (( LOW >= 2 )); then
        echo "$(date -u +%FT%TZ) STOP rank=$RANK MemAvailable_KiB=$AVAIL_KIB guard_GiB=$GUARD_MIN_GIB container=$CID"
        docker stop -t 8 "$CID" || docker kill "$CID" || true
        exit 1
      fi
      sleep 2
    done
    exit 0 ;;
  start|pack) ;;
  *) die "Unknown action: $ACTION" ;;
esac

[[ -f "$MODEL_DIR/config.json" && -f "$MODEL_DIR/model.safetensors.index.json" ]] || die "Checkpoint metadata missing from $MODEL_DIR."
docker image inspect "$IMAGE" >/dev/null || die "Image missing: $IMAGE"
[[ $(docker image inspect -f '{{.Architecture}}' "$IMAGE") == arm64 ]] || die 'Serving image must be ARM64.'

if [[ "$ACTION" == pack ]]; then
  # No GPU or RDMA needed. Exact native FP8+scale rows, repacked into local files.
  docker run --rm --name "$NAME-pack" --memory 2g --memory-swap 2g \
    -e PYTHONPATH= \
    --mount "type=bind,src=$MODEL_DIR,dst=/models/DeepSeek-V4.1-Flash,readonly" \
    --mount "type=bind,src=$ENGRAM_DIR,dst=/engram" \
    --entrypoint python3 "$IMAGE" /opt/dsv41/scripts/pack_engram.py \
    --model /models/DeepSeek-V4.1-Flash --out /engram --rank "$RANK" --tp 3
  exit 0
fi

[[ -e "$NCCL_DIR/libnccl.so.2" ]] || die "Custom NCCL missing: $NCCL_DIR/libnccl.so.2"
[[ -d /dev/infiniband ]] || die '/dev/infiniband is missing.'
ip link show "$MGMT_IF" >/dev/null || die "Management interface $MGMT_IF is missing."
if docker container inspect "$NAME" >/dev/null 2>&1; then
  die "Container $NAME already exists. Stop it with this script before a new run."
fi
GPU_PIDS=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null || true)
if [[ "$GPU_PIDS" =~ [0-9] ]]; then die "GPU compute process already present; inspect it before launching: $GPU_PIDS"; fi
AVAIL_KIB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
(( AVAIL_KIB >= ${START_MIN_GIB:-110} * 1048576 )) || die "Insufficient boot headroom: $AVAIL_KIB KiB available."
for LAYER in 1 14; do
  [[ -f "$ENGRAM_DIR/engram-l$LAYER-r${RANK}of3.bin" ]] || die "Packed native Engram layer $LAYER missing; run the pack action."
done

case "$GPU_MODE" in
  cdi) GPU_ARGS=(--device nvidia.com/gpu=all) ;;
  runtime) GPU_ARGS=(--gpus all) ;;
  *) die 'GPU_MODE must be cdi or runtime.' ;;
esac

CONTEXT_LENGTH=${CONTEXT_LENGTH:-524288}
MAX_TOTAL_TOKENS=${MAX_TOTAL_TOKENS:-4200000}
MAX_RUNNING_REQUESTS=${MAX_RUNNING_REQUESTS:-8}
CHUNKED_PREFILL_SIZE=${CHUNKED_PREFILL_SIZE:-256}
MEM_FRACTION_STATIC=${MEM_FRACTION_STATIC:-0.95}
DSPARK_BLOCK_SIZE=${DSPARK_BLOCK_SIZE:-5}
SPEC_ALGO=${SPEC_ALGO:-DSPARK}
# Published profile: real native DSpark gamma5, K3 main experts, all precision
# and graph kernels pinned. These defaults reproduce the historical flags.
export DSV41_EXL3_MAIN_EXPERTS=1 DSV41_EXL3_COOP_ABI3=1
export DSV41_EXPERIMENT_TARGET_ROUTED_K=3 DSV41_TARGET_ROUTED_K_STAGE=full-model-validation
export DSV41_COMPACT_EXTRA_PREFILL=1 DSV41_MASK_TP3_DRAFT_PADDING=1 DSV41_RESIDENCY_TELEMETRY=1
export DSV41_WARM_PREFIX_OBSERVER=0 DSV41_INDEXER_PREFILL_ROWS=0
export DSV41_EXPERIMENT_RAGGED_ENGRAM=0 DSV41_SPS_EXECUTION_OBSERVER=0
unset SGLANG_SIMULATE_ACC_LEN SGLANG_RAGGED_VERIFY_MODE SGLANG_DSPARK_ENABLE_SPS_RECORD
unset SGLANG_DSPARK_DEBUG_DUMP DSV41_SPS_PROFILE_SESSION
DSPARK_SPS_TABLE=; DSPARK_STS_TABLE=
EXTRA_SGLANG_ARGS='--fp8-gemm-backend flashinfer_cutlass --watchdog-timeout 1800 --kt-method= --disable-flashinfer-autotune'
# Experimental prefill and SPS instrumentation require an explicit per-boot opt-in.
[[ ${DSV41_COMPACT_EXTRA_PREFILL:-0} =~ ^[01]$ ]] || die 'DSV41_COMPACT_EXTRA_PREFILL must be 0 or 1.'
[[ ${DSV41_EXL3_MAIN_EXPERTS:-0} =~ ^[01]$ ]] || die 'DSV41_EXL3_MAIN_EXPERTS must be 0 or 1.'
[[ ${DSV41_WARM_PREFIX_OBSERVER:-0} =~ ^[01]$ ]] || die 'DSV41_WARM_PREFIX_OBSERVER must be 0 or 1.'
if [[ ${DSV41_WARM_PREFIX_OBSERVER:-0} == 1 ]]; then
  [[ ${DSV41_RESIDENCY_TELEMETRY:-0} == 1 ]] || die 'Warm prefix observer requires DSV41_RESIDENCY_TELEMETRY=1.'
fi
[[ ${DSV41_INDEXER_PREFILL_ROWS:-0} == 0 || ${DSV41_INDEXER_PREFILL_ROWS:-0} == 32 ]] || die 'DSV41_INDEXER_PREFILL_ROWS must be 0 or 32.'
# Ragged Engram is an isolated opt-in, gated by actual GPU evidence.
[[ ${DSV41_EXPERIMENT_RAGGED_ENGRAM:-0} =~ ^[01]$ ]] || die 'DSV41_EXPERIMENT_RAGGED_ENGRAM must be 0 or 1.'
RAGGED_ENV=()
RAGGED_MOUNTS=()
if [[ ${DSV41_EXPERIMENT_RAGGED_ENGRAM:-0} == 1 ]]; then
  case ${DSV41_RAGGED_ENGRAM_STAGE:-} in
    full-model-validation|qualified) ;;
    *) die 'Explicit ragged Engram full-model-validation or qualified stage required.' ;;
  esac
  RAGGED_ENGRAM_EVIDENCE_DIR=${RAGGED_ENGRAM_EVIDENCE_DIR:-$LAB/state/ragged-engram-evidence}
  [[ -f "$RAGGED_ENGRAM_EVIDENCE_DIR/component.json" ]] || die 'Actual ragged Engram component GPU PASS receipt is missing.'
  [[ ${DSV41_RAGGED_ENGRAM_COMPONENT_RECEIPT_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || die 'Explicit component receipt SHA256 required.'
  RAGGED_MOUNTS+=(--mount "type=bind,src=$RAGGED_ENGRAM_EVIDENCE_DIR,dst=/evidence/ragged-engram,readonly")
  RAGGED_ENV+=("DSV41_RAGGED_ENGRAM_STAGE=$DSV41_RAGGED_ENGRAM_STAGE"
    "DSV41_RAGGED_ENGRAM_COMPONENT_RECEIPT=/evidence/ragged-engram/component.json"
    "DSV41_RAGGED_ENGRAM_COMPONENT_RECEIPT_SHA256=$DSV41_RAGGED_ENGRAM_COMPONENT_RECEIPT_SHA256")
  if [[ $DSV41_RAGGED_ENGRAM_STAGE == qualified ]]; then
    [[ -f "$RAGGED_ENGRAM_EVIDENCE_DIR/full-model.json" ]] || die 'Ragged Engram full-model PASS receipt missing.'
    [[ ${DSV41_RAGGED_ENGRAM_FULL_MODEL_RECEIPT_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || die 'Explicit full-model receipt SHA256 required.'
    RAGGED_ENV+=("DSV41_RAGGED_ENGRAM_FULL_MODEL_RECEIPT=/evidence/ragged-engram/full-model.json"
      "DSV41_RAGGED_ENGRAM_FULL_MODEL_RECEIPT_SHA256=$DSV41_RAGGED_ENGRAM_FULL_MODEL_RECEIPT_SHA256")
  fi
  RAGGED_CPU=(run --rm --network none --memory 128m --memory-swap 128m --entrypoint python3)
  RAGGED_CPU+=("${RAGGED_MOUNTS[@]}")
  for ITEM in "${RAGGED_ENV[@]}"; do RAGGED_CPU+=(-e "$ITEM"); done
  # Pure stdlib -S checker: verifies installed source and bound receipts; no GPU,
  # SGLang, runtime_context or model imports. Runtime constraints run on forward.
  docker "${RAGGED_CPU[@]}" "$IMAGE" -S /opt/ragged-engram-serving-build/check_image.py
fi
# Cooperative ABI3 retains its own same-binary component-policy preflight.
[[ ${DSV41_EXL3_COOP_ABI3:-0} =~ ^[01]$ ]] || die 'DSV41_EXL3_COOP_ABI3 must be 0 or 1.'
if [[ ${DSV41_EXL3_COOP_ABI3:-0} == 1 ]]; then
  [[ ${DSV41_EXL3_MAIN_EXPERTS:-0} == 1 ]] || die 'Cooperative ABI3 requires EXLv011 main experts.'
  docker run --rm --network none --memory 128m --memory-swap 128m --entrypoint python3     -e DSV41_EXL3_COOP_ABI3=1 -e DSV41_EXL3_MAIN_EXPERTS=1 "$IMAGE" -S -c 'import hashlib,pathlib,runpy,sys; p=pathlib.Path("/opt/dsv41-coop-integration/preflight.py"); assert hashlib.sha256(p.read_bytes()).hexdigest()=="dff64f77a6515ed222c37f6b8abb562aa52bdb4e42aea267e6b28bd9f904a98a", "Coop preflight source mismatch"; sys.path.insert(0,str(p.parent)); runpy.run_path(str(p),run_name="__main__")' 
fi
# Isolated reduced-target-K derivative; K6 has no routing hook.
TARGET_ROUTED_K=${DSV41_EXPERIMENT_TARGET_ROUTED_K:-6}
[[ $TARGET_ROUTED_K == 6 || $TARGET_ROUTED_K == 5 || $TARGET_ROUTED_K == 4 || $TARGET_ROUTED_K == 3 ]] || die 'Target routed K must be 6, 5, 4 or 3.'
TARGET_ROUTED_K_IMAGE_ID=
if [[ $TARGET_ROUTED_K != 6 ]]; then
  [[ " ${EXTRA_SGLANG_ARGS:-} " == *" --disable-flashinfer-autotune "* ]] || die 'Reduced K requires --disable-flashinfer-autotune before graph preparation.'
  [[ " ${EXTRA_SGLANG_ARGS:-} " == *" --kt-method= "* ]] || die 'EXL requires explicit empty --kt-method=.'
  [[ ${DSV41_TARGET_ROUTED_K_STAGE:-} == full-model-validation ]] || die 'Reduced K requires explicit full-model-validation stage.'
  [[ ${DSV41_EXL3_MAIN_EXPERTS:-0} == 1 && ${DSV41_EXL3_COOP_ABI3:-0} == 1 ]] || die 'Reduced K requires original EXL and cooperative ABI3.'
  [[ ${DSV41_EXPERIMENT_RAGGED_ENGRAM:-0} == 0 && ${DSV41_SPS_EXECUTION_OBSERVER:-0} == 0 && ${DSV41_INDEXER_PREFILL_ROWS:-0} == 0 ]] || die 'Isolate reduced K from ragged, SPS observer and indexer experiments.'
  [[ ${DSV41_SPS_PROFILE_SESSION:-0} == 0 && ${SGLANG_DSPARK_ENABLE_SPS_RECORD:-0} == 0 && ! ${SGLANG_SIMULATE_ACC_LEN+x} ]] || die 'Reduced K requires real unsimulated speculation.'
  TARGET_ROUTED_K_IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE")
  [[ $TARGET_ROUTED_K_IMAGE_ID =~ ^sha256:[0-9a-f]{64}$ ]] || die 'Immutable target image ID missing.'
  # All later calls use this resolved identity, preventing tag replacement.
  IMAGE=$TARGET_ROUTED_K_IMAGE_ID
  docker run --rm --network none --memory 256m --memory-swap 256m --entrypoint python3 \
    -e "DSV41_EXPERIMENT_TARGET_ROUTED_K=$TARGET_ROUTED_K" -e DSV41_TARGET_ROUTED_K_STAGE=full-model-validation \
    -e DSV41_EXL3_COOP_ABI3=1 -e DSV41_EXL3_MAIN_EXPERTS=1 \
    "$IMAGE" -S -c 'import hashlib,pathlib,runpy,sys; p=pathlib.Path("/opt/dsv41-target-routed-k/preflight.py"); assert hashlib.sha256(p.read_bytes()).hexdigest()=="97036ed2315bb8a9cb664b14f761a4e3bb1a4b8314d155d63a0de4b7b2ae7d59", "Target preflight source mismatch"; sys.path.insert(0,str(p.parent)); runpy.run_path(str(p),run_name="__main__")'
fi

# Observer is permitted only in a dedicated simulated compact gamma5 profile.
[[ ${DSV41_SPS_EXECUTION_OBSERVER:-0} =~ ^[01]$ ]] || die 'DSV41_SPS_EXECUTION_OBSERVER must be 0 or 1.'
if [[ ${DSV41_SPS_EXECUTION_OBSERVER:-0} == 1 ]]; then
  [[ ${DSV41_SPS_PROFILE_SESSION:-0} == 1 && ${SGLANG_DSPARK_ENABLE_SPS_RECORD:-0} == 1 && ${SGLANG_SIMULATE_ACC_LEN:-} == 1 ]] || die 'Observer requires dedicated SPS simulation/recording exactly1.'
  [[ $DSPARK_BLOCK_SIZE == 5 && $SPEC_ALGO == DSPARK && ${SGLANG_RAGGED_VERIFY_MODE:-} == compact ]] || die 'Observer requires compact DSPARK gamma5.'
  [[ ${DSV41_EXPERIMENT_RAGGED_ENGRAM:-0} == 1 ]] || die 'Observer requires opted-in ragged Engram.'
  (( MAX_RUNNING_REQUESTS >= 1 && MAX_RUNNING_REQUESTS <= 8 )) || die 'Observer scope is C1..8.'
  [[ ${DSV41_INDEXER_PREFILL_ROWS:-0} == 0 ]] || die 'First composed experiment must retain native indexer.'
  docker run --rm --network none --memory 128m --memory-swap 128m --entrypoint python3     -e DSV41_SPS_EXECUTION_OBSERVER=1 -e DSV41_SPS_PROFILE_SESSION=1     -e SGLANG_DSPARK_ENABLE_SPS_RECORD=1 -e SGLANG_SIMULATE_ACC_LEN=1     -e SGLANG_RAGGED_VERIFY_MODE=compact -e DSPARK_BLOCK_SIZE=5     -e DSV41_EXPERIMENT_RAGGED_ENGRAM=1 -e "NODE_RANK=$RANK"     "$IMAGE" -S /opt/ragged-sps-combined/preflight.py
fi
# Reject unsupported opt-ins instead of silently benchmarking an unchanged image.
if [[ ${DSV41_EXL3_MAIN_EXPERTS:-0} == 1 || ${DSV41_INDEXER_PREFILL_ROWS:-0} == 32 || ${DSV41_COMPACT_EXTRA_PREFILL:-0} == 1 || ${DSV41_WARM_PREFIX_OBSERVER:-0} == 1 ]]; then
  docker run --rm -i --network none --memory 128m --memory-swap 128m --entrypoint python3 "$IMAGE" -S - \
    "${DSV41_EXL3_MAIN_EXPERTS:-0}" "${DSV41_INDEXER_PREFILL_ROWS:-0}" "${DSV41_COMPACT_EXTRA_PREFILL:-0}" "${DSV41_WARM_PREFIX_OBSERVER:-0}" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path('/sgl-workspace/sglang/python/sglang')
adapter = pathlib.Path('/opt/dsv41/adapter')
def check(path, digest):
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise SystemExit('Enabled experiment missing or changed in image: ' + str(path))
if sys.argv[1] == '1':
    check(root/'srt/models/deepseek_v4.py', '29f84eaba28e33a74438d394649a3020cb02959db9ffa2549b1f847cde512ff3')
    check(pathlib.Path('/opt/sglang/lib/python3.12/site-packages/cuda_exl3/_C.cpython-312-aarch64-linux-gnu.so'), '71777ec6f3efdf5319aee7800724a91f864ab0af360eafeac081136facb3da0a')
    if not (root/'srt/layers/quantization/exl3_spark/runtime.py').is_file():
        raise SystemExit('EXL3 runtime module missing')
if sys.argv[2] == '32':
    check(root/'srt/layers/attention/deepseek_v4_backend.py', '66e974d1b71511c1e5f306183a7fcdc758b1b72f9e7b0c5065e406c4c498d85e')
    check(adapter/'dsv41_indexer_rows.py', '978f3446d05f491f67cd4a70ce4efd8971cac9ea6039e7fb69d16eed2334a9af')
if sys.argv[3] == '1':
    check(root/'kernels/ops/attention/flash_mla_sm120.py', 'c589015873537a41cfb81b51b94d22a3da54dcd90c5bcaab0441037d9ab0851c')
    check(adapter/'dsv41_compact_extra.py', '761d7f554407293c90a86075a2003307d0184f99266e7501cd2f1805d887d59c')
if sys.argv[4] == '1':
    check(root/'srt/entrypoints/openai/protocol.py', '9447216f7c7500530c35829045ac6440a48f31a914505fd76ea3bf6552b8080e')
    check(root/'srt/entrypoints/openai/serving_chat.py', '7c33913c2eb59c189d96ef038cf1a9cbe1ad943b122bea0de687e7d0c9fbf9e6')
    check(root/'srt/managers/io_struct.py', 'ebe1d216c98d0918c39089832f872a225977ce53c244680c9bcee51dee70e9e6')
    check(root/'srt/managers/schedule_batch.py', 'fad9db4f282622ed612818ebd10e35c5477f08eec556b07f339f51c51cc66430')
    check(root/'srt/managers/scheduler.py', '05df58e451a21d420571ce732f95c60d683d8729c92b587874551fa9f4c1a55b')
    check(root/'srt/managers/scheduler_components/residency_telemetry.py', 'b9a631e56089d3eaf91eb67883efbd9f83850f02429107bcb5c8a7e685e7db35')
    check(root/'srt/managers/scheduler_components/residency_telemetry_v1.py', '89e5e9c4fabcfebac793e15c261bfb865d6ad9b3268d591818916fff4ceefba9')
    check(root/'srt/managers/scheduler_components/warm_prefix_observer.py', '1455e70412bf29f9f78aff921a3e8cb8fda2c27c49bdb8c9f32f97423ade4e55')
    check(root/'srt/mem_cache/radix_cache.py', '02405d32974bf013daaabdfd90a4498d170bb41d02547ae465475c31eb61ee84')
    check(root/'srt/mem_cache/registry.py', 'd7a36fdbed3283960a70ebf017e6ecb0fe64ba5f09d978d5589ff7bfc8deec32')
    check(root/'srt/mem_cache/unified_radix_cache.py', '4d04e8f7b5a5f0e00fab9dcfa9a0e60bd81dee6e82942aec7a2bd456e87935af')
    check(root/'srt/managers/scheduler_components/warm-prefix-installed-lock.json', '572d36b21210e910fff2f569460d863df09f67eeea0564a9252dad52c336d730')
print('Enabled experiment image source checks PASS (no GPU or model loaded)')
PY
fi
[[ ${DSV41_SPS_PROFILE_SESSION:-0} =~ ^[01]$ ]] || die 'DSV41_SPS_PROFILE_SESSION must be 0 or 1.'
[[ ${SGLANG_DSPARK_ENABLE_SPS_RECORD:-0} =~ ^[01]$ ]] || die 'SGLANG_DSPARK_ENABLE_SPS_RECORD must be 0 or 1.'
if [[ ${SGLANG_SIMULATE_ACC_LEN+x} || ${SGLANG_DSPARK_ENABLE_SPS_RECORD:-0} == 1 || -n ${SGLANG_DSPARK_DEBUG_DUMP:-} ]]; then
  [[ ${DSV41_SPS_PROFILE_SESSION:-0} == 1 ]] || die 'SPS simulation/recording/debug requires DSV41_SPS_PROFILE_SESSION=1 on this dedicated profiling boot.'
fi
API_HOST=${API_HOST:-127.0.0.1}
# The pinned boot.py health/smoke client always connects to 127.0.0.1.
[[ "$API_HOST" == 127.0.0.1 || "$API_HOST" == 0.0.0.0 ]] || die 'Use API_HOST=127.0.0.1 or 0.0.0.0; pinned health checks require loopback.'
EXTRA_SGLANG_ARGS=${EXTRA_SGLANG_ARGS:---fp8-gemm-backend flashinfer_cutlass --watchdog-timeout 1800}
if (( MAX_RUNNING_REQUESTS >= 8 )); then
  EXTRA_SGLANG_ARGS="$EXTRA_SGLANG_ARGS --min-free-slots-delay 1"
fi

ARGS=(run -d --name "$NAME" --restart no --network host --ipc host
  "${GPU_ARGS[@]}" --cap-add IPC_LOCK --cap-add SYS_NICE --device /dev/infiniband:/dev/infiniband
  --shm-size 32g --ulimit memlock=-1:-1 --ulimit stack=67108864 --oom-score-adj 1000
  --label spark.experiment=deepseek-v41-native --label "spark.rank=$RANK"
  --mount "type=bind,src=$MODEL_DIR,dst=/models/DeepSeek-V4.1-Flash,readonly"
  --mount "type=bind,src=$ENGRAM_DIR,dst=/engram,readonly"
  --mount "type=bind,src=$STATE_DIR,dst=/state"
  --mount "type=bind,src=$CACHE_DIR,dst=/root/.cache"
  --mount "type=bind,src=$NCCL_DIR,dst=/opt/spark-nccl,readonly"
  # Torch explicitly preloads this wheel path before consulting LD_LIBRARY_PATH.
  # This path belongs to the pinned ARM64 base image; use the same custom binary.
  --mount "type=bind,src=$NCCL_DIR,dst=/opt/sglang/lib/python3.12/site-packages/nvidia/nccl/lib,readonly"
)
ENVIRON=(
  "LD_LIBRARY_PATH=/opt/spark-nccl:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/cuda/lib64"
  "SGLANG_NCCL_SO_PATH=/opt/spark-nccl/libnccl.so.2"
  "OFFLOAD_MODE=nvme" "DSV41_CACHE_GIB=0" "DSV41_RESIDENT_SCALES=0"
  "DSV41_IO_THREADS=${DSV41_IO_THREADS:-96}" "DSV41_CACHE_WAYS=4" "DSV41_STATS_SECONDS=60"
  "DSV41_PACKED_DIR=/engram" "DSV41_SOURCE=/models/DeepSeek-V4.1-Flash"
  "MODEL_PATH=/models/DeepSeek-V4.1-Flash" "STATE_PATH=/state"
  "NODE_RANK=$RANK" "NNODES=3" "TP_SIZE=3" "EP_SIZE=3"
  "DIST_INIT_ADDR=$MASTER_ADDR:${DIST_PORT:-20000}" "SERVER_PORT=8888" "HOST=$API_HOST"
  "HOST_IP=$NODE_IP" "VLLM_HOST_IP=$NODE_IP"
  "CONTEXT_LENGTH=$CONTEXT_LENGTH" "MAX_TOTAL_TOKENS=$MAX_TOTAL_TOKENS"
  "MAX_RUNNING_REQUESTS=$MAX_RUNNING_REQUESTS" "CUDA_GRAPH_MAX_BS_DECODE=$MAX_RUNNING_REQUESTS"
  "CHUNKED_PREFILL_SIZE=$CHUNKED_PREFILL_SIZE" "MEM_FRACTION_STATIC=$MEM_FRACTION_STATIC"
  "SPEC_ALGO=$SPEC_ALGO" "DSPARK_BLOCK_SIZE=$DSPARK_BLOCK_SIZE"
  "MOE_RUNNER_BACKEND=${MOE_RUNNER_BACKEND:-flashinfer_mxfp4}"
  "DSPARK_SPS_TABLE=${DSPARK_SPS_TABLE-/state/dspark_sps.json}"
  "DSPARK_STS_TABLE=${DSPARK_STS_TABLE-/state/dspark_sts.json}"
  "SERVED_MODEL_NAME=deepseek-v4.1-flash" "SKIP_PREPARE=1" "SKIP_VERIFY=1"
  "SKIP_SMOKE=${SKIP_SMOKE:-0}" "SMOKE_QUICK=${SMOKE_QUICK:-1}" "WARMUP=${WARMUP:-1}"
  "EXTRA_SGLANG_ARGS=$EXTRA_SGLANG_ARGS"
  "DSV41_MXFP8_BACKEND=${DSV41_MXFP8_BACKEND:-b12x}"
  "SGLANG_FLASHINFER_MOE_FUSED_FINALIZE=0" "SGLANG_ENABLE_DSV41_ENGRAM_HOST_TABLE=0"
  "DSV41_TP_PAD=1" "SGLANG_DSV41_REASONING_EFFORT=${REASONING_EFFORT:-75}"
  "DSV41_MASK_TP3_DRAFT_PADDING=${DSV41_MASK_TP3_DRAFT_PADDING:-0}"
  "DSV41_RESIDENCY_TELEMETRY=${DSV41_RESIDENCY_TELEMETRY:-0}"
  "DSV41_WARM_PREFIX_OBSERVER=${DSV41_WARM_PREFIX_OBSERVER:-0}"
  "DSV41_EXPERIMENT_RAGGED_ENGRAM=${DSV41_EXPERIMENT_RAGGED_ENGRAM:-0}"
  "DSV41_SPS_EXECUTION_OBSERVER=${DSV41_SPS_EXECUTION_OBSERVER:-0}"
  "DSV41_EXL3_COOP_ABI3=${DSV41_EXL3_COOP_ABI3:-0}"
  "DSV41_EXPERIMENT_TARGET_ROUTED_K=$TARGET_ROUTED_K"
  "DSV41_TARGET_ROUTED_K_STAGE=${DSV41_TARGET_ROUTED_K_STAGE:-}"
  "DSV41_TARGET_ROUTED_K_EXECUTION_IMAGE_ID=$TARGET_ROUTED_K_IMAGE_ID"
  "DSV41_NVFP4_CUTLASS_EXPERIMENT=${DSV41_NVFP4_CUTLASS_EXPERIMENT:-0}"
  "DSV41_COMPACT_EXTRA_PREFILL=${DSV41_COMPACT_EXTRA_PREFILL:-0}"
  "DSV41_INDEXER_PREFILL_ROWS=${DSV41_INDEXER_PREFILL_ROWS:-0}"
  "DSV41_EXL3_MAIN_EXPERTS=${DSV41_EXL3_MAIN_EXPERTS:-0}"
  "SGLANG_FLASHINFER_NVFP4_PER_TOKEN_ACTIVATION=0"
  "DSV41_MAX_NEW_TOKENS=${DSV41_MAX_NEW_TOKENS:-32768}"
  "DSV41_LOOP_ABORT=${DSV41_LOOP_ABORT:-0}"
  "DSV41_PREFILL_EMPTY_CACHE_TOKENS=${DSV41_PREFILL_EMPTY_CACHE_TOKENS:-8192}"
  "PYTORCH_CUDA_ALLOC_CONF=expandable_segments:False" "CUDA_DEVICE_ORDER=PCI_BUS_ID"
  "MAX_JOBS=2" "FLASHINFER_NVCC_THREADS=1"
  "NCCL_NET=IB" "NCCL_IB_DISABLE=0" "NCCL_NET_PLUGIN=none"
  "NCCL_IB_HCA=${RDMA_HCAS:-rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1}"
  "NCCL_SOCKET_IFNAME=$MGMT_IF" "GLOO_SOCKET_IFNAME=$MGMT_IF" "NCCL_SOCKET_FAMILY=AF_INET"
  "NCCL_P2P_DISABLE=1" "NCCL_SHM_DISABLE=1" "NCCL_CROSS_NIC=1"
  "NCCL_IB_SUBNET_AWARE_ROUTING=1" "NCCL_IB_MERGE_NICS=0" "NCCL_CUMEM_ENABLE=0"
  "NCCL_BUFFSIZE=${NCCL_BUFFSIZE:-1048576}" "NCCL_LL128_BUFFSIZE=${NCCL_LL128_BUFFSIZE:-262144}"
  "NCCL_PROTO=${NCCL_PROTO:-^LL128}" "NCCL_MAX_NCHANNELS=${NCCL_MAX_NCHANNELS:-8}"
  "NCCL_DEBUG=${NCCL_DEBUG:-INFO}" "NCCL_DEBUG_SUBSYS=${NCCL_DEBUG_SUBSYS:-INIT,ENV}"
)
ARGS+=("${RAGGED_MOUNTS[@]}")
ENVIRON+=("${RAGGED_ENV[@]}")
# Expert-only adapter retains native MODEL_PATH and mounts its independently
# verified alternative checkpoint and checksum receipt read-only.
if [[ ${DSV41_EXL3_MAIN_EXPERTS:-0} == 1 ]]; then
  EXL3_MODEL_DIR=${EXL3_MODEL_DIR:-$LAB/models/DeepSeek-V4.1-Flash-EXL3-3.5}
  EXL3_RECEIPT=${EXL3_RECEIPT:-$LAB/state/exl3-download.json}
  [[ -f "$EXL3_MODEL_DIR/model.safetensors.index.json" && -f "$EXL3_RECEIPT" ]] || die 'EXL3 checkpoint metadata or verification receipt missing.'
  [[ ${MOE_RUNNER_BACKEND:-flashinfer_mxfp4} == flashinfer_mxfp4 ]] || die 'EXL3 adapter requires native shared/draft flashinfer_mxfp4 backend.'
  ARGS+=(--mount "type=bind,src=$EXL3_MODEL_DIR,dst=/models/DeepSeek-V4.1-Flash-EXL3-3.5,readonly"
    --mount "type=bind,src=$EXL3_RECEIPT,dst=/evidence/exl3-download.json,readonly")
  ENVIRON+=("DSV41_EXL3_CHECKPOINT=/models/DeepSeek-V4.1-Flash-EXL3-3.5"
    "DSV41_EXL3_VERIFICATION_RECEIPT=/evidence/exl3-download.json"
    "SGLANG_OPT_MOE_QUANT_ONCE=0" "SGLANG_ENABLE_MOE_DEFERRED_FINALIZE=0" "SGLANG_DSV4_FP4_DEQUANT=0")
fi
# Leave SPS simulation/profiling unset in ordinary boots. Forward only the
# allowlisted variables explicitly supplied by the operator, including empties.
for OPTIN_NAME in DSV41_SPS_PROFILE_SESSION SGLANG_DSPARK_ENABLE_SPS_RECORD \
  SGLANG_SIMULATE_ACC_LEN SGLANG_DSPARK_DEBUG_DUMP SGLANG_RAGGED_VERIFY_MODE; do
  if [[ ${!OPTIN_NAME+x} ]]; then ENVIRON+=("$OPTIN_NAME=${!OPTIN_NAME}"); fi
done
# Let the subnet-aware NCCL build select a per-port GID unless explicitly overridden.
[[ -z ${NCCL_IB_GID_INDEX:-} ]] || ENVIRON+=("NCCL_IB_GID_INDEX=$NCCL_IB_GID_INDEX")
if [[ "$RANK" != 0 ]]; then ENVIRON+=("SKIP_SMOKE=1" "WARMUP=0"); fi
for ITEM in "${ENVIRON[@]}"; do ARGS+=(-e "$ITEM"); done
# Docker reads this environment variable without putting the secret in argv or the run manifest.
if [[ -f "$LAB/state/api-key" ]]; then
  API_KEY=$(< "$LAB/state/api-key")
  [[ -n "$API_KEY" ]] || die 'API key file exists but is empty.'
  export API_KEY
  ARGS+=(-e API_KEY)
  ARGS+=(--mount "type=bind,src=$LAB/state/api-key,dst=/run/dsv41-api-key,readonly")
fi
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
printf '%s\n' "image=$(docker image inspect -f '{{.Id}}' "$IMAGE")" "rank=$RANK" "${ENVIRON[@]}" \
  > "$LOG_DIR/$NAME-$STAMP-env.txt"
CID=$(docker "${ARGS[@]}" "$IMAGE" run)
printf 'Started %s rank=%s id=%s context=%s pool=%s concurrency=%s chunk=%s DSpark=%s/%s\n' \
  "$NAME" "$RANK" "$CID" "$CONTEXT_LENGTH" "$MAX_TOTAL_TOKENS" "$MAX_RUNNING_REQUESTS" \
  "$CHUNKED_PREFILL_SIZE" "$SPEC_ALGO" "$DSPARK_BLOCK_SIZE"
if (( GUARD_MIN_GIB > 0 )); then
  nohup env LAB="$LAB" LOG_DIR="$LOG_DIR" GUARD_MIN_GIB="$GUARD_MIN_GIB" \
    bash "$(readlink -f "$0")" "$RANK" guard "$CID" \
    > "$LOG_DIR/$NAME-$STAMP-guard.log" 2>&1 < /dev/null &
fi
echo "Inspect startup with: docker logs --tail 100 -f $NAME"

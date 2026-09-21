# Provenance

This repository contains a public reconstruction of a historical three-DGX-Spark experiment, together with sanitized numeric exports. Model weights, complete benchmark corpora, images, raw replies, and operational logs are not redistributed.

## Checkpoints and target function

| Source | Pinned revision |
|---|---|
| [DeepSeek V4.1 Flash](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash) | `fb2764a5cf321eaa5070ca8f9e892818f477c16d` |
| [Pollard EXL3 3.5 bpw main experts](https://huggingface.co/bot-lab-21/DeepSeek-V4.1-Flash-EXL3-3.5bpw-Pollard) | `f129e31a81e1337aa33e129e2d847fc7e37c8733` |

Only the main routed-expert weights in layers 0–39 are replaced by the Pollard checkpoint. Each layer still stores 384 routed experts. The candidate selects three routes rather than the native six, during prefill, decode, and target verification. Six physical slots are retained with zero-weight padding. The native image routing parameters and selected unbiased sqrtsoftplus normalization are retained by the target implementation.

The selected target function identifier is:

```text
sha256:598293f99398d279706acf183bb39a7dcee1439715ba31f4430d8ddec267f58a
```

The historical runtime identifier is `hybrid-pollard-coop-targetK3-static5-v020-qos0-warm0`: cooperative ABI3, static DSpark block size 5, target K3, NVMe QoS 0 during measurements, and no warm-prefix observer. [runtime-profile.json](../results/runtime-profile.json) records the public settings.

The baseline definition records the published native MXFP4 weights, native K6 routing, and all 48 native checkpoint shard hashes matching the pinned revision. It is a native-weight **local adapted-stack reference**, not a BF16 or unmodified publisher-stack result. Its historical records do not provide the later candidate's complete all-rank inventory at the exact baseline quality boot. Consequently the comparison is reported as the observed local paired pilot, without a claim of bitwise native-runtime equivalence.

Engram storage preserves native FP8 E4M3 weight bytes and UE8M0 scale bytes. Rows are repacked as 256 weight bytes plus eight scale bytes for local NVMe lookup. The reported recipe does not prune rows, product-quantize them, or convert them to INT4. The native vision tower and aligner are retained. Speculative verification uses the modified target.

## Runtime sources and attribution

The source package retains component notices and licenses. The packaged revisions are:

| Project | Revision |
|---|---|
| [Mia three-Spark recipe](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks) | `fba44707a12026a7bf92c85b234e5aa44923fc14` |
| [SGLang](https://github.com/sgl-project/sglang) | `da64c5cbb8cf6bfd39be19da43573fdfd484c43a` |
| [cuda-exl3](https://github.com/Zeuss5/cuda-exl3) | `6a1ffc34866e23f484574ce1922a8bca93eb33b2` |
| [ExLlamaV3](https://github.com/turboderp-org/exllamav3) cooperative source | `02aef45cd681b960a00afcd0749a4ab99e6c1bfe` |
| [NCCL Spark source](https://github.com/zyang-dev/nccl) | `fab1850acd902672d79ca81c2e7fb8e1848c208c` (2.29.7) |

Mia's notices also credit the [0xSero recipe](https://github.com/0xSero/deepseek-v4.1-flash-4x-rtx-pro-6000) for the recipe skeleton and Engram row-store idea. Component licenses remain applicable; this document is attribution, not a replacement for their terms.

Public packaging includes the measured extension binaries with their sources and manifests. Rebuilding an extension creates a new unqualified artifact until its correctness and workload gates are repeated. If sources are distributed in `runtime-source.tar.gz`, the top-level build tooling verifies and extracts that package before assembling the runtime. Consult the top-level scripts and configuration rather than historical launch examples inside vendored sources.

The fresh public ARM64 image build and component checks passed. Those checks do not load and re-evaluate the full GPU model. Historical performance belongs to the original recorded runtime and remains distinct from the public reconstruction's build validation.

## Evaluation inputs

| Input source | Pinned revision / protocol |
|---|---|
| [TIGER-Lab/MMLU-Pro](https://huggingface.co/datasets/TIGER-Lab/MMLU-Pro) | `b189ec765aa7ed75c8acfea42df31fdae71f97be` |
| [MMMU/MMMU](https://huggingface.co/datasets/MMMU/MMMU) | `98e6ac0cb9b7b2cd2c991b85a50762edc4aedc68` |
| [OpenAI HumanEval](https://github.com/openai/human-eval) | `6d43fb980f9fee3c892a914eda09951f772ad10d` |
| Text/vision local protocol | `local-v41-paired-zero-shot-mc-v1` |
| Coding local protocol | `dsv41.humaneval64.complete-module.v1` |
| Long-context task package | `long500k-vision-v0.1` |

The text/vision pilot manifest SHA-256 is `7e1f8e05f705b2bd3a0842bb97d4ebc61376b4c753c4096decf55275816f5bcf`. The coding manifest SHA-256 is `62cd0d185dcdba12db0a88cc5103483a5026599ab90f600b94dc568b20464d56`. Selected case IDs, sampling rules, budgets, and paired coding outcomes are in [quality-pilot-192.json](../results/quality-pilot-192.json).

The long-context package manifest SHA-256 is `db01e56cb7509336e73c7c7cd6778965312e0b86e7e232a5f1bf1b67635a87b7`. It combines synthetic independent archives with selected MMMU images and additional tasks. It is not a standard MMMU long-context benchmark. The six image source case IDs are published, but the images and question text are not.

## Export and audit policy

The public JSON files were constructed using explicit allowlists, not by copying raw records and trying to redact every sensitive field. Exported fields include counts, elapsed durations, settings, public checkpoint/dataset identifiers, paired scores, and SHA-256 hashes. Network addresses, machine/user identities, device identifiers, credentials, raw prompt/response content, and dataset media were excluded.

[SOURCE_ARTIFACTS.json](../results/SOURCE_ARTIFACTS.json) records a logical role, original basename, and SHA-256 digest for each source artifact used in these exports. It intentionally omits original absolute paths. The original private logs and full datasets are not available in this repository; the hashes identify them but cannot substitute for their contents in an independent audit.

Arithmetic checks recomputed each exported short-run throughput from the common-interval token count and duration, the long-run conservative generation rates from the upper duration bound, and the paired quality totals from the domain counts. These checks validate internal consistency of the exported numbers. They do not replace re-executing the workloads or independently verifying the omitted raw records.

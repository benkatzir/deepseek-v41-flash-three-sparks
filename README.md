# DeepSeek V4.1 Flash on three DGX Sparks

An experimental recipe for running DeepSeek V4.1 Flash with native vision across three DGX Sparks connected by three direct QSFP links. It combines Pollard EXL3 3.5 bpw routed experts, cooperative expert execution, native-precision Engram rows on local NVMe, and DSpark speculative decoding.

**This is a useful research result, with an important boundary: six independent 500k-token image requests completed, but their long-context answer checks failed.** It is not a qualified accurate 500k-context service. The public source package reconstructs the measured private runtime; a fresh build of this package has not been re-benchmarked.

## What was measured

All numbers below are from the same selected **K3 / static DSpark γ5** candidate. K3 changes the model from six to three routed experts per token. These results do not use the faster K2 or other rejected candidates.

| Workload | Concurrency | Observed speed per stream | Common measurement window | Result |
|---|---:|---:|---:|---|
| Short prompts, one image per request | 6 | **30.0–41.2 tokens/s** | **61.47 s** | All six completed; 208.2 tokens/s aggregate |
| Short prompts, one image per request | 8 | **15.0–25.2 tokens/s** | **46.79 s** | All eight completed; 180.2 tokens/s aggregate |
| Independent 500,741–500,802-token prompts, one image each | 6 | **18.8–24.25 generated tokens/s** | **8.41 s** | All six completed; about **81.1 minutes** until all six were fully prefilled |
| Selected text, vision, and coding quality pilot | 6 | Not a speed test | 192 cases | Candidate **157/192**, native baseline **157/192**; **five losses and five gains** |

The short-prompt rates use generated-token counts observed in streamed responses. The 500k rates use accepted generation counts from sampled scheduler telemetry; they do **not** establish streamed delivery speed or sustained 60-second performance. The long trial scored **0/24 exact lookups, 0/6 evidence-chain terminals, and 1/6 image answer fields**. Formatting accounted for some errors, but did not explain the failures. The eight-way 500k trial was canceled before qualification; it yielded no capacity or speed result.

See [benchmark methods and exact results](docs/BENCHMARKS.md), [limitations](docs/LIMITATIONS.md), and the [machine-readable evidence](results/README.md).

## The selected recipe

“Strongest” here means the locally selected candidate with completed short-context text/vision/coding comparisons and completed six-way populated-context testing. It does not mean globally optimal, fastest, native-equivalent, or best among all public Spark recipes.

| Component | Setting |
|---|---|
| Hardware | 3 × DGX Spark, 128 GB unified memory each; direct QSFP triangle |
| Parallelism | TP3 / EP3 with three-way compatibility padding |
| Native checkpoint | [`deepseek-ai/DeepSeek-V4.1-Flash`](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash), revision `fb2764a5cf321eaa5070ca8f9e892818f477c16d` |
| Main routed expert weights | [`bot-lab-21/DeepSeek-V4.1-Flash-EXL3-3.5bpw-Pollard`](https://huggingface.co/bot-lab-21/DeepSeek-V4.1-Flash-EXL3-3.5bpw-Pollard), revision `f129e31a81e1337aa33e129e2d847fc7e37c8733` |
| Routing | Top-3 of 384 stored experts per main layer; applies during prefill, decode, and target verification |
| Expert execution | Cooperative EXL3 ABI3 |
| Speculation | Native DSpark draft, static block size 5 |
| Vision | Native vision tower and aligner retained |
| Engram | Native FP8 rows and scale bytes retained, repacked onto local NVMe |
| Context configuration | 524,288 per request; 4,199,936-token full pool; at most 8 running requests |
| Prefill | Chunk size 256; mixed chunking disabled |

The model keeps all 384 stored experts per main layer. It selects fewer experts for each token; this is a model behavior change. DSpark verifies against this K3 target, so speculative decoding does not restore native K6 behavior. Neither Engram pruning nor further Engram quantization is part of this recipe.

The full profile and hashes are recorded in [runtime-profile.json](results/runtime-profile.json) and [PROVENANCE.md](docs/PROVENANCE.md).

## Reconstructing the environment

Start with the packaged [configuration](config/cluster.env.example) and [launch/build scripts](scripts/). Configure each node's addresses, interfaces, model storage, and rank for your own cluster. Interface names are machine-specific; the original NVIDIA provisioning failure that prompted this work was an invalid interface selection, not a model issue.

On each Spark, use an installed Docker/NVIDIA container environment and CUDA build toolchain, with enough local NVMe space for both checkpoints, packed Engram rows, and container layers. From a fresh checkout, prepare the checkpoint downloader and build the ARM64 image:

```bash
git clone https://github.com/benkatzir/deepseek-v41-flash-three-sparks.git
cd deepseek-v41-flash-three-sparks
python3 scripts/extract_sources.py
sudo install -d -o "$(id -u)" -g "$(id -g)" /srv/deepseek-v41
python3 -m venv .venv
.venv/bin/pip install -r requirements-download.txt
.venv/bin/python scripts/download_models.py --data-dir /srv/deepseek-v41
sudo bash scripts/build.sh
cp config/cluster.env.example config/cluster.env
```

`extract_sources.py` verifies the packaged archive before extraction. The build script also extracts and checks the source manifest automatically. Substitute your own storage directory consistently if you do not use `/srv/deepseek-v41`.

Edit `config/cluster.env` for your cluster, then build its pinned subnet-aware NCCL on each Spark:

```bash
bash scripts/build_nccl.sh
```

Ensure `NCCL_DIR` in the configuration matches the resulting library directory. Pack the Engram rows on **each** node using that node's rank, then start workers before the head:

```bash
sudo bash scripts/launch.sh 0 pack   # on rank 0; use 1 and 2 on those nodes
sudo bash scripts/launch.sh 1 start  # on rank 1
sudo bash scripts/launch.sh 2 start  # on rank 2
sudo bash scripts/launch.sh 0 start  # on rank 0, after the workers
```

Run the commands on the indicated nodes; the launcher is local to each node. Use the script usage and configuration comments for additional prerequisites and settings.

The reported speed measurements also used a temporary **NVMe QoS 0** setting on every node. Normal launch does not enable it, so normal-launch speed may differ. See [the optional bounded lease and restoration procedure](docs/NVME_QOS.md). This portable helper has passed source checks but has not itself been exercised on hardware.

The [fresh ARM64 image build and component checks passed](results/public-build-verification.json). No fresh full-model GPU startup, quality, or throughput run was performed. The measured results belong to the historical runtime identified in the evidence, not automatically to any rebuild or changed configuration. Component correctness checks, startup profile checks, and workload checks must be rerun after rebuilding or changing kernels, weights, routing, or draft settings. See the build and provenance notes before treating a fresh deployment as reproduced.

## What this repository contributes

This repository preserves a specific implementation and its measured boundaries: native vision on a three-node deployment, working cooperative execution for the selected compressed experts, a paired 192-case pilot, and actual six-way 500k input loading with observable generation. The negative long-context results are included so capacity success is not mistaken for accurate retrieval or reliable service behavior.

It does not establish 40 tokens/s on every stream, eight simultaneous 500k contexts, or a general 87%/90% native accuracy guarantee. There is no measured claim of superiority over other models or public recipes.

## Attribution and evidence policy

This work builds on DeepSeek, the Pollard checkpoint, Mia's Spark work, SGLang, cuda-exl3, and ExLlamaV3. See [provenance and upstream revisions](docs/PROVENANCE.md) and the source notices for authorship and licensing. Model weights are downloaded separately under their own terms.

Public evidence is an allowlist export of numeric results, case identifiers, settings, and original artifact hashes. It omits credentials, private network identities, raw logs, model replies, benchmark text, and images. The omitted artifacts' hashes identify the original records; they do not make the omitted data independently inspectable.

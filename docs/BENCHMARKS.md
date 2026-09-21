# Benchmarks and interpretation

These are historical observations from September 18–20, 2026. They describe the selected Pollard EXL3 / routed-K3 / cooperative ABI3 / static DSpark γ5 runtime. They are not measurements of a newly built public package. Exact settings, per-stream counts, and original source-artifact SHA-256 digests are in [results](../results/README.md).

## Short image requests

Each request contained one native image and a short prompt. Requests were submitted concurrently in one wave per concurrency. Temperature was 0, thinking was off, and seed was 417. The six- and eight-stream output budgets were 8,192 tokens; the single-stream budget was 4,096. Native stop behavior was honored. These requests tested throughput and image-bearing execution, not answer correctness.

The common interval starts at the last stream's first visible output and ends at the first stream's last visible output. Each rate is that stream's incremental server cumulative generated-token count observed through SSE in this **same interval**, divided by its duration. TTFT and time after another stream finishes are excluded. This avoids reporting a stream's later, less-concurrent tail as its concurrent rate. Cumulative usage can include a control/EOS token not present in retokenized text; the evidence preserves the generated-token count basis.

| Concurrent requests | Prompt tokens each, including image | Shared interval | Minimum–maximum tokens/s per stream | Aggregate tokens/s | Completed | Length-capped outputs |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 611 | 31.5138 s | 52.7071 | 52.7071 | 1/1 | 0 |
| 6 | 612–660 | 61.4663 s | 30.0165–41.1770 | 208.1792 | 6/6 | 3 |
| 8 | 612–769 | 46.7869 s | 15.0469–25.2421 | 180.1786 | 8/8 | 1 |

Only the six-stream wave met the configured 60-second common-duration requirement. None of these waves established 40 tokens/s on **every** stream for a valid common duration. The single-stream figure should not be extrapolated to six or eight users.

Per-stream values for the concurrent waves:

| Stream index | C6 common tokens | C6 tokens/s | C6 TTFT, s | C8 common tokens | C8 tokens/s | C8 TTFT, s |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | 2,103 | 34.2139 | 3.3831 | 1,074 | 22.9551 | 6.6352 |
| 1 | 1,909 | 31.0577 | 4.1680 | 1,125 | 24.0452 | 2.2559 |
| 2 | 2,531 | 41.1770 | 2.6229 | 1,127 | 24.0879 | 5.9592 |
| 3 | 1,845 | 30.0165 | 4.9440 | 1,010 | 21.5872 | 3.6539 |
| 4 | 2,463 | 40.0707 | 5.4136 | 1,051 | 22.4635 | 4.3083 |
| 5 | 1,945 | 31.6434 | 1.8982 | 1,181 | 25.2421 | 2.9557 |
| 6 | — | — | — | 1,158 | 24.7505 | 5.2577 |
| 7 | — | — | — | 704 | 15.0469 | 7.3781 |

Image token counts were 187–322 depending on the image. Cached input tokens were zero. Joined scheduler snapshots confirmed logical request residency at the head scheduler for the concurrent waves. They did not measure every device's physical KV pool continuously. There was no observed competing request in the sampled checks, but these observations cannot exclude all possible external traffic between samples.

Source: [short-vision.json](../results/short-vision.json).

## Fixed-budget, paired 192-case quality pilot

The candidate and the local native baseline answered the same selected public cases with the same fixed generation budgets. The baseline used the published native MXFP4 routed-expert weights and native K6 routing on the adapted three-Spark stack. It was not a BF16 reference and was not an unmodified publisher deployment.

| Selected subset | Cases | Native correct | K3 candidate correct | Both correct | Native-only correct | Candidate-only correct |
|---|---:|---:|---:|---:|---:|---:|
| MMLU-Pro text | 64 | 53 | 53 | 52 | 1 | 1 |
| MMMU vision | 64 | 44 | 44 | 42 | 2 | 2 |
| HumanEval coding | 64 | 60 | 60 | 58 | 2 | 2 |
| Total | 192 | **157** | **157** | **152** | **5** | **5** |

Equal aggregate scores conceal changed answers: five baseline successes were lost and five baseline failures were corrected. This is useful evidence on the selected pilot; it is not universal equivalence or proof of retaining 87% or 90% of native capability.

MMLU-Pro used stratification across 14 subjects, with at least four selected cases per subject. MMMU used 30 subjects, with at least two each. HumanEval used 64 tasks selected by seeded hashes. These are **subsets**, not full benchmark scores. There was no contamination control.

Both runs used thinking on, reasoning effort 75, temperature 0, top-p 1, and concurrency 6. Text and vision had 8,192 output tokens and seed 417. Coding had 4,096 output tokens and seed 20260918 under the complete-module protocol. The coding results represent one generated completion per task checked against its task tests.

Transport/technical errors were zero. Missing or unparsed final answers were scored as incorrect, including budget-limited responses. The native text/vision runs had 4/12 unparsed and length-limited outputs; the candidate had 4/13. These are fixed-budget outcomes, not unrestricted reasoning-capability measurements. Exploratory bootstrap diagnostics from the internal analysis are not presented as a general confidence guarantee.

No separate matched EXL3-K6 full-192 control was completed. Therefore this comparison does not isolate the effects of expert quantization from reduced routing or other adaptations. The short quality runs and long-context runs also used different thinking settings.

Source: [quality-pilot-192.json](../results/quality-pilot-192.json). Dataset versions and selection identifiers are in [provenance](PROVENANCE.md).

## Six independent 500k contexts with images

Six cold requests were submitted together, each containing an independently constructed synthetic archive, one image, exact lookup/evidence-chain questions, and an engineering-analysis task. Native usage reported **500,741–500,802 prompt tokens per request**. Cached tokens and retractions were zero for every request. All six requests completed; one reached the 8,192-token generation cap.

The measured time until all six had fully populated logical contexts was about **81.1 minutes**. Earlier output from an individual stream did not mean all six were ready: a first response began around 14 minutes, then progress could stall while remaining prefill proceeded.

The first contiguous sampled interval with all six live, fully prefilled, and producing output lasted **8.41243–8.41257 seconds**. It contained 15 eligible snapshots, with a maximum bounded gap of 0.66666 seconds. Rates below use accepted scheduler output counts divided by the conservative upper duration. Rejected draft tokens are excluded. These are **generation rates, not proof of client delivery speed**.

| Request index | Prompt tokens | Image tokens | Final completion tokens | Stop reason | Accepted tokens in common interval | Conservative generated tokens/s |
|---:|---:|---:|---:|---|---:|---:|
| 0 | 500,751 | 200 | 8,192 | Length cap | 204 | 24.2494 |
| 1 | 500,802 | 200 | 2,986 | Stop | 173 | 20.5645 |
| 2 | 500,783 | 200 | 218 | Stop | 194 | 23.0607 |
| 3 | 500,766 | 236 | 216 | Stop | 198 | 23.5362 |
| 4 | 500,741 | 197 | 389 | Stop | 198 | 23.5362 |
| 5 | 500,789 | 187 | 2,910 | Stop | 158 | 18.7814 |

The rate is a simultaneous, populated-context observation; its 8.41-second duration is too short to qualify sustained performance. The sampled head pool reached 3,005,952 used token slots (71.57% of its configured pool). This is logical scheduler telemetry, not a separate physical-residency measurement on each GPU. Pre/post runtime checks covered all three ranks.

### Answer quality in the same six requests

The frozen strict scorer found:

| Check | Correct |
|---|---:|
| Exact archive lookups | **0/24** |
| Evidence-chain terminal answers | **0/6** |
| Image answer fields | **1/6** |

Three replies did not parse under the required format. An additional read-only content review, without rerunning or changing the scores, recovered five correct lookup values hidden by wrappers. It still found three wrong lookup values, sixteen missing ones, and no correct chain terminal. One image answer was internally contradictory; another selected source question's gold label was flagged as ambiguous. Neither was rescored.

The failures therefore cannot be explained by formatting alone. This trial demonstrates capacity and execution, while showing that the tested long-context task was not answered reliably. There was no matched native 500k control, so it cannot determine native-relative accuracy or isolate the cause of the failure.

Source: [long-context-500k-c6.json](../results/long-context-500k-c6.json).

## Eight independent 500k contexts

The eight-way long-context trial was canceled by the user before qualification. It did not establish success, speed, or a capacity failure. The completed eight-way **short-prompt** run above must not be described as eight simultaneous 500k contexts.

## Repetition and reproduction

Each throughput result here is one measured wave, not a distribution across repeated deployments, hardware sets, or days. The source package preserves the selected profile, but its reconstructed build has not yet repeated these benchmarks. Original private records are retained by the author; the public numeric extracts and hashes permit arithmetic checks and source identification, not independent inspection of every omitted raw record.

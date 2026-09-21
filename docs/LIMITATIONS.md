# Limitations and unresolved work

The selected recipe runs, accepts native images, completed a paired short-context quality pilot, and completed six independent requests with more than 500k input tokens each. Its long-context answers were unreliable. These are different findings and both matter.

## Model behavior is changed

The native target routes six experts per token. This candidate routes three during prefill, decode, and target verification, with all 384 experts still stored in each main layer. It also replaces the main routed weights with Pollard EXL3 3.5 bpw weights. The native vision tower, aligner, router parameters, shared experts, DSpark draft, attention, and Engram precision remain intact, but that does not make the whole model native-equivalent.

DSpark verifies its draft against the modified K3 target. Its acceptance mechanism is not a guarantee of matching native K6 outputs. A separate matched EXL3-K6 full-192 quality control was not completed, so the quantization and reduced-routing effects cannot be separated by the reported pilot.

## Short quality evidence is limited

The candidate and adapted native baseline each scored 157/192 across selected public text, vision, and coding cases. Five cases changed from correct to wrong, and five changed from wrong to correct. The baseline uses the publisher's native MXFP4 checkpoint, not BF16. It also needs local three-Spark runtime adaptations; bitwise equivalence to an unmodified publisher deployment was not established.

These results are from 64-case subsets per domain with fixed output budgets, public task exposure, and no contamination control. Length limits and missing final answers are part of the measured outcomes. A favorable aggregate pilot does not establish broad 87% or 90% accuracy retention, robustness across prompts, or long-context reasoning performance.

## Long-context answer quality failed the tested checks

All six independent 500k-plus-image requests completed, but strict scoring found 0/24 exact archive lookups, 0/6 evidence-chain terminals, and 1/6 image answer fields. Three responses had format failures. Supplemental inspection found only five correct lookup values hidden by wrappers, with other values wrong or absent. The outcome is therefore not only a parser problem.

The trial used a synthetic combined task and thinking off, unlike the short quality pilot. There was no matched native 500k control. The evidence cannot identify whether the failures chiefly reflect task construction, inference adaptations, reduced routing, compression, budget, or native model behavior. It cannot supply a native-relative long-context accuracy percentage. One source image question's gold was flagged as ambiguous without rescoring.

## Latency and sustained throughput remain constraints

Cold loading of all six 500k contexts took about 81.1 minutes. The interval in which all six were simultaneously fully prefilled and generating was only 8.41 seconds. The 18.8–24.25 tokens/s range is conservative scheduler generation throughput in that short interval; it is not a measured client delivery guarantee, whole-request average, or 60-second sustained rate.

The six-way short-prompt image run did have 61.47 seconds of common output, at 30.0–41.2 tokens/s per stream. The eight-way short run had only 46.79 seconds, at 15.0–25.2. Neither demonstrates 40 tokens/s on every stream for a valid common duration. Each is one wave, not a repeated-run latency or throughput distribution.

## Eight 500k contexts remain unqualified

The eight-way long-context run was canceled before qualification. No eight-way capacity or speed result was obtained, and no capacity failure was established. A configured context limit or a pool-size calculation is not a substitute for a completed workload.

## Observability has a defined scope

Request usage, accepted-output counts, head-scheduler residency snapshots, and all-rank pre/post runtime checks support the reported execution observations. The head telemetry describes logical requests and token pools. It does not independently prove physical residency on all three GPUs at every instant, nor exclude unrelated traffic between periodic observations.

NVMe QoS was set to zero for the reported candidate measurements. The serving profile, source hashes, and draft block size must be matched when comparing results. Short and long measurements use different timing/count channels and should not be combined into one performance figure.

## Public reconstruction and raw-evidence scope

The public ARM64 image build and component checks passed. A new GPU startup, full-model quality run, and throughput run of that rebuilt image have not been performed. Passing build or component gates does not validate full-model accuracy or reproduce the historical numbers.

The public results deliberately contain numeric summaries, case IDs, settings, and hashes, rather than private machine records, raw generations, benchmark questions, or images. Those omissions protect operational privacy and avoid unnecessary redistribution of dataset content, but limit independent auditability. Original artifact hashes identify records; they do not prove omitted contents to a reader who lacks those records.

The most useful next checks would be a fresh-build GPU smoke test and matched long-context correctness comparisons before tuning throughput further. These are outstanding checks, not promised results.

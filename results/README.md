# Sanitized measured evidence

These files preserve numerical results from the selected K3 / static DSpark γ5 runtime. They contain no model weights, benchmark text, raw model replies, dataset images, credentials, private addresses, or machine identities.

| File | Contents |
|---|---|
| [runtime-profile.json](runtime-profile.json) | Public checkpoint revisions, routing definition, parallelism, and measured serving settings |
| [short-vision.json](short-vision.json) | One short image-bearing wave each at concurrency 1, 6, and 8; common intervals and per-stream token counts |
| [quality-pilot-192.json](quality-pilot-192.json) | Paired selected text/vision/coding scores, case IDs, domain diagnostics, sampling rules, and budgets |
| [long-context-500k-c6.json](long-context-500k-c6.json) | Actual six-way 500k-plus-image completion, short common-generation interval, strict answer failures, and supplemental diagnostics |
| [SOURCE_ARTIFACTS.json](SOURCE_ARTIFACTS.json) | Original private artifact digests under neutral logical roles |
| [public-build-verification.json](public-build-verification.json) | Fresh ARM64 public image build and component-check receipt; explicitly excludes new full-model GPU measurements |

For short runs, divide each `qualified_overlap_tokens` by its run's `common_overlap.seconds` to recover the per-stream rate; sum those rates for aggregate throughput. For the long run, divide `accepted_generated_tokens` by `common_interval.duration_upper_seconds` to recover the conservative scheduler generation rate. These two measurements use different observation channels and must remain labeled separately.

The quality pilot totals are the sum of three 64-case domains. Both runs scored 157/192, with five losses and five gains. Long-context strict results remain 0/24 lookups, 0/6 chain terminals, and 1/6 image fields; the supplemental content inspection did not change those scores.

The eight-way 500k run was canceled before qualification. It has no public capacity/speed result and is not the completed short-prompt eight-way run.

The original logs and generations are not included, so these are arithmetic-auditable extracts, not a complete independently replayable raw evaluation release. See [benchmark methods](../docs/BENCHMARKS.md), [limitations](../docs/LIMITATIONS.md), and [provenance](../docs/PROVENANCE.md).

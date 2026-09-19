# L12 Curated Evidence

- Learning unit: **L12 — External DevOps Delivery Continuity Extension (Optional)**
- Classification: **Three clean local fixed-condition matrices; not production RTO/RPO evidence**
- Source branch: `feat/l12-delivery-continuity`
- Harness commit: `7f0e9fc886329b6941536339648c6a9d300474a2` (`git_dirty=false`)
- Raw source: `results/delivery-continuity/20260919T114620Z-2042/`

This directory contains the human-reviewable JSON, workflow/runner logs, and raw `summary.md` from
the named result only. All 141 selected files were copied without redaction or measured-value edits
and verified with `cmp` against their raw counterpart. Package binaries and image-context binaries
are intentionally not committed; their SHA256 identities appear in the copied manifests. No database
dump, temporary credential, token value, environment dump, private absolute path, or original package
binary is curated.

## Fixed prepared inputs and runtime identity

| Item | Actual value |
| --- | --- |
| Prepared source C | `0217cb98ce49547a3a929b909204b7278b95692c` |
| Prepared action SHA | `e735cac7b96b71319dca899e18e06191c286987d` |
| Forgejo Server | `codeberg.org/forgejo/forgejo:15.0.9` (`sha256:91a5310c86934339e16bd06b6078aada836e3d8935b2d70f6598108cbfaed5d1`) |
| Forgejo Runner | `code.forgejo.org/forgejo/runner:13.1.0` (`sha256:c4af85fd9f0dd03788676a534781a87c71aa2c6a37737143e017eb94d4312952`) |
| Go image/toolchain | `golang:1.26.7` (`sha256:e30143be198ab04cf7ba25fba83ab3a692ca584c994aad0bf131fa0eb32dd8c1`); `go1.26.7 linux/amd64` |
| Prepared vendor archive SHA256 | `b79d50de1ba83429041b6256b1a9b335cef4537b04dd809870ccd3bdbd9325a8` |
| S3 artifact SHA256 (all repetitions) | `451ddd097041f655e817a2b5ae3ebb8900c4592c490c98a616882a3f220f896f` |

The [per-repetition version record](repetition-1/versions.json) and
[prepared-input manifest](repetition-1/prepared-inputs.json) are raw copies. Source/action C is a
prepared read-only snapshot, not a claim of RPO=0. Prepare was run separately before this matrix;
verify consumes inputs already present and does not call prepare.

## Scenario contracts — all three repetitions

| Scenario | Workflow observation | Delivery boundary | Contract / witness |
| --- | --- | --- | --- |
| S0 `primary-control` | success | Primary source + Primary action build path works | PASS; existing witness healthy; no new candidate required |
| S1 `source-unavailable` | expected failure | Continuity action resolves, Primary source acquisition fails after Primary stop | PASS; no new deployment; witness healthy |
| S2 `action-unavailable` | expected failure | Primary action acquisition fails; action resolution occurs before source clone | PASS; no new deployment; witness healthy |
| S3 `prepared-continuity` | success | New post-outage job uses Continuity source/action, vendor package and offline test/build; package artifact is hash-checked then deployed | PASS; candidate started and health/ready/token probes succeeded |
| N1 `unprepared-revision` | expected failure | Synthetic Primary-only revision is absent from Continuity; no fallback to C | PASS; no deployment; witness healthy |
| N2 `tampered-artifact` | CD rejection | Downloaded copy SHA256 differs from trusted manifest | PASS; no activation; witness healthy |
| S4 `primary-restored` | success | Restored Primary source + action path works again | PASS; existing witness healthy; no new candidate required |

`comparison.json` has `all_contracts_passed=true`. Each repetition's scenario detail is available in
its [first](repetition-1/summary.json), [second](repetition-2/summary.json), and
[third](repetition-3/summary.json) raw summary, including workflow status and assertion contract.
The intended workflow failures are not recorded as an overall failure: their contracts require the
specific dependency boundary, no candidate deployment, and the witness health result.

## Provenance, isolation, and cleanup

For S3, each copied artifact manifest connects source C, the prepared vendor SHA256, Forgejo run id,
and binary SHA256. The bounded CD record then connects its downloaded SHA256 to the candidate image,
container and functional probes; see
[artifact manifest](repetition-1/prepared-continuity/cd/artifact-manifest.json),
[deployment record](repetition-1/prepared-continuity/deployment.json), and
[runtime probe](repetition-1/prepared-continuity/cd/runtime-probe.json). N2 preserves the distinct
tampered SHA256 and its rejected deployment record instead of modifying the original registry artifact.

Every matrix records `docker_network_internal=true`, local Forgejo reachability and
`github_https_blocked=true`; see [network isolation](repetition-1/network-isolation.json). This proves
the disposable runner's selected-network boundary, not server egress, production network isolation,
or a host firewall/DNS control. Each copied [cleanup record](repetition-1/cleanup.json) reports zero
owned containers, networks and volumes, with temporary credentials removed. Final `make l12-clean`
removes the exact L12 runner/candidate images and temporary runtime directory while preserving raw
results.

## Limits and conclusion

This evidence supports only this local, fixed revision/action/vendor/toolchain/Compose condition:
while the Primary fixture was down, the S3 continuity path—with prepared source, action, toolchain,
vendored dependencies, independent job-control, package and bounded CD inputs together—could build,
verify, and deploy the prepared revision. S1/S2 separately show delivery failure when source or action
dependency remained on Primary; they do not independently prove the necessity of every other S3 input.
Unavailable revisions or altered artifacts were rejected rather than silently substituted.

It does **not** establish GitHub customer architecture, GitHub endorsement of Forgejo, production
resilience, universal dependency coverage, HA source control, automatic mirroring/failback, production
RTO/RPO, or SLSA/signing equivalence. The host-executor-in-disposable-container design is a constrained
lab boundary, not a multi-tenant runner security architecture.

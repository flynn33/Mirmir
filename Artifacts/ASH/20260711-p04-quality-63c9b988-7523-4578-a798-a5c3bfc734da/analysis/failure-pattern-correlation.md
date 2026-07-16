# ASH Failure-Pattern Correlation

## Scope and conclusion

This review correlates failures found while making the P04 benchmark trustworthy. It does not evaluate whether the current ASH reconstruction improves visual quality. The 24-case production run is a pre-change control that proves the measurement path can execute, preserve, and verify evidence without opening the holdout.

The failures cluster at representation and lifecycle boundaries. A local check could pass while the end-to-end claim remained under-bound. The improvement area is therefore the contract between every producer and consumer of evidence.

## Correlated clusters

| Cluster | Failure pattern | Evidence that exposed it | Implemented control | Required downstream discipline |
|---|---|---|---|---|
| Provenance binding | A top-level file hash can remain valid while an unlisted helper, schema, tool, source asset, decode record, crop, or display transform changes. | The harness now validates a recursive 53-file implementation manifest, exact corpus media hashes, selected decode-record hashes, centered crop geometry, and source evidence manifests. | Recursive implementation manifest; exact source-media and active-plane binding; fail-closed geometry checks. | Every P05/P06 candidate, operator table, and configuration input must be recursively bound before its result is accepted. |
| Stateful writer contamination | Codec output can depend on neighboring frames, processing order, or a reused encoder session, confounding a one-case metric comparison. | `test_isolated_production_writer_is_order_and_neighbor_invariant` compares solo, neighbor-present, and reordered execution. The production run records 24 separate HEVC processes plus two route-level H.264 processes. | One candidate case per HEVC process and container; explicit `neighbor_frames_present: false`; decoded-payload replay. | Keep metric cases isolated. Treat any change to process/session scope as a benchmark-contract change that invalidates dependent evidence. |
| Representation mismatch | A padded decoder-buffer hash is not the same object as the active raster bytes consumed by metrics. Nominal video-range metadata also does not prove every decoded value lies inside the nominal interval. | Six sample records retain both hashes. Two samples record real luma excursions: `dev-nasa-b-stand-aerial-4k` has 110 values below and 36 above nominal; `dev-nasa-oco3-plants-4k` has 591 above nominal. | Independent active Y-plus-CbCr hash, per-component excursion counts, canonical display geometry, and explicit nominal-range clamping before normalization. | P05 metrics and operators must consume the canonical active-plane representation, carry color/range metadata, and never substitute storage-layout hashes for sample identity. |
| Publication identity | Making a pathname read-only or user-immutable does not protect it from a writable descriptor that was opened against the same inode before finalization. | The focused finalization test holds a writable descriptor across publication and attempts a later write. | Every artifact pathname is atomically replaced with a distinct owner-read-only inode, marked user-immutable, then hashed. The held descriptor reaches only the detached old inode. Direct writes and additions fail. | Continue detached-inode publication for all immutable evidence. State the cooperating-process boundary; do not overstate protection against an owner or administrator deliberately clearing flags. |
| Syntactic integrity without semantic integrity | Individually schema-valid, correctly hashed files can still contradict one another or omit required rows. | False-pass schema fixtures and semantic-snapshot mutation tests are rejected. The final verifier reopens source locks, payloads, reports, decoded frames, results, checkpoint, bootstrap record, and manifest. | Exact expected path set, manifest self-hash, cross-file semantic replay, 24 engine rows, 24 container rows, and 26 writer replays. | Later gates must verify cross-artifact meaning, not only schemas and SHA-256 values. Required case counts and ordering must be explicit. |

## Cross-cluster interpretation

The clusters share one causal shape: an assertion was made about a logical object while the evidence bound only a convenient representation of that object. Examples include binding a top-level manifest instead of its transitive implementation, a padded allocation instead of active pixels, a filename instead of the inode published at that filename, and a valid document instead of the complete cross-file benchmark state.

This pattern predicts the highest-risk areas in P05 and P06:

1. Candidate adapters and operator descriptors can appear deterministic while reading unbound configuration or choosing a route from ambient state.
2. Metrics can appear repeatable while comparing different crop, range, chroma-siting, or decoded-container semantics.
3. Paired comparisons can appear valid while writer-session history or asset/frame weighting changes the experimental unit.
4. A sealed configuration can appear immutable while a transitive implementation file or semantic dependency remains outside the lock.

## Improvement priorities

1. Bind the full dependency closure of every quality claim, including source, configuration, route, writer settings, metric policy, and executable implementation.
2. Isolate all stateful evidence producers at the declared experimental-unit boundary.
3. Give storage bytes, active sample bytes, normalized samples, and decoded container samples distinct identities and explicit conversion contracts.
4. Reject ambiguous aperture, orientation, aspect ratio, range, and chroma-siting metadata before metrics run.
5. Preserve failures under unique names; recompute resumptions from bound inputs rather than trusting mutable checkpoints.
6. Publish evidence through detached immutable inodes and replay its semantics after reopening from the final path.

## Gate implication

G04 passes because the benchmark and metric harness meets its integrity contract. ASH quality remains unproven at this checkpoint. The first causal quality claims belong to G05/G07 after the spatial mapping, operator bank, selector, configuration lock, and one-time holdout process are complete.

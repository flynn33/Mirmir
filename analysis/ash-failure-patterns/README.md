# P06 ASH failure-pattern analysis

This directory contains a bounded technical diagnostic of the open-development P06 calibration ledger. It does not read media, validation, or holdout payloads. Every reported attempt ends at an explicit sequence and record hash from a canonical, continuous, self-hashed ledger prefix.

The analysis validates each referenced development evaluation by size and SHA-256, recomputes its summary and feasibility predicates with the repository evaluator, and verifies the recorded candidate, summary, canonical-failure, and search-rank bindings. It also recomputes the internal run input-bundle hash, requires the full plan-derived metadata record set and an unopened metadata-only holdout proof, matches every bound repository input to current bytes, matches the consumed calibration plan and tolerance bytes to their source snapshots, and verifies that imported evaluator sources remain byte-identical across loading. The SQL file then produces the bounded report datasets from normalized in-memory rows.

Run from the repository root with a new output path:

```sh
PYTHONPATH=. python3 analysis/ash-failure-patterns/analyze_p06_failures.py \
  --repository-root . \
  --bound-repository-root <worktree-matching-the-live-run-input-bundle> \
  --partial-root <p06-partial-root> \
  --cutoff-sequence <last-included-sequence> \
  --output analysis/ash-failure-patterns/evidence/<snapshot-name>.json
```

The generated report is a snapshot diagnostic, not a G06 result, release claim, or substitute for terminal preservation and release validation. The attempt ledger does not separately anchor the input-bundle hash, so bundle verification is an internal consistency proof rather than an independent attestation.

Build the canonical report artifact from the final checked snapshot:

```sh
python3 analysis/ash-failure-patterns/build_p06_failure_report.py \
  --analysis analysis/ash-failure-patterns/evidence/p06-current-source-snapshot-final.json \
  --output analysis/ash-failure-patterns/artifact.json
```

`report.html` is the portable rendered result. `report-delivery-receipt.json` records artifact validation, packaging, browser verification, source-dialog interaction, and the verified responsive viewports.

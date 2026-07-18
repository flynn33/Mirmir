# Roadmap Alignment Governance

The `Roadmap alignment` GitHub check keeps the repository's published product
direction synchronized with the canonical roadmap. It runs for every pull request
to `main`, every push to `main`, merge-queue validation, manual dispatch, and a
weekly scheduled audit. The check has read-only repository permission and uses
only Python's standard library.

## What the check enforces

The verifier reads `.github/roadmap-alignment-policy.json` and rejects drift in:

- the canonical roadmap Markdown and JSON paths, SHA-256 digests, version, and date;
- roadmap schema, phase IDs and ordering, phase dependency references, Apple-method
  IDs, and authorization values;
- the phase-status vocabulary and prerequisite rule: a phase marked `next`,
  `in_progress`, `evidence_ready`, or `passed` requires every declared dependency
  to be `passed`;
- the complete canonical Markdown embedded between the stable README markers;
- the generated `Roadmap Progress` indicators in the README;
- required roadmap, evidence-status, and historical-status language in the aligned
  repository documentation;
- the current Forsetti dependency boundary and pinned legacy dependency identity;
- tracked Forsetti repository, framework, or vendored paths forbidden by policy;
- the GitHub repository description and topics recorded as exact policy; and
- workflow triggers or commands that could open legacy P06/P07/P08 or holdout
  execution, create a tag or release, or use `pull_request_target`.

Unit tests run before the repository check. The stable required-check name is
`Roadmap alignment`. The weekly run repeats the repository and metadata checks so
description or topic changes made outside a pull request become visible as drift.

## Updating progress

Change phase statuses only in the canonical roadmap JSON after the corresponding
roadmap decision and evidence have been accepted. Update the canonical JSON digest
and affected contract fields in the alignment policy in the same pull request.
Then regenerate the clearly labeled README progress section and verify the
repository:

```sh
python3 Scripts/roadmap_alignment.py --write-progress
python3 -m unittest Scripts/tests/test_roadmap_alignment.py
python3 Scripts/roadmap_alignment.py --check
GITHUB_TOKEN="..." python3 Scripts/roadmap_alignment.py --check-github-metadata
```

`--write-progress` changes only the content between the README progress markers;
it does not change roadmap policy, phase authorization, or canonical evidence.
The metadata command compares GitHub's current description and topic set with the
exact values in policy; it requires a token with read access to repository
metadata and does not modify GitHub.

## Current Forsetti legacy mode

The preserved source still references the exact Forsetti package URL and revision
recorded in the alignment policy. This is a temporary legacy allowance, not the
target dependency model. Roadmap R00 must remove the Forsetti repository as a
build and runtime dependency. The repository remains reference-only: approved
app-owned outputs adapted from its templates may be committed, but the Forsetti
repository, packaged framework, or repository dependency must not be included or
vendored in Mirmir.

Enforcement follows R00's canonical status:

- `planned`, `next`, or `blocked`: both tracked project declarations must retain
  the exact approved legacy URL, revision, and three products;
- `in_progress` or `evidence_ready`: the dependency must be either exact and
  unchanged or completely removed; partial or unpinned migration fails; and
- `passed`: repository coordinates, package products, and package imports must be
  absent while app-owned adaptations and manifests remain permitted.

## Non-release boundaries

This check does not run legacy P06/P07/P08 scripts, open holdout data, build the
application, execute product tests, create tags, or publish releases. Passing it
does not authorize production Auto mode, G08, a product-quality claim, a
market-position claim, or a release. It establishes repository alignment only.

## Amending the policy

A policy amendment requires an explicit roadmap decision and a reviewed pull
request. Update the canonical roadmap sources first, then update the policy's
digests and affected contract fields, regenerate README progress, update aligned
documentation, and add or revise verifier tests for the new rule. The pull request
must identify affected phase IDs, authorization changes, accepted evidence, and
the Forsetti-boundary impact.

Policy changes are visible in the same pull request as the material they govern;
they do not provide independent authorization. Reviewers must compare the change
with the accepted roadmap decision and evidence before merging it.

## Limitations

The verifier checks committed repository state. It does not determine whether
evidence is scientifically sufficient, whether a phase's implementation works,
or whether a PR description is truthful. PR-template metadata is reviewer guidance
in this initial slice and is not parsed by the workflow. Branch-protection rules
must separately require the `Roadmap alignment` check before merging to `main`.

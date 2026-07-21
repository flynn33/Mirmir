# Roadmap Alignment Governance

The `Roadmap alignment` GitHub check keeps the repository's published product
direction synchronized with the canonical roadmap. It runs for every pull request
to `main`, every push to `main`, merge-queue validation, and manual dispatch. The
required check has read-only repository permission, uses only Python's standard
library, and performs no live network requests after checkout. A separate
informational `Roadmap metadata audit` runs weekly or by manual dispatch.

## What the check enforces

The verifier reads `.github/roadmap-alignment-policy.json` and rejects drift in:

- the canonical roadmap Markdown and JSON paths, SHA-256 digests, version, and date;
- roadmap schema, phase IDs and ordering, phase dependency references, Apple-method
  IDs, and authorization values;
- the phase-status vocabulary and prerequisite rule: a phase marked `next`,
  `in_progress`, `evidence_ready`, or `passed` requires every declared dependency
  to be `passed`, except the exact policy-scoped R03 and R04 `in_progress` local
  continuations from their recorded unpublished predecessor closures;
- the complete canonical Markdown embedded between the stable README markers;
- the generated `Roadmap Progress` indicators in the README;
- required roadmap, evidence-status, and historical-status language in the aligned
  repository documentation;
- the current Forsetti dependency boundary across tracked package manifests,
  generated project declarations, active paths, and decorated Swift imports;
- the schema-closed, exact-commit R00 C01-C11 source inventory, its generated
  Markdown, its fail-closed evidence boundaries, and candidate drift across every
  accepted source path;
- status-sensitive phase-start contracts: R02, R03, and R04 `in_progress`,
  `evidence_ready`, and `passed` states require regular, non-symlink
  preregistration and fixture-catalog files, whose dedicated validators preserve
  exact unpublished predecessor truth and the operator-observation boundary;
- tracked Forsetti repository, framework, or vendored paths forbidden by policy;
- the GitHub repository description and topics recorded as exact policy; and
- workflow triggers or commands that could open legacy P06/P07/P08 or holdout
  execution, create a tag or release, or use `pull_request_target`.

Unit tests run before the repository and inventory checks. The stable required-check name is
`Roadmap alignment`. The separate weekly metadata audit
uses three bounded attempts so description or topic changes made outside a pull
request become visible without making the required check network-dependent.

## Updating progress

Change phase statuses only in the canonical roadmap JSON after the corresponding
roadmap decision and evidence have been accepted. Two narrow exceptions apply
when direct operator instruction authorizes local implementation from an exact,
recorded phase-specific local closure:

- R03 may be `in_progress` while R02 remains `in_progress` only when its regular
  preregistration exactly binds R02 closure commit
  `673b0582c0b4d6b4ad81de6b01ba9e3f35f4e3d4` and tree
  `a5e95d810abacbdb872ddc6e94125103831e6fba` as
  `local_unpublished_closure`.
- R04 may be `in_progress` while R03 remains `in_progress` only when its regular
  preregistration exactly binds R03 closure commit
  `947983a8414c60e4f5f4246e6cb658792fc7c357` and tree
  `d1a89e5b9edf8d42b1da9ba06a3b6a0c139f08f3`. The bound R03 result is
  fail-closed and `blocked`, with closure state
  `local_unpublished_blocked_closure` and `predecessor_result: blocked`; this
  exception does not interpret it as success.

Both preregistrations record `accepted_merge_commit: null`,
`acceptance_state: not_claimed`, and
`continuation_scope: local_implementation_only`; each closure must be an ancestor
of `HEAD`. The exceptions never apply to `next`, `evidence_ready`, or `passed`.
They do not authorize publication, phase closure, acceptance, production
enablement, or release. Update the canonical JSON digest and affected contract
fields in the alignment policy in the same change.
Then regenerate the clearly labeled README progress section and verify the
repository:

```sh
python3 Scripts/roadmap_alignment.py --write-readme
python3 Scripts/r00_inventory.py --write-markdown
python3 -m unittest Scripts/tests/test_roadmap_alignment.py Scripts/tests/test_r00_inventory.py Scripts/tests/test_r01_observation_waiver.py Scripts/tests/test_r02_contracts.py Scripts/tests/test_r03_contracts.py Scripts/tests/test_r04_contracts.py
python3 Scripts/roadmap_alignment.py --check
python3 Scripts/r00_inventory.py --check
python3 Scripts/r02_contracts.py --check-preregistration
python3 Scripts/r02_contracts.py --check-fixtures
test ! -f docs/roadmaps/evidence/r02/records/conformance.json || python3 Scripts/r02_contracts.py --check-conformance
python3 Scripts/r03_contracts.py --check-preregistration
python3 Scripts/r03_contracts.py --check-fixtures
test ! -f docs/roadmaps/evidence/r03/records/baseline-conformance.json || python3 Scripts/r03_contracts.py --check-conformance
python3 Scripts/r04_contracts.py --check-preregistration
python3 Scripts/r04_contracts.py --check-fixtures
test ! -f docs/roadmaps/evidence/r04/records/integration-conformance.json || python3 Scripts/r04_contracts.py --check-conformance
GITHUB_TOKEN="..." python3 Scripts/roadmap_alignment.py --check-github-metadata --metadata-attempts 3
```

`--write-readme` synchronizes only the canonical-roadmap and progress blocks;
it does not change roadmap policy, phase authorization, or canonical evidence.
`r00_inventory.py --write-markdown` regenerates only the human-readable summary
from the canonical inventory JSON.
The metadata command compares GitHub's current description and topic set with the
exact values in policy; it requires a token with read access to repository
metadata and does not modify GitHub.

## Current external-runtime boundary

Established at `R00: evidence_ready` and retained at `R00: passed`, the app-owned
runtime has replaced the former package boundary. The Forsetti repository is
reference-only: no repository coordinate,
package product, Swift import, framework, submodule, vendored source, generated
project reference, or active source/resource path is permitted. Normal builds
therefore require no network package resolution.

The verifier keeps status-sensitive rules so inconsistent or partially removed
states fail deterministically:

- `planned`, `next`, or `blocked`: both tracked project declarations must retain
  the exact approved legacy URL, revision, and three products;
- `in_progress`: the dependency must be either exact and unchanged or completely
  removed; partial or unpinned migration fails; and
- `evidence_ready` or `passed`: repository coordinates, package products,
  package imports, and Forsetti-named active source/resource paths must be absent.

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

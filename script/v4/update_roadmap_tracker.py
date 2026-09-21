#!/usr/bin/env python3
"""Render the GitHub roadmap tracker from the canonical v4 status documents."""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import subprocess
import sys
import textwrap
from dataclasses import dataclass
from pathlib import Path


MILESTONE_PATTERN = re.compile(r"^### (M[0-7])\s+[—-]\s+(.+)$", re.MULTILINE)
STATUS_PATTERN = re.compile(r"^Status:\s*(.+)$", re.MULTILINE)
EXPECTED_MILESTONES = tuple(f"M{index}" for index in range(8))
EXPECTED_CANDIDATES = (
    "candidate_v4",
    "uniform_priors",
    "randomized_state_message",
    "temporal_hysteresis_off",
    "motion_history_off",
)


class TrackerError(RuntimeError):
    """Raised when a canonical roadmap input is incomplete or contradictory."""


@dataclass(frozen=True)
class Milestone:
    identifier: str
    title: str
    status: str
    state: str


@dataclass(frozen=True)
class TrackerState:
    version: str
    build: str
    verified_date: str
    simulation_source_commit: str | None
    selected_candidate: str
    milestones: tuple[Milestone, ...]
    open_steps: tuple[str, ...]
    m7_satisfied: bool
    quality_gain_percent: float
    processing_reduction_percent: float
    candidate_count: int


def read_required(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise TrackerError(f"cannot read {path}: {error}") from error


def classify_status(identifier: str, status: str) -> str:
    normalized = status.casefold()
    implementation_landed = normalized.startswith("landed ") or normalized.startswith(
        "implementation landed "
    )
    qualification_open = any(word in normalized for word in ("open", "remains", "blocker"))

    if identifier == "M7":
        if qualification_open:
            return "open"
        if normalized.startswith(("complete", "qualified", "passed")):
            return "complete"
    elif implementation_landed:
        return "proof-open" if qualification_open else "complete"

    raise TrackerError(f"unrecognized {identifier} status: {status}")


def parse_milestones(roadmap: str) -> tuple[Milestone, ...]:
    headings = list(MILESTONE_PATTERN.finditer(roadmap))
    identifiers = tuple(match.group(1) for match in headings)
    if identifiers != EXPECTED_MILESTONES:
        raise TrackerError(
            "roadmap must contain M0 through M7 exactly once and in order; "
            f"found {identifiers}"
        )

    milestones: list[Milestone] = []
    for index, heading in enumerate(headings):
        section_end = headings[index + 1].start() if index + 1 < len(headings) else len(roadmap)
        section = roadmap[heading.end() : section_end]
        status_match = STATUS_PATTERN.search(section)
        if status_match is None:
            raise TrackerError(f"{heading.group(1)} has no Status line")
        status = status_match.group(1).strip()
        milestones.append(
            Milestone(
                identifier=heading.group(1),
                title=heading.group(2).strip(),
                status=status,
                state=classify_status(heading.group(1), status),
            )
        )
    return tuple(milestones)


def parse_open_steps(qualification_status: str) -> tuple[str, ...]:
    marker = "## Open M7 simulator steps"
    marker_index = qualification_status.find(marker)
    if marker_index < 0:
        return ()

    steps: list[str] = []
    for line in qualification_status[marker_index + len(marker) :].splitlines():
        match = re.match(r"^\s*\d+\.\s+(.+?)[;.]?$", line)
        if match:
            steps.append(match.group(1).strip())
            continue
        if steps and line.startswith("## "):
            break
    return tuple(steps)


def table_value(document: str, field: str) -> str:
    match = re.search(
        rf"^\| {re.escape(field)} \| (.+?) \|$",
        document,
        re.MULTILINE,
    )
    if match is None:
        raise TrackerError(f"qualification status has no {field} field")
    return match.group(1).strip().strip("`")


def read_selection_contract(root: Path) -> tuple[dict, Path]:
    path = root / "script/v4/m7-simulation-selection-contract-v1.json"
    try:
        contract = json.loads(read_required(path))
    except json.JSONDecodeError as error:
        raise TrackerError(f"selection contract is not JSON: {error}") from error
    if not isinstance(contract, dict):
        raise TrackerError("selection contract is not an object")
    if contract.get("schemaVersion") != "mirmir-ash-v4-m7-simulation-selection-contract-v1":
        raise TrackerError("selection contract schema differs")
    if contract.get("baselineVariant") != "baseline_p05":
        raise TrackerError("selection baseline differs")
    if tuple(contract.get("candidateVariants", ())) != EXPECTED_CANDIDATES:
        raise TrackerError("selection candidate roster differs")
    if contract.get("eligibleCorpusKinds") != ["synthetic_diagnostic"]:
        raise TrackerError("selection corpus scope differs")
    quality = contract.get("quality")
    timing = contract.get("timing")
    if quality != {
        "minimumIndex": 105.0,
        "minimumPairedBootstrap95PercentLowerBound": 105.0,
    }:
        raise TrackerError("selection quality targets differ")
    if timing != {
        "maximumMedianRatio": 0.8,
        "maximumP95Ratio": 0.8,
        "maximumTotalRatio": 0.8,
    }:
        raise TrackerError("selection processing-time targets differ")
    return contract, path


def checked_evidence_path(root: Path, relative: str) -> Path:
    if "\\" in relative or not relative.startswith("docs/v4/evidence/"):
        raise TrackerError("selection evidence path is outside docs/v4/evidence")
    path = (root / relative).resolve()
    evidence_root = (root / "docs/v4/evidence").resolve()
    try:
        path.relative_to(evidence_root)
    except ValueError as error:
        raise TrackerError("selection evidence path escapes docs/v4/evidence") from error
    if path.name != "m7-simulation-selection-report.json" or not path.is_file() or path.is_symlink():
        raise TrackerError("selection evidence report is absent or unsafe")
    return path


def verify_completed_selection(
    root: Path,
    selection_contract: Path,
    evidence_value: str,
    source_commit: str,
    selected_candidate: str,
) -> None:
    report_path = checked_evidence_path(root, evidence_value)
    evidence_root = report_path.parent
    quality_contract = evidence_root / "quality-gate-contract-v1.json"
    canonical_quality_contract = evidence_root / "quality-gate-canonical-contract-v1.json"
    quality_report = evidence_root / "quality-gate-report.json"
    selector = root / "script/v4/select_simulated_candidate_v4.py"
    derivation_tool = root / "script/v4/derive_m7_quality_contract_v4.py"
    p05_discovery = evidence_root / "p05-discovery.json"
    p05_binding = evidence_root / "m7-p05-toolchain-binding.json"
    for path in (
        quality_contract,
        canonical_quality_contract,
        quality_report,
        selector,
        derivation_tool,
        p05_discovery,
        p05_binding,
    ):
        if not path.is_file() or path.is_symlink():
            raise TrackerError(f"selection verifier input is absent or unsafe: {path}")
    try:
        derivation = subprocess.run(
            [
                sys.executable,
                str(derivation_tool),
                "--canonical",
                str(canonical_quality_contract),
                "--discovery",
                str(p05_discovery),
                "--output",
                str(quality_contract),
                "--binding",
                str(p05_binding),
                "--verify",
            ],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
        )
        if derivation.returncode != 0:
            detail = derivation.stderr.strip() or derivation.stdout.strip()
            raise TrackerError(f"P05 toolchain binding does not reproduce: {detail}")
        completed = subprocess.run(
            [
                sys.executable,
                str(selector),
                "verify",
                "--contract",
                str(selection_contract),
                "--quality-contract",
                str(quality_contract),
                "--quality-report",
                str(quality_report),
                "--capture-binding",
                str(evidence_root / "m7-capture-binding.json"),
                "--canonical-quality-contract",
                str(canonical_quality_contract),
                "--p05-discovery",
                str(p05_discovery),
                "--p05-binding",
                str(p05_binding),
                "--output",
                str(report_path),
            ],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=180,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise TrackerError(f"cannot replay selection evidence: {error}") from error
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise TrackerError(f"selection evidence does not reproduce: {detail}")
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise TrackerError(f"selection report is not JSON: {error}") from error
    if report.get("m7Satisfied") is not True:
        raise TrackerError("selection report does not satisfy M7")
    if report.get("sourceCommit") != source_commit:
        raise TrackerError("selection report source commit differs")
    if report.get("selectedCandidateID") != selected_candidate:
        raise TrackerError("selection report winner differs")
    expected_contract_sha = hashlib.sha256(selection_contract.read_bytes()).hexdigest()
    if report.get("contractSHA256") != expected_contract_sha:
        raise TrackerError("selection report contract identity differs")


def parse_state(root: Path) -> TrackerState:
    roadmap = read_required(root / "DETERMINISTIC_ENGINE_V4_ROADMAP.md")
    qualification_status = read_required(root / "docs/v4/CURRENT_QUALIFICATION_STATUS.md")
    version = read_required(root / "VERSION").strip()
    build = read_required(root / "BUILD_NUMBER").strip()

    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is None:
        raise TrackerError(f"invalid VERSION value: {version!r}")
    if re.fullmatch(r"[1-9][0-9]*", build) is None:
        raise TrackerError(f"invalid BUILD_NUMBER value: {build!r}")

    verified_match = re.search(r"^Verified\s+(.+?)\.$", qualification_status, re.MULTILINE)
    if verified_match is None:
        raise TrackerError("qualification status has no verified date")

    selection_contract, selection_contract_path = read_selection_contract(root)
    milestones = parse_milestones(roadmap)
    open_steps = parse_open_steps(qualification_status)
    m7_status = table_value(qualification_status, "M7 simulation status")
    commit_value = table_value(qualification_status, "Simulation source commit")
    selected_candidate = table_value(qualification_status, "Selected candidate")
    quality_target = table_value(qualification_status, "Quality target")
    timing_target = table_value(qualification_status, "Processing-time target")
    evidence_value = table_value(qualification_status, "Selection evidence")
    m7_satisfied = m7_status == "Complete"
    if m7_status not in {"Pending", "Complete"}:
        raise TrackerError(f"unsupported M7 simulation status: {m7_status}")
    if (milestones[-1].state == "complete") != m7_satisfied:
        raise TrackerError("roadmap and qualification document disagree about M7 completion")
    if not m7_satisfied and not open_steps:
        raise TrackerError("M7 is pending but no simulator steps are open")
    if not m7_satisfied and (
        commit_value != "Pending"
        or selected_candidate != "Pending"
        or quality_target != "Pending"
        or timing_target != "Pending"
        or evidence_value != "Pending"
    ):
        raise TrackerError("pending M7 contains completed decision fields")
    if m7_satisfied:
        if open_steps:
            raise TrackerError("completed M7 still has open simulator steps")
        if re.fullmatch(r"[0-9a-f]{40}", commit_value) is None:
            raise TrackerError("completed M7 has no full simulation source commit")
        if selected_candidate not in selection_contract["candidateVariants"]:
            raise TrackerError("completed M7 has no selected candidate")
        if not quality_target.startswith("Passed") or not timing_target.startswith("Passed"):
            raise TrackerError("completed M7 has an unpassed numerical target")
        if evidence_value == "Pending":
            raise TrackerError("completed M7 has no selection evidence")
        verify_completed_selection(
            root,
            selection_contract_path,
            evidence_value,
            commit_value,
            selected_candidate,
        )
    simulation_source_commit = (
        commit_value if re.fullmatch(r"[0-9a-f]{40}", commit_value) else None
    )

    return TrackerState(
        version=version,
        build=build,
        verified_date=verified_match.group(1),
        simulation_source_commit=simulation_source_commit,
        selected_candidate=selected_candidate,
        milestones=milestones,
        open_steps=open_steps,
        m7_satisfied=m7_satisfied,
        quality_gain_percent=float(selection_contract["quality"]["minimumIndex"]) - 100.0,
        processing_reduction_percent=(
            1.0 - float(selection_contract["timing"]["maximumTotalRatio"])
        ) * 100.0,
        candidate_count=len(selection_contract["candidateVariants"]),
    )


def wrapped_lines(value: str, width: int, maximum: int) -> tuple[str, ...]:
    lines = tuple(textwrap.wrap(value, width=width, break_long_words=False, break_on_hyphens=False))
    if not lines:
        return ("",)
    if len(lines) <= maximum:
        return lines
    shortened = list(lines[:maximum])
    shortened[-1] = textwrap.shorten(
        " ".join(lines[maximum - 1 :]),
        width=width,
        placeholder="…",
    )
    return tuple(shortened)


def render_text_lines(lines: tuple[str, ...], x: int, y: int, css_class: str, step: int = 22) -> str:
    return "\n".join(
        f'<text class="{css_class}" x="{x}" y="{y + index * step}">{html.escape(line)}</text>'
        for index, line in enumerate(lines)
    )


def milestone_label(milestone: Milestone) -> str:
    if milestone.state == "complete":
        return "Complete"
    if milestone.state == "proof-open":
        return "Implemented · simulator proof open"
    return "Simulator selection open"


def render_svg(state: TrackerState) -> str:
    implementation_complete = all(
        milestone.state in {"complete", "proof-open"}
        for milestone in state.milestones[:-1]
    )
    m7_open = state.milestones[-1].state == "open"
    release_gate_label = "PASSED" if state.m7_satisfied and not m7_open else "OPEN"
    release_gate_class = "gate-open" if release_gate_label == "OPEN" else "gate-complete"

    cards: list[str] = []
    for index, milestone in enumerate(state.milestones):
        column = index % 4
        row = index // 4
        x = 44 + column * 279
        y = 154 + row * 142
        state_class = {
            "complete": "complete",
            "proof-open": "proof-open",
            "open": "open",
        }[milestone.state]
        title = render_text_lines(wrapped_lines(milestone.title, 29, 2), x + 18, y + 58, "card-title")
        cards.append(
            f'''<g class="milestone {state_class}">
  <rect x="{x}" y="{y}" width="259" height="124" rx="14"/>
  <text class="milestone-id" x="{x + 18}" y="{y + 29}">{milestone.identifier}</text>
  <text class="milestone-state" x="{x + 241}" y="{y + 29}" text-anchor="end">{html.escape(milestone_label(milestone))}</text>
  {title}
</g>'''
        )

    quality_threshold = f"≥{state.quality_gain_percent:g}%"
    processing_threshold = f"≥{state.processing_reduction_percent:g}% faster"
    gates = (
        ("Quality", quality_threshold),
        ("Processing time", processing_threshold),
        ("Candidates", f"{state.candidate_count} variants"),
        ("Selection", "deterministic rank"),
        ("Evidence", "independent replay"),
    )
    gate_cards: list[str] = []
    for index, (name, threshold) in enumerate(gates):
        x = 44 + index * 223
        gate_cards.append(
            f'''<g class="release-gate {release_gate_class}">
  <rect x="{x}" y="489" width="205" height="73" rx="12"/>
  <text class="gate-name" x="{x + 14}" y="516">{html.escape(name)}</text>
  <text class="gate-value" x="{x + 14}" y="540">{html.escape(threshold)} · {release_gate_label}</text>
</g>'''
        )

    implementation_label = "M0–M6 implementation complete" if implementation_complete else "Implementation in progress"
    qualification_label = "M7 simulator selection open" if m7_open else "M7 simulator selection complete"
    qualification_summary_class = "summary-open" if m7_open else "summary"
    step_label = (
        f"{len(state.open_steps)} simulator steps open"
        if state.open_steps
        else f"Selected {state.selected_candidate}"
    )
    description = (
        f"{implementation_label}. {qualification_label}. {step_label}. "
        f"Quality and processing-time simulation targets are {release_gate_label.lower()}. "
        "Physical hardware, notarization, shipping, and distribution are outside M7."
    )

    segments = []
    for index, milestone in enumerate(state.milestones):
        css_class = "segment-complete" if milestone.state == "complete" else "segment-open"
        if milestone.state == "proof-open":
            css_class = "segment-proof"
        segments.append(
            f'<rect class="{css_class}" x="{44 + index * 139}" y="119" width="125" height="10" rx="5"/>'
        )

    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="620" viewBox="0 0 1200 620" role="img" aria-labelledby="roadmap-title roadmap-description">
  <title id="roadmap-title">Mirmir deterministic engine v4 roadmap status</title>
  <desc id="roadmap-description">{html.escape(description)}</desc>
  <style>
    .background {{ fill: #101d29; }}
    text {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #dce9f3; }}
    .eyebrow {{ font-size: 13px; font-weight: 600; letter-spacing: 1.2px; fill: #88a7ba; }}
    .title {{ font-size: 30px; font-weight: 700; }}
    .summary {{ font-size: 16px; fill: #9fb8c8; }}
    .summary-open {{ font-size: 16px; font-weight: 600; fill: #efc45c; }}
    .segment-complete {{ fill: #55c7b5; }}
    .segment-proof {{ fill: #d9aa43; }}
    .segment-open {{ fill: #4e88a8; }}
    .milestone rect {{ fill: #182a38; stroke-width: 1.5; }}
    .milestone.complete rect {{ stroke: #397e76; }}
    .milestone.proof-open rect {{ stroke: #8f7437; }}
    .milestone.open rect {{ stroke: #4e7890; fill: #1c3242; }}
    .milestone-id {{ font-size: 20px; font-weight: 700; }}
    .milestone-state {{ font-size: 11px; font-weight: 600; }}
    .complete .milestone-state {{ fill: #65d1c0; }}
    .proof-open .milestone-state {{ fill: #efc45c; }}
    .open .milestone-state {{ fill: #83bddb; }}
    .card-title {{ font-size: 15px; font-weight: 600; fill: #c8d9e5; }}
    .section-label {{ font-size: 13px; font-weight: 600; fill: #88a7ba; letter-spacing: .4px; }}
    .release-gate rect {{ fill: #172936; stroke-width: 1.25; }}
    .release-gate.gate-open rect {{ stroke: #8f7437; }}
    .release-gate.gate-complete rect {{ stroke: #397e76; }}
    .gate-name {{ font-size: 14px; font-weight: 600; }}
    .gate-value {{ font-size: 12px; fill: #efc45c; }}
    .gate-complete .gate-value {{ fill: #65d1c0; }}
    .footer {{ font-size: 12px; fill: #88a7ba; }}
  </style>
  <rect class="background" width="1200" height="620" rx="22"/>
  <text class="eyebrow" x="44" y="39">MIRMIR · ASH P06 · VERSION {html.escape(state.version)} ({html.escape(state.build)})</text>
  <text class="title" x="44" y="78">Deterministic Engine v4</text>
  <text class="summary" x="44" y="103">{html.escape(implementation_label)}</text>
  <text class="{qualification_summary_class}" x="1148" y="103" text-anchor="end">{html.escape(qualification_label)}</text>
  {''.join(segments)}
  {''.join(cards)}
  <text class="section-label" x="44" y="466">M7 SIMULATOR DECISION</text>
  {''.join(gate_cards)}
  <text class="footer" x="44" y="591">{html.escape(step_label)} · simulation source {state.simulation_source_commit[:12] if state.simulation_source_commit else 'pending'} · verified {html.escape(state.verified_date)}</text>
  <text class="footer" x="1156" y="591" text-anchor="end">Simulator only · no hardware/notarization/shipping/distribution</text>
</svg>
'''


def update(root: Path, output: Path, check: bool) -> int:
    expected = render_svg(parse_state(root))
    if check:
        if not output.is_file():
            print(f"roadmap tracker is missing: {output}", file=sys.stderr)
            return 1
        actual = output.read_text(encoding="utf-8")
        if actual != expected:
            print(
                "roadmap tracker is stale; run "
                "python3 script/v4/update_roadmap_tracker.py",
                file=sys.stderr,
            )
            return 1
        print(f"roadmap tracker is current: {output}")
        return 0

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(expected, encoding="utf-8")
    print(f"updated roadmap tracker: {output}")
    return 0


def main(argv: list[str] | None = None) -> int:
    default_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args(argv)
    root = arguments.root.resolve()
    output = arguments.output.resolve() if arguments.output else root / "docs/v4/roadmap-status.svg"
    try:
        return update(root, output, arguments.check)
    except TrackerError as error:
        print(f"roadmap tracker failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Tests for the generated deterministic-engine-v4 roadmap tracker."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("update_roadmap_tracker.py")
SPEC = importlib.util.spec_from_file_location("update_roadmap_tracker", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
tracker = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = tracker
SPEC.loader.exec_module(tracker)


class RoadmapTrackerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "docs/v4").mkdir(parents=True)
        (self.root / "VERSION").write_text("1.3.0\n", encoding="utf-8")
        (self.root / "BUILD_NUMBER").write_text("3\n", encoding="utf-8")
        (self.root / "script/v4").mkdir(parents=True)
        (self.root / "script/v4/m7-simulation-selection-contract-v1.json").write_text(
            """{
  "baselineVariant": "baseline_p05",
  "candidateVariants": [
    "candidate_v4",
    "uniform_priors",
    "randomized_state_message",
    "temporal_hysteresis_off",
    "motion_history_off"
  ],
  "eligibleCorpusKinds": ["synthetic_diagnostic"],
  "quality": {
    "minimumIndex": 105.0,
    "minimumPairedBootstrap95PercentLowerBound": 105.0
  },
  "schemaVersion": "mirmir-ash-v4-m7-simulation-selection-contract-v1",
  "selectionOrder": [],
  "timing": {
    "maximumMedianRatio": 0.8,
    "maximumP95Ratio": 0.8,
    "maximumTotalRatio": 0.8
  }
}\n""",
            encoding="utf-8",
        )
        roadmap = ["# Roadmap", ""]
        for index in range(8):
            roadmap.extend(
                [
                    f"### M{index} — Milestone {index}",
                    "",
                    (
                        "Status: simulator contract complete; candidate comparison remains open"
                        if index == 7
                        else "Status: implementation landed in 1.3.0; M7 proof remains open"
                        if index in {2, 3, 6}
                        else "Status: landed in 1.3.0"
                    ),
                    "",
                ]
            )
        (self.root / "DETERMINISTIC_ENGINE_V4_ROADMAP.md").write_text(
            "\n".join(roadmap),
            encoding="utf-8",
        )
        (self.root / "docs/v4/CURRENT_QUALIFICATION_STATUS.md").write_text(
            """# Status

Verified September 21, 2026.

## Current M7 decision

| Field | Value |
| --- | --- |
| M7 simulation status | Pending |
| Simulation source commit | Pending |
| Selected candidate | Pending |
| Quality target | Pending |
| Processing-time target | Pending |
| Selection evidence | Pending |

## Open M7 simulator steps

1. performance;
2. quality.
""",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_renders_all_milestones_and_open_simulator_steps(self) -> None:
        state = tracker.parse_state(self.root)
        document = tracker.render_svg(state)

        self.assertEqual(tuple(item.identifier for item in state.milestones), tracker.EXPECTED_MILESTONES)
        self.assertEqual(len(state.open_steps), 2)
        self.assertIn("M0–M6 implementation complete", document)
        self.assertIn("M7 simulator selection open", document)
        self.assertIn(
            '<text class="summary-open" x="1148" y="103" text-anchor="end">M7 simulator selection open</text>',
            document,
        )
        self.assertIn("≥5% · OPEN", document)
        self.assertIn("simulation source pending", document)
        self.assertIn(
            "Physical hardware, notarization, shipping, and distribution are outside M7.",
            document,
        )
        self.assertIn(
            "Simulator only · no hardware/notarization/shipping/distribution",
            document,
        )

        completed_document = tracker.render_svg(
            replace(
                state,
                simulation_source_commit="0" * 40,
                selected_candidate="candidate_v4",
                open_steps=(),
                m7_satisfied=True,
                milestones=state.milestones[:-1]
                + (replace(state.milestones[-1], state="complete"),),
            )
        )
        self.assertIn(
            '<text class="summary" x="1148" y="103" text-anchor="end">M7 simulator selection complete</text>',
            completed_document,
        )

    def test_check_rejects_stale_output(self) -> None:
        output = self.root / "docs/v4/roadmap-status.svg"
        output.write_text("stale\n", encoding="utf-8")

        self.assertEqual(tracker.update(self.root, output, check=True), 1)
        self.assertEqual(tracker.update(self.root, output, check=False), 0)
        self.assertEqual(tracker.update(self.root, output, check=True), 0)

    def test_rejects_missing_milestone(self) -> None:
        roadmap_path = self.root / "DETERMINISTIC_ENGINE_V4_ROADMAP.md"
        roadmap_path.write_text(
            roadmap_path.read_text(encoding="utf-8").replace("### M4 — Milestone 4", "### Removed"),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(tracker.TrackerError, "M0 through M7"):
            tracker.parse_state(self.root)

    def test_rejects_open_m7_without_simulator_steps(self) -> None:
        status_path = self.root / "docs/v4/CURRENT_QUALIFICATION_STATUS.md"
        status_path.write_text(
            status_path.read_text(encoding="utf-8").replace(
                "## Open M7 simulator steps\n\n1. performance;\n2. quality.\n",
                "",
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(tracker.TrackerError, "no simulator steps"):
            tracker.parse_state(self.root)

    def test_rejects_selection_contract_drift(self) -> None:
        contract_path = self.root / "script/v4/m7-simulation-selection-contract-v1.json"
        contract_path.write_text(
            contract_path.read_text(encoding="utf-8").replace(
                '"maximumTotalRatio": 0.8',
                '"maximumTotalRatio": 0.9',
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(tracker.TrackerError, "processing-time targets differ"):
            tracker.parse_state(self.root)


if __name__ == "__main__":
    unittest.main()

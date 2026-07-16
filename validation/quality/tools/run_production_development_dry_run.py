#!/usr/bin/env python3
"""Run the production-locked development quality dry run."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys


QUALITY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(QUALITY_ROOT / "src"))

from mirmir_quality.production_dry_run import (  # noqa: E402
    ProductionDevelopmentDryRun,
    ProductionDryRunInterrupted,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--corpus-lock", type=Path, required=True)
    parser.add_argument("--asset-root", type=Path, required=True)
    parser.add_argument("--evidence-root", type=Path, required=True)
    parser.add_argument("--development-sample-lock", type=Path, required=True)
    parser.add_argument("--sample-root", type=Path, required=True)
    parser.add_argument("--resume-from", type=Path)
    parser.add_argument("--fail-after-cases", type=int)
    arguments = parser.parse_args()

    runner = ProductionDevelopmentDryRun(
        output_root=arguments.output_root,
        run_id=arguments.run_id,
        quality_root=QUALITY_ROOT,
        corpus_lock_path=arguments.corpus_lock,
        asset_root=arguments.asset_root,
        evidence_root=arguments.evidence_root,
        development_sample_lock_path=arguments.development_sample_lock,
        sample_root=arguments.sample_root,
    )
    try:
        final = runner.run(
            resume_from=arguments.resume_from,
            fail_after_cases=arguments.fail_after_cases,
        )
    except ProductionDryRunInterrupted as error:
        print(f"failed_run={error.failure_path}")
        return 1
    print(f"final_run={final}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

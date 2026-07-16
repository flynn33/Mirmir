#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.reference.lut_oracle import (  # noqa: E402
    ROUTES,
    compile_route_bytes,
    load_locked_compiler_input,
    validate_lut,
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compile both P06 route LUTs with the independent reference compiler."
    )
    parser.add_argument("locked_input", type=Path, help="schema-valid locked compiler-input JSON")
    parser.add_argument("output_directory", type=Path, help="new or empty output directory")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    configuration = load_locked_compiler_input(arguments.locked_input)
    arguments.output_directory.mkdir(parents=True, exist_ok=True)
    output_paths = {
        name: arguments.output_directory / route.filename for name, route in ROUTES.items()
    }
    existing = [str(path) for path in output_paths.values() if path.exists()]
    if existing:
        raise FileExistsError(f"refusing to replace existing LUT files: {existing}")

    summaries = []
    for name, route in ROUTES.items():
        data = compile_route_bytes(route, configuration)
        output_paths[name].write_bytes(data)
        validated = validate_lut(
            data,
            expected_configuration=configuration,
            expected_route=route,
        )
        summaries.append(
            {
                "entry_count": validated.entry_count,
                "filename": route.filename,
                "parameter_count": validated.parameter_count,
                "payload_sha256": validated.payload_sha256,
                "route": name,
                "whole_file_sha256": validated.whole_file_sha256,
                "whole_file_size_bytes": len(data),
            }
        )
    print(
        json.dumps(
            {
                "configuration_id": configuration.configuration_id,
                "routes": summaries,
                "status": "compiled_and_validated",
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

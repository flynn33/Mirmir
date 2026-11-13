"""Current physical quality contracts retain the genuine historical P05 inputs."""
from __future__ import annotations

import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest

import chroma_geometry_v4 as chroma
import p05_baseline_v4 as p05
import quality_gate_v4 as quality


SCRIPT_DIRECTORY = Path(__file__).resolve().parent


def load(name: str) -> dict:
    return json.loads((SCRIPT_DIRECTORY / name).read_text())


class QualityContractPhase2V4Tests(unittest.TestCase):
    def testCurrentContractsChangeOnlyPhysicalDeclarationAndRetainP05(self) -> None:
        for prefix in ("quality-gate-contract", "quality-gate-release-contract"):
            with self.subTest(contract=prefix):
                old, new = load(prefix + "-v1.json"), load(prefix + "-v2.json")
                self.assertFalse(chroma.quality_contract_phase2(old))
                self.assertTrue(chroma.quality_contract_phase2(new))
                self.assertEqual(p05.frozen_identity(old), p05.frozen_identity(new))
                self.assertEqual(old["corpusConstruction"]["chromaSiting"], "left")
                expected = copy.deepcopy(old)
                expected["schemaVersion"] = chroma.QUALITY_CONTRACT_SCHEMA_PHASE2
                expected["corpusConstruction"].update(
                    chromaSiting="center", sourceChromaSiting="center",
                    referenceChromaSiting="center",
                    chromaRecipePolicyID=chroma.QUALITY_RECIPE_POLICY_ID,
                )
                self.assertEqual(new, expected)

    def testFreshAndHistoricalContractCaptureProfilesCannotMix(self) -> None:
        old = load("quality-gate-contract-v1.json")
        new = load("quality-gate-contract-v2.json")
        quality.require_quality_contract_profile(old, False)
        quality.require_quality_contract_profile(new, True)
        for contract, selected in ((old, True), (new, False)):
            with self.subTest(selected=selected), self.assertRaisesRegex(
                SystemExit, "phase profiles differ"
            ):
                quality.require_quality_contract_profile(contract, selected)

    def testFreshPhysicalDeclarationRejectsMissingForeignAndWrongFacts(self) -> None:
        original = load("quality-gate-contract-v2.json")
        for key in (
            "chromaSiting", "sourceChromaSiting", "referenceChromaSiting",
            "chromaRecipePolicyID", "declaredDownsampling",
        ):
            for operation in ("missing", "foreign"):
                changed = copy.deepcopy(original)
                if operation == "missing":
                    del changed["corpusConstruction"][key]
                else:
                    changed["corpusConstruction"][key] = "foreign"
                with self.subTest(key=key, operation=operation):
                    with self.assertRaises(ValueError):
                        chroma.quality_contract_phase2(changed)
        changed = copy.deepcopy(original)
        changed["corpusConstruction"]["extra"] = "center"
        with self.assertRaisesRegex(ValueError, "field set differs"):
            chroma.quality_contract_phase2(changed)

    def testSyntheticRegenerationKeepsEveryRawArtifactAndChangesManifest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="quality-physical-contract-") as temporary:
            root = Path(temporary)
            manifests = []
            for version in (1, 2):
                contract = load(f"quality-gate-contract-v{version}.json")
                contract["corpusConstruction"].update(
                    syntheticDiagnosticClipCountPerCohort=1,
                    syntheticDiagnosticFramesPerClip=2,
                )
                path = root / f"contract{version}.json"
                path.write_text(json.dumps(contract))
                output = root / f"corpus{version}"
                with contextlib.redirect_stdout(io.StringIO()):
                    quality.generate_corpus(path, output)
                manifests.append(json.loads((output / "corpus-manifest.json").read_text()))
            old, new = manifests
            self.assertEqual(old["artifactSetSHA256"], new["artifactSetSHA256"])
            self.assertEqual(old["cases"], new["cases"])
            self.assertEqual(old["artifacts"], new["artifacts"])
            for item in old["artifacts"]:
                self.assertEqual(
                    (root / "corpus1" / item["path"]).read_bytes(),
                    (root / "corpus2" / item["path"]).read_bytes(),
                )
            self.assertEqual(
                {key for key in old if old[key] != new[key]},
                {"construction", "contractSHA256"},
            )

    def testRehashedOldConstructionRejectsBeforeRawArtifactsAreRead(self) -> None:
        contract = load("quality-gate-contract-v2.json")
        corpus = {"construction": load("quality-gate-contract-v1.json")["corpusConstruction"]}
        with self.assertRaisesRegex(SystemExit, "construction differs"):
            quality.replay_raw_components(
                contract, corpus, Path("/absent-corpus"),
                {"schemaVersion": quality.SCHEMA_CAPTURE_PHASE2}, Path("/absent-capture"),
            )

    def testHistoricalCorpusBuilderAndLockRemainExact(self) -> None:
        lock = load("natural-quality-corpus-lock-v1.json")
        builder = SCRIPT_DIRECTORY / "test-fixtures/phase1-release-v1/script/v4/build_natural_quality_corpus.py"
        self.assertEqual(builder.stat().st_size, 19178)
        self.assertEqual(
            hashlib.sha256(builder.read_bytes()).hexdigest(),
            "0150955cfa206bf9e4b3f3ca7b74971543e70d4ec47d4f174eb87b1e33790aa8",
        )
        self.assertEqual(lock["builderSourceSHA256"], hashlib.sha256(builder.read_bytes()).hexdigest())
        self.assertEqual(lock["manifestSHA256"], "f999e0607dfac799ee0531804d14c4e6333db3bee20328898498e6a5e9a96896")
        current = load("natural-quality-corpus-lock-v2.json")
        self.assertEqual(current["artifactSetSHA256"], lock["artifactSetSHA256"])
        self.assertNotEqual(current["manifestSHA256"], lock["manifestSHA256"])


if __name__ == "__main__":
    unittest.main()

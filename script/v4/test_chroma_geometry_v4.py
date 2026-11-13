"""Strict phase2 geometry evidence and independently replayed golden identities."""
from __future__ import annotations
import copy
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import chroma_geometry_v4 as chroma
import quality_gate_v4 as quality

GOLDEN = {
    "coordinateProcedureID": "pixel-center-luma-authenticated-subsampled-siting-v2",
    "kernelContractID": "ash-p06-catmull-rom-q14-subsampled-physical-siting-v2",
    "kernelIRSHA256": "f69ce9c88b2c13362f899755e46061d32577b01f2a7e5ff1a647d99138c95a24",
    "outputSiting": "center", "planSchemaVersion": 2,
    "recipePolicyID": "quality-box-source-reference-center-v1",
    "scalePlanSHA256": "8a71db5178322e7cb0a3b71f3811a0b78da4e2fe3577a7a9a8bc79b4f1623220",
    "schemaVersion": "mirmir-ash-v4-quality-chroma-geometry-v1",
    "sourceLumaHeight": 36, "sourceLumaWidth": 48, "sourceSiting": "center",
    "targetLumaHeight": 72, "targetLumaWidth": 96,
}


class ChromaGeometryV4Tests(unittest.TestCase):
    def validate(self, value):
        chroma.validate_geometry(value, (48, 36, 96, 72),
            schema="mirmir-ash-v4-quality-chroma-geometry-v1",
            policy="quality-box-source-reference-center-v1", source="center", target="center", label="golden")

    def testActualSwiftPlanAndKernelGoldenMatchIndependentPhysicalReplay(self):
        self.validate(GOLDEN)
        self.assertEqual(chroma.expected_hashes(48,36,96,72,"center","center"),
                         (GOLDEN["scalePlanSHA256"], GOLDEN["kernelIRSHA256"]))

    def testMissingForeignIncorrectAndRehashedGeometryReject(self):
        for key in GOLDEN:
            with self.subTest(missing=key):
                value=copy.deepcopy(GOLDEN);del value[key]
                with self.assertRaises(ValueError):self.validate(value)
        changes={"schemaVersion":"foreign", "recipePolicyID":"foreign",
            "coordinateProcedureID":"pixel-center-v1", "kernelContractID":"legacy",
            "sourceSiting":"left", "outputSiting":"left", "planSchemaVersion":1,
            "sourceLumaWidth":47, "sourceLumaHeight":35, "targetLumaWidth":95,
            "targetLumaHeight":71, "scalePlanSHA256":"0"*64, "kernelIRSHA256":"1"*64}
        for key,bad in changes.items():
            with self.subTest(field=key):
                value={**GOLDEN,key:bad}
                if key in {"sourceSiting","outputSiting"}:
                    value["scalePlanSHA256"],value["kernelIRSHA256"]=chroma.expected_hashes(48,36,96,72,value["sourceSiting"],value["outputSiting"])
                with self.assertRaises(ValueError):self.validate(value)
        for key,bad in [("planSchemaVersion",True),("sourceLumaWidth",48.0),("extra",0)]:
            with self.assertRaises(ValueError):self.validate({**GOLDEN,key:bad})

    def testPhase2QualityDispatchRequiresKernelAndEveryCaseGeometry(self):
        definition={"id":"a","sourceWidth":48,"sourceHeight":36,"targetWidth":96,"targetHeight":72}
        case={"id":"a","outputs":{},"milliseconds":{},"chromaGeometry":GOLDEN}
        capture={key:"fixture" for key in ["contractSHA256","corpusManifestSHA256","sourceCommit",
            "sourceTreeIdentitySHA256","candidateBackendID","candidateImplementationVersion",
            "runtimeManifestSHA256","runtimeSourceRevision"]}
        capture.update(schemaVersion=quality.SCHEMA_CANDIDATE_PHASE2,fixedPointKernelID=chroma.KERNEL_ID,
            cases=[case],productionRuntimeLocked=False,fullMirrorIdentityPass=True,warmupCount=1)
        corpus={"cases":[definition]};quality.validate_phase2_geometry(capture,corpus)
        for change in ({"fixedPointKernelID":"legacy"},{"schemaVersion":"foreign"},{"cases":[]},
                       {"cases":[case,case]}, {"cases":[{k:v for k,v in case.items()if k!="chromaGeometry"}]},
                       {"cases":[{**case,"id":"foreign"}]}):
            with self.subTest(change=change),self.assertRaises(SystemExit):
                quality.validate_phase2_geometry({**capture,**change},corpus)

    def testDifferentPhysicalSitesAndSameCeilOddExtentsHaveDifferentPlanIdentity(self):
        plans={chroma.expected_hashes(31,19,62,38,site,site)[0]for site in chroma.OFFSETS}
        self.assertEqual(len(plans),6)
        self.assertNotEqual(chroma.expected_hashes(31,19,62,38,"center","center")[0],
                            chroma.expected_hashes(32,20,62,38,"center","center")[0])
        for dimensions in [(0,1,2,2),(2,2,1,2),(True,2,2,2),(65537,2,65537,2)]:
            with self.assertRaises(ValueError):chroma.expected_hashes(*dimensions,"center","center")

class Phase2ParityEvidenceTests(unittest.TestCase):
    def setUp(self):
        import cpu_metal_parity_v4
        self.parity = cpu_metal_parity_v4
        self.definition = {"id":"phase2-case", "kind":"pixel_temporal", "scanMode":"progressive",
            "sourceWidth":48,"sourceHeight":36,"targetWidth":96,"targetHeight":72,
            "storage":"nv12_video_range_8"}

    def plan(self, source):
        result={**GOLDEN,"schemaVersion":"mirmir-ash-v4-parity-chroma-plan-v1",
                "recipePolicyID":"parity-declared-raw-uv-field-siting-v1", "sourceSiting":source,"outputSiting":"left"}
        result["scalePlanSHA256"],result["kernelIRSHA256"]=chroma.expected_hashes(48,36,96,72,source,"left")
        return result

    def document(self, interlaced=False):
        p=self.parity
        return {"schemaVersion":p.EXECUTION_SCHEMA_PHASE2,"caseID":"phase2-case","backend":"cpu",
            "spatialSchedule":"production_full_frame","temporalSchedule":"raster",
            "checkpointSchemaID":p.CONTIGUOUS_CHECKPOINT_SCHEMA,"checkpointSHA256s":[],"boundedRoute":None,
            "fixedPointKernelID":chroma.KERNEL_ID,"chromaApplicability":"subsampled_420",
            "chromaGeometry":{"schemaVersion":"mirmir-ash-v4-parity-chroma-geometry-v1",
                "normalizationPolicyID":p.FIELD_CHROMA_POLICY if interlaced else "progressive-declared-uv-left-v1",
                "top":self.plan("left"),"bottom":self.plan("center") if interlaced else None}}

    def validate(self, document, definition=None, states=None):
        p=self.parity
        return p.validate_execution_evidence(p.canonical_json(document),definition or self.definition,
            states or {},"cpu","production_full_frame","raster","phase2")

    def testNewExecutionRequiresExactApplicableGeometry(self):
        p=self.parity;document=self.document();self.validate(document)
        for key in ["chromaApplicability","fixedPointKernelID","chromaGeometry"]:
            bad=copy.deepcopy(document);del bad[key]
            with self.subTest(missing=key),self.assertRaises(p.ParityEvidenceError):self.validate(bad)
        for key,bad in [("fixedPointKernelID","legacy"),("chromaGeometry",None),("chromaApplicability","not_applicable_packed_alpha"),("extra",1)]:
            with self.subTest(key=key),self.assertRaises(p.ParityEvidenceError):self.validate({**document,key:bad})
        bad=copy.deepcopy(document);bad["chromaGeometry"]["top"]=self.plan("center")
        with self.assertRaises(p.ParityEvidenceError):self.validate(bad)
        bad=copy.deepcopy(document);bad["schemaVersion"]=p.EXECUTION_SCHEMA
        with self.assertRaises(p.ParityEvidenceError):self.validate(bad)

    def testInterlacedPairAndRehashedWrongBottomPhaseReject(self):
        p=self.parity;definition={**self.definition,"scanMode":"interlaced_tff","kind":"pixel_interlaced_temporal"}
        document=self.document(True);self.validate(document,definition)
        for bad in [None,self.plan("left"),{**self.plan("center"),"sourceLumaWidth":47}]:
            forged=copy.deepcopy(document);forged["chromaGeometry"]["bottom"]=bad
            with self.assertRaises(p.ParityEvidenceError):self.validate(forged,definition)

    def testAlphaExplicitlyRejectsAnySubsampledProof(self):
        p=self.parity;document=self.document();definition={**self.definition,"kind":"alpha_spatial"}
        document.update(checkpointSchemaID="none",fixedPointKernelID="not_applicable_packed_alpha",
            chromaApplicability="not_applicable_packed_alpha",chromaGeometry=None)
        self.validate(document,definition)
        bad={**document,"chromaGeometry":self.document()["chromaGeometry"]}
        with self.assertRaises(p.ParityEvidenceError):self.validate(bad,definition)

    def testCheckpointFormatIdentityAuthenticatesCoordinatesAndBothPhases(self):
        p=self.parity;doc=self.document(True);definition={**self.definition,"scanMode":"interlaced_tff","kind":"pixel_interlaced_temporal"}
        checkpoint={"runtimeManifestSHA256":"a"*64}
        parts=["ash-p06-deterministic-v4","a"*64,"nv12_video_range_8_bit","48","36","96","72","x=2/1;y=2/1",
            chroma.COORDINATE_ID,chroma.COORDINATE_ID+":left->left",p.FIELD_CHROMA_POLICY+":top=left;bottom=center;output=left"]
        checkpoint["formatIdentity"]=p.sha256_bytes("|".join(parts).encode())
        data=p.compact_canonical_json(checkpoint);states={0:{"canonicalData":data}}
        doc["checkpointSHA256s"]=[p.sha256_bytes(data)];self.validate(doc,definition,states)
        checkpoint["formatIdentity"]="b"*64;data=p.compact_canonical_json(checkpoint)
        doc["checkpointSHA256s"]=[p.sha256_bytes(data)]
        with self.assertRaises(p.ParityEvidenceError):self.validate(doc,definition,{0:{"canonicalData":data}})


class Phase2QualityReportTests(unittest.TestCase):
    def materialize(self, root):
        from test_quality_gate_v4 import QualityGateV4Tests
        fixture=QualityGateV4Tests();fixture.setUp();report,contract=fixture.materializeValidEvidence(root,phase2=True)
        capture_path=root/"capture-manifest.json"
        return fixture,report,contract,capture_path

    def testVersion2ReportReplaysAndRejectsResealedDependencyForgeryAndDowngrade(self):
        with tempfile.TemporaryDirectory()as temporary:
            root=Path(temporary);fixture,report,contract,capture=self.materialize(root)
            with contextlib.redirect_stdout(io.StringIO()):quality.verify_report(report,contract)
            original=json.loads(report.read_text());self.assertEqual(original["schemaVersion"],quality.SCHEMA_REPORT_PHASE2)
            bad=copy.deepcopy(original);bad["identities"]["chromaGeometryValidatorSHA256"]="0"*64;quality.write_json(report,bad);fixture.sealEvidence(root)
            with self.assertRaisesRegex(SystemExit,"validator identity"):quality.verify_report(report,contract)
            bad=copy.deepcopy(original);bad["schemaVersion"]=quality.SCHEMA_REPORT;del bad["identities"]["chromaGeometryValidatorSHA256"];quality.write_json(report,bad);fixture.sealEvidence(root)
            with self.assertRaisesRegex(SystemExit,"phase profiles differ"):quality.verify_report(report,contract)


if __name__ == "__main__":unittest.main()

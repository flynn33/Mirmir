"""Actual loaded-code tests for current five-helper and historical four-helper trust."""
from __future__ import annotations
import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import release_qualification_v4 as qualification
import release_qualification_trust_v4 as builder

SCRIPT_DIRECTORY = Path(__file__).resolve().parent


class Phase2TrustClosureV4Tests(unittest.TestCase):
    def setUp(self):
        self.contract = SCRIPT_DIRECTORY / "release-qualification-contract-v1.json"
        self.root = builder.build_trust_root(SCRIPT_DIRECTORY, self.contract)
        self.assertEqual(self.root["schemaVersion"], qualification.TRUST_ROOT_SCHEMA_PHASE2)

    def reseal(self, root):
        root["trustedToolSetSHA256"] = builder.trusted_tool_set_sha([
            {"role":"qualification_evaluator", **root["evaluator"]},
            {"role":"release_contract", **root["contract"]}, *root["helpers"]])

    def establish(self, root, contract=None):
        with tempfile.TemporaryDirectory()as temporary:
            path=Path(temporary)/"trust-root.json";path.write_text(json.dumps(root,sort_keys=True))
            return qualification.establish_external_trust(path, qualification.sha256(path), contract or self.contract)

    def testFiveVerifiedHelpersLoadChromaBeforeCurrentLaneImports(self):
        self.establish(self.root)
        self.assertEqual(len(self.root["helpers"]),5)
        self.assertEqual(self.root["helpers"][0]["role"],"chroma_geometry_replay")
        module=sys.modules["chroma_geometry_v4"]
        self.assertIs(qualification.parity_replay.chroma,module)
        self.assertIs(qualification.quality_replay.chroma,module)
        self.assertEqual(qualification.sha256(Path(module.__file__)),self.root["helpers"][0]["sha256"])

    def testMissingForeignRehashedAndOldTrustRejectBeforeAnyCodeLoads(self):
        variants=[]
        value=copy.deepcopy(self.root);value["helpers"].pop(0);variants.append(value)
        value=copy.deepcopy(self.root);value["helpers"][0]["repositoryRelativePath"]="script/v4/foreign.py";variants.append(value)
        value=copy.deepcopy(self.root);value["helpers"][0]["moduleName"]="foreign";variants.append(value)
        value=copy.deepcopy(self.root);value["helpers"][0]["sha256"]="0"*64;variants.append(value)
        value=copy.deepcopy(self.root);value["schemaVersion"]=qualification.TRUST_ROOT_SCHEMA;variants.append(value)
        value=copy.deepcopy(self.root);value["roleDispatch"][0]["replayHelperRoles"].remove("chroma_geometry_replay");variants.append(value)
        for index,value in enumerate(variants):
            self.reseal(value)
            with self.subTest(index=index),mock.patch.object(qualification,"load_trusted_replay_module")as loader:
                with self.assertRaises(qualification.QualificationError):self.establish(value)
                loader.assert_not_called()

    def testResealedForeignContractValidatorLockRejectsBeforeImport(self):
        with tempfile.TemporaryDirectory()as temporary:
            contract=json.loads(self.contract.read_text());contract["qualityLockedSources"]["chromaGeometryValidatorSHA256"]="0"*64
            path=Path(temporary)/"release-qualification-contract-v1.json";path.write_text(json.dumps(contract))
            value=copy.deepcopy(self.root);value["contract"]=builder.descriptor(path,"script/v4/release-qualification-contract-v1.json");self.reseal(value)
            with mock.patch.object(qualification,"load_trusted_replay_module")as loader:
                with self.assertRaisesRegex(qualification.QualificationError,"source lock"):self.establish(value,path)
                loader.assert_not_called()

    def testFreshAndHistoricalEnvelopeMixingRejects(self):
        contract=json.loads(self.contract.read_text())
        for quality,parity in [("mirmir-ash-v4-quality-report-v1","mirmir-ash-v4-cpu-metal-parity-report-v3"),
                               ("mirmir-ash-v4-quality-report-v2","mirmir-ash-v4-cpu-metal-parity-report-v2")]:
            changed=copy.deepcopy(contract);changed["evidenceSchemas"].update(quality=quality,cpu_metal_parity=parity)
            with self.assertRaises(qualification.QualificationError):qualification.validate_contract(changed)

    def testLegacyTrustRejectsCurrentModulesEvenWithResealedEnvelope(self):
        historical=SCRIPT_DIRECTORY/"test-fixtures/phase1-release-v1/script/v4/release-qualification-contract-v1.json"
        value=copy.deepcopy(self.root);value["schemaVersion"]=qualification.TRUST_ROOT_SCHEMA
        value["helpers"].pop(0)
        value["contract"]=builder.descriptor(historical,"script/v4/release-qualification-contract-v1.json")
        for row in value["roleDispatch"]:
            if row["role"]=="quality":row["evidenceSchema"]="mirmir-ash-v4-quality-report-v1"
            if row["role"]=="cpu_metal_parity":row["evidenceSchema"]="mirmir-ash-v4-cpu-metal-parity-report-v2"
            row["replayHelperRoles"]=[role for role in row["replayHelperRoles"]if role!="chroma_geometry_replay"]
        self.reseal(value)
        with mock.patch.object(qualification,"load_trusted_replay_module")as loader:
            with self.assertRaisesRegex(qualification.QualificationError,"historical trust root contains"):self.establish(value,historical)
            loader.assert_not_called()
        with self.assertRaisesRegex(ValueError,"exact four-helper"):builder.build_trust_root(SCRIPT_DIRECTORY,historical)

    def testHistoricalTrustSubprocessActuallyLoadsArchivedFourHelperBytes(self):
        fixture=SCRIPT_DIRECTORY/"test-fixtures/phase1-release-v1"
        manifest=json.loads((fixture/"source-manifest.json").read_text())
        with tempfile.TemporaryDirectory()as temporary:
            source=Path(temporary)/"script/v4";source.mkdir(parents=True)
            for row in manifest["files"]:
                self.assertIn(row["gitMode"], {"100644", "100755"})
                original=fixture/row["path"];self.assertEqual(original.stat().st_size,row["byteCount"]);self.assertEqual(qualification.sha256(original),row["sha256"])
                target=Path(temporary)/row["path"];target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(original,target)
            for name in ["release_qualification_v4.py","release_qualification_trust_v4.py"]:
                shutil.copy2(SCRIPT_DIRECTORY/name,source/name)
            code='''import json,sys;from pathlib import Path
sys.path.insert(0,sys.argv[1]);import release_qualification_v4 as q,release_qualification_trust_v4 as b
s=Path(sys.argv[1]);c=s/'release-qualification-contract-v1.json';v=b.build_trust_root(s,c)
assert v['schemaVersion']==q.TRUST_ROOT_SCHEMA and len(v['helpers'])==4
p=s/'operator-trust.json';p.write_text(json.dumps(v));q.establish_external_trust(p,q.sha256(p),c)
assert not hasattr(q.parity_replay,'chroma') and not hasattr(q.quality_replay,'chroma')
for role,module in [('cpu_metal_parity_replay',q.parity_replay),('quality_raw_plane_replay',q.quality_replay),('p05_baseline_replay',q.p05_replay),('support_matrix_replay',q.support_replay)]:
 assert q.sha256(Path(module.__file__))==q.LEGACY_REPLAY_SOURCE_SHA256[role]
print('historical four-helper bytes genuinely loaded')'''
            process=subprocess.run([sys.executable,"-c",code,str(source)],capture_output=True,text=True)
            self.assertEqual(process.returncode,0,process.stderr)
            self.assertIn("genuinely loaded",process.stdout)

class Phase2StagingAndIndexV4Tests(unittest.TestCase):
    def testFreshContractStageRequiresExactFourToolsAndUsesVersion3Name(self):
        import packaged_candidate_evidence_v4 as packaged
        contract=SCRIPT_DIRECTORY/"cpu-metal-parity-contract-v3.json"
        with tempfile.TemporaryDirectory()as temporary:
            root=Path(temporary);staged=packaged.stage_parity_contract(contract,root/"good")
            self.assertEqual(staged.name,"cpu-metal-parity-contract-v3.json")
            self.assertEqual(staged.read_bytes(),contract.read_bytes())
            original=json.loads(contract.read_text())
            for index,change in enumerate(("missing","foreign","malformed")):
                value=copy.deepcopy(original)
                if change=="missing":del value["tools"]["chromaGeometryValidatorSHA256"]
                if change=="foreign":value["tools"]["extraSHA256"]="a"*64
                if change=="malformed":value["tools"]["chromaGeometryValidatorSHA256"]="not-a-hash"
                path=root/(change+".json");path.write_text(json.dumps(value))
                with self.assertRaises(packaged.PackagedEvidenceError):packaged.stage_parity_contract(path,root/("bad"+str(index)))
            legacy=SCRIPT_DIRECTORY/"test-fixtures/phase1-release-v1/script/v4/cpu_metal_parity_v4.py"
            legacy_contract=root/"legacy.json";legacy_contract.write_text(json.dumps({"schemaVersion":"mirmir-ash-v4-cpu-metal-parity-contract-v2"}))
            self.assertEqual(packaged.stage_parity_contract(legacy_contract,root/"legacy").name,"cpu-metal-parity-contract-v2.json")

    def testIndexSelectsVersion3ContractAndSealedValidatorOnly(self):
        import assemble_release_evidence_index_v4 as index
        with tempfile.TemporaryDirectory()as temporary:
            root=Path(temporary).resolve();suite=root/"cpu_metal_parity";suite.mkdir()
            old=suite/"cpu-metal-parity-contract-v2.json";current=suite/"cpu-metal-parity-contract-v3.json";helper=suite/"chroma_geometry_v4.py"
            old.write_bytes(b"same-contract-bytes");current.write_bytes(old.read_bytes());helper.write_bytes(b"bound-helper")
            paths={old,current,helper};facts={path:{"byteCount":path.stat().st_size,"sha256":index.sha256(path)}for path in paths}
            by_hash={facts[current]["sha256"]:[old,current],facts[helper]["sha256"]:[helper]}
            report={"schemaVersion":"mirmir-ash-v4-cpu-metal-parity-report-v3","contractSHA256":facts[current]["sha256"],"identities":{"chromaGeometryValidatorSHA256":facts[helper]["sha256"]}}
            binding=index.binding_for("/contractSHA256",report,paths,facts,root,by_hash,"cpu_metal_parity")
            self.assertEqual(Path(binding["path"]).name,current.name)
            binding=index.binding_for("/identities/chromaGeometryValidatorSHA256",report,paths,facts,root,by_hash,"cpu_metal_parity")
            self.assertEqual(Path(binding["path"]).name,helper.name)
            with self.assertRaises(index.AssemblyError):index.binding_for("/identities/chromaGeometryValidatorSHA256",report,paths-{helper},facts,root,by_hash,"cpu_metal_parity")
            with self.assertRaises(index.AssemblyError):index.binding_for("/contractSHA256",report,paths-{current},facts,root,by_hash,"cpu_metal_parity")


if __name__=="__main__":unittest.main()

#!/usr/bin/env python3
"""Explicitly execute one reviewed existing observer invocation; never notarize."""
from pathlib import Path
from datetime import datetime, timezone
import argparse, base64, importlib.util, json, os, subprocess, sys
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('smoke_request_builder', HERE / 'build_smoke_request.py')
builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--invocation', type=Path, required=True)
    parser.add_argument('--allow-app-owned-live-validation', action='store_true', help='Recover only, with an explicitly prepared fallback: retain external PermissionError and require successful app-owned phase-one seal and decoded-semantic equality checks.')
    parser.add_argument('--execute', action='store_true', help='Required explicit action after root review; without it this command only validates.')
    args = parser.parse_args(); invocation = args.invocation.resolve(strict=True); plan = invocation.parent
    record = builder.load(invocation); argv = record['argv']
    builder.require(len(argv) == 3 and argv[1] == builder.FLAG, 'unexpected executable command shape')
    data = base64.b64decode(argv[2], validate=True); request = json.loads(data)
    builder.require(builder.canonical(request) == data, 'request JSON is not canonical')
    phase = request['phase']; builder.require(phase in ('prepare', 'recover'), 'unexpected phase')
    owner_required = record.get('appOwnedLiveValidationRequired', False)
    builder.require(not args.allow_app_owned_live_validation or (phase == 'recover' and owner_required), 'app-owned live validation is allowed only for an explicitly prepared recover fallback')
    builder.require(not owner_required or args.allow_app_owned_live_validation, 'recover fallback requires explicit --allow-app-owned-live-validation')
    builder.require((plan / (phase + '-request.json')).read_bytes() == data, 'invocation/request file mismatch')
    generated = datetime.strptime(request['generatedAtUTC'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    builder.require(-30 <= (datetime.now(timezone.utc) - generated).total_seconds() <= 300, 'request stale: rebuild a fresh request before execution')
    reviewed = record['reviewedInputs']
    audit, inventory, manifest = builder.check_app(Path(argv[0]).parents[2], reviewed)
    builder.check_sources(manifest, request['sourceCommit'], Path(reviewed['repository']))
    builder.require(inventory == record['appFileInventory'], 'invocation app file inventory changed')
    for key in ('bundleIdentifier', 'productVersion', 'productBuild', 'runtimeManifestSHA256', 'runtimeManifestFileSHA256', 'laneContractSHA256', 'releaseContractSHA256'):
        builder.require(audit[key] == request[key], 'request identity differs from reviewed app: ' + key)
    archive = Path(record['actualApplicationArchive'])
    archive_sha = builder.check_zip(archive, Path(audit['app']), inventory)
    builder.require(archive_sha == request['applicationArchiveSHA256'] == record['actualApplicationArchiveSHA256'], 'actual local archive identity changed')
    builder.require(audit['executable'] == argv[0] and audit['executableSHA256'] == request['expectedExecutableSHA256'], 'app identity changed')
    builder.require(record['scope'] == audit['scope'], 'development-smoke scope changed')
    expected_root = Path.home() / 'Library/Containers' / request['bundleIdentifier'] / 'Data/Library/Application Support/MirmirQualificationV4/notarized-smoke' / request['requestID']
    builder.require(str(expected_root) == record['expectedQualificationRoot'], 'qualification root differs from request identity')
    prepare_result = None; prepare_live_error = None
    if phase == 'recover':
        prepare_bytes = (plan / 'prepare-result.json').read_bytes()
        builder.require(builder.sha(prepare_bytes) == request['phaseOneResultSHA256'] == record['phaseOneResultValidation']['phaseOneResultSHA256'], 'retained phase-one seal differs')
        prepare_request_bytes = (plan / 'prepare-request.json').read_bytes()
        prepare_result = builder.validate_observer_result(prepare_bytes, prepare_request_bytes, audit, expected_root)
        if owner_required:
            validation = record['phaseOneResultValidation']
            builder.require(validation['mode'] == 'app-owned-prepare-seal-required' and validation['externalLiveFileEqualityVerified'] is False and validation['externalLiveFileReadError'] is not None, 'explicit owner-validation declaration differs')
            retained, _, provenance = builder.retained_prepare_from_stdout(plan, Path(validation['explicitRetainedSource']), prepare_request_bytes, audit, expected_root)
            builder.require(retained == prepare_bytes and all(validation[key] == value for key, value in provenance.items()), 'retained fallback provenance changed')
        prepare_live, prepare_live_error = builder.read_live_result(expected_root / 'prepare-result.json')
        if prepare_live_error is None: builder.require(prepare_live == prepare_bytes, 'retained phase-one bytes differ from live prepare result')
        else: builder.require(owner_required and args.allow_app_owned_live_validation, 'external live prepare comparison is unavailable without explicit owner-validation mode')
    if not args.execute:
        print('Validated only; no app launch. Add --execute only after root review and gates finish.'); return
    for suffix in ['stdout.txt', 'stderr.txt', 'run.json', 'observer-result.json']:
        builder.require(not (plan / (phase + '-' + suffix)).exists(), 'prior run artifacts already exist; preserve them')
    environment = dict(os.environ); environment.update(record['environmentAdditions'])
    started = builder.utc()
    try:
        process = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, timeout=900, check=False)
        stdout, stderr, code, timed_out = process.stdout, process.stderr, process.returncode, False
    except subprocess.TimeoutExpired as error:
        stdout, stderr, code, timed_out = error.stdout or b'', error.stderr or b'', None, True
    builder.write_new(plan / (phase + '-stdout.txt'), stdout); builder.write_new(plan / (phase + '-stderr.txt'), stderr)
    run = {'scope': audit['scope'], 'startedAtUTC': started, 'finishedAtUTC': builder.utc(),
        'returnCode': code, 'timedOut': timed_out, 'executableSHA256': audit['executableSHA256'],
        'requestSHA256': builder.sha(data), 'sourceCommit': request['sourceCommit'],
        'runtimeSourceRevision': audit['runtimeSourceRevision'], 'notarizedProof': False,
        'distributionQualification': False, 'appSourceAndTestsModifiedByRunner': False,
        'allowAppOwnedLiveValidationExplicitlyRequested': args.allow_app_owned_live_validation,
        'prepareExternalLiveFileReadError': prepare_live_error}
    if phase == 'recover': run['phaseOneResultValidation'] = record['phaseOneResultValidation']
    try:
        builder.require(code == 0, 'observer process failed or timed out')
        result_bytes = builder.decode_observer_stdout(stdout)
        result = builder.validate_observer_result(result_bytes, data, audit, expected_root, prepare_result)
        live = expected_root / (phase + '-result.json')
        live_bytes, live_error = builder.read_live_result(live)
        run['externalLiveFileEqualityVerified'] = live_error is None
        run['externalLiveFileReadError'] = live_error
        if live_error is None: builder.require(live_bytes == result_bytes, 'stdout observer result differs from live sandbox result')
        else: builder.require(phase == 'recover' and owner_required and args.allow_app_owned_live_validation, 'external live result comparison is unavailable without explicit recover owner-validation mode')
        if phase == 'recover':
            run['phaseOneResultSHA256'] = result['phaseOneResultSHA256']
            run['appOwnedPhaseOneSealAuthenticated'] = True
            run['decodedSemanticEqualityVerified'] = result['referenceSemantic'] == result['recoveredSemantic'] == prepare_result['directOutputSemantic']
            run['prepareValidationCompletedThroughAppOwnedRecoverSeal'] = owner_required
        builder.write_new(plan / (phase + '-observer-result.json'), result_bytes)
        run['observerResultSHA256'] = builder.sha(result_bytes)
    except Exception as error:
        run['resultValidationError'] = str(error)
    builder.write_new(plan / (phase + '-run.json'), json.dumps(run, indent=2).encode() + b'\n')
    builder.require(code == 0 and 'observerResultSHA256' in run, 'observer invocation failed or timed out; retained stdout/stderr/run record')
    print('Local development-signed headless workflow smoke phase completed; not notarized proof: ' + phase)

if __name__ == '__main__':
    try: main()
    except Exception as error: raise SystemExit('Reviewed observer invocation refused or failed: ' + str(error))

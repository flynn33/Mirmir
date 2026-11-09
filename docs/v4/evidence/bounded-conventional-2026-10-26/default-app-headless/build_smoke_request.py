#!/usr/bin/env python3
"""Prepare truthful requests for an existing app observer; never launch an app."""
from pathlib import Path, PurePosixPath
from datetime import datetime, timezone
import argparse, base64, hashlib, importlib.util, json, os, plistlib, re, stat, subprocess, uuid, zipfile, secrets, sys
sys.dont_write_bytecode = True

ROOT = Path('/Volumes/DockCase/GitHub/Mirmir')
BASE = ROOT / 'output/resumed-qa-2026-10-25/conventional-preservation-bounded-01'
DEFAULT_APP = Path('/private/tmp/Mirmir-root-bounded-default-release-derived-20261025/Build/Products/Release/Mirmir.app')
SOURCE_MANIFEST = BASE / 'sealed-source-manifest.json'
BINDING = BASE / 'sealed-source-runtime-binding.json'
FILE_INVENTORY = BASE / 'sealed-default-release-file-inventory.json'
LANE_CONTRACT = ROOT / 'script/v4/notarized-smoke-contract-v1.json'
RELEASE_CONTRACT = ROOT / 'script/v4/release-qualification-contract-v1.json'
FLAG = '--mirmir-v4-notarized-smoke'
SCHEMA = 'mirmir-ash-v4-notarized-smoke-request-v1'

def require(value, message):
    if not value: raise ValueError(message)

def sha(data): return hashlib.sha256(data).hexdigest()
def file_sha(path): return sha(path.read_bytes())
def canonical(value): return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode('utf-8')
def foundation_canonical_result(raw):
    # Observer results use Foundation JSONSerialization, including NSNumber text.
    here = Path(__file__).resolve().parent
    process = subprocess.run(['/usr/bin/swift', '-module-cache-path', str(here / 'foundation-module-cache'),
        str(here / 'foundation_canonical_json.swift')], input=raw, capture_output=True, timeout=60)
    require(process.returncode == 0, 'native Foundation result canonicalization failed: ' + process.stderr.decode(errors='replace'))
    return process.stdout
def load(path): return json.loads(path.read_bytes())
def write_new(path, data):
    with path.open('xb') as handle: handle.write(data)
def utc(): return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
def git(*arguments, input=None, repository=ROOT):
    process = subprocess.run(['git', '-C', str(repository), *arguments], input=input, capture_output=True)
    require(process.returncode == 0, 'Git read failed: ' + process.stderr.decode(errors='replace'))
    return process.stdout

def check_sources(manifest, source_commit=None, repository=ROOT):
    repository = repository.resolve(strict=True)
    spec = importlib.util.spec_from_file_location('smoke_source_identity', repository / 'script/v4/p06_source_identity_v4.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    rows = manifest['sources']; require(len(rows) == manifest['sourceCount'] == 411, 'source closure count changed')
    if source_commit is not None:
        require(re.fullmatch('[0-9a-f]{40}', source_commit), 'sourceCommit must be the full actual 40-character Git commit, not a truncated source fingerprint')
        resolved = git('rev-parse', '--verify', source_commit + '^{commit}', repository=repository).decode().strip()
        require(resolved == source_commit, 'sourceCommit is not an existing exact commit')
        data = git('cat-file', '--batch', input=''.join(source_commit + ':' + row['path'] + '\n' for row in rows).encode(), repository=repository)
        blobs = []; offset = 0
        for row in rows:
            end = data.index(b'\n', offset); header = data[offset:end].split(); offset = end + 1
            require(len(header) == 3 and header[1] == b'blob', 'committed source absent: ' + row['path'])
            size = int(header[2]); blobs.append(data[offset:offset + size]); offset += size
            require(data[offset:offset + 1] == b'\n', 'invalid Git batch delimiter'); offset += 1
        require(offset == len(data), 'extra Git batch output')
    else: blobs = [(repository / row['path']).read_bytes() for row in rows]
    digest = hashlib.sha256(manifest['identityDomain'].encode() + b'\0' + bytes.fromhex(manifest['contractSemanticSHA256']))
    for row, raw in zip(rows, blobs):
        require(sha(raw) == row['sha256'], ('commit' if source_commit else 'working tree') + ' production bytes differ from retained source manifest: ' + row['path'])
        normalized = raw
        if row['normalizations']:
            normalized, names = module.normalize_trust_roots(raw)
            require(names == row['normalizations'], 'trust-root normalization list changed')
        require(sha(normalized) == row['normalizedSHA256'], 'normalized source digest differs: ' + row['path'])
        encoded = row['path'].encode(); digest.update(len(encoded).to_bytes(4, 'big')); digest.update(encoded)
        digest.update(len(normalized).to_bytes(8, 'big')); digest.update(normalized)
    require(digest.hexdigest() == manifest['sourceRevision'], 'production source identity recomputation differs')
    return {'sourceCount': len(rows), 'sourceRevision': digest.hexdigest(), 'commitVerified': source_commit is not None}

INPUT_KEYS = ('sourceManifest', 'runtimeBinding', 'appFileInventory', 'laneContract', 'releaseContract')

def capture_reviewed_inputs(repository, source_manifest, runtime_binding, app_file_inventory, lane_contract, release_contract):
    repository = repository.resolve(strict=True)
    require(repository.is_dir(), 'reviewed repository is not a directory')
    files = {}
    for key, path in zip(INPUT_KEYS, (source_manifest, runtime_binding, app_file_inventory, lane_contract, release_contract)):
        require(path.is_file() and not path.is_symlink(), 'reviewed input is not a regular nonsymlink file: ' + str(path))
        path = path.resolve(strict=True)
        files[key] = {'path': str(path), 'sha256': file_sha(path)}
    return {'repository': str(repository), 'files': files}

def validate_reviewed_inputs(reviewed):
    require(set(reviewed) == {'repository', 'files'} and set(reviewed['files']) == set(INPUT_KEYS), 'reviewed input identity record is incomplete')
    repository = Path(reviewed['repository'])
    require(repository.is_absolute() and repository.resolve(strict=True) == repository and repository.is_dir(), 'reviewed repository path changed')
    paths = {}
    for key in INPUT_KEYS:
        entry = reviewed['files'][key]
        require(set(entry) == {'path', 'sha256'}, 'reviewed input record shape changed: ' + key)
        path = Path(entry['path'])
        require(path.is_absolute() and path.is_file() and not path.is_symlink() and path.resolve(strict=True) == path, 'reviewed input path changed: ' + key)
        require(file_sha(path) == entry['sha256'], 'reviewed input bytes changed: ' + key)
        paths[key] = path
    return repository, paths

def check_app(app, reviewed):
    repository, paths = validate_reviewed_inputs(reviewed)
    app = app.resolve(strict=True)
    inventory_record = load(paths['appFileInventory'])
    require(app.is_dir() and str(app) == inventory_record['path'], 'application path differs from the retained app file inventory')
    inventory = inventory_record['files']
    actual = {}
    for path in app.rglob('*'):
        require(not path.is_symlink(), 'application contains a symlink: ' + str(path))
        if path.is_file(): actual[path.relative_to(app).as_posix()] = file_sha(path)
    require(actual == inventory, 'default app bytes differ from the retained app file inventory')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    runtime_path = app / 'Contents/Resources/ASH-P06.bundle/runtime-manifest.json'
    runtime = load(runtime_path); binding = load(paths['runtimeBinding']); source_manifest = load(paths['sourceManifest'])
    runtime_canonical = sha(b'ash-p06-runtime-manifest-v4\0' + canonical(runtime))
    require(runtime_canonical == binding['manifestSHA256'], 'embedded canonical runtime identity differs')
    require(runtime['provenance']['sourceRevision'] == binding['sourceRevision'] == source_manifest['sourceRevision'], 'embedded source identity differs')
    require(runtime['provenance']['builderSourceSHA256'] == binding['builderSourceSHA256'], 'embedded builder identity differs')
    require(runtime['releaseStatus'] == 'release_qualified', 'existing observer requires the embedded manifest declaration release_qualified')
    signing = subprocess.run(['/usr/bin/codesign', '--display', '--entitlements', '-', '--xml', str(app)], capture_output=True)
    require(signing.returncode == 0, 'cannot read actual signing entitlements')
    entitlements = plistlib.loads(signing.stdout)
    require(entitlements.get('com.apple.security.app-sandbox') is True, 'existing observer requires app sandbox')
    require(entitlements.get('com.apple.security.get-task-allow') is True, 'reviewed development signing identity changed; inspect before reusing this plan')
    signature = subprocess.run(['/usr/bin/codesign', '--display', '--verbose=4', str(app)], capture_output=True, text=True)
    require(signature.returncode == 0, 'cannot read code signature identity')
    authorities = re.findall(r'^Authority=(.+)$', signature.stdout + signature.stderr, flags=re.MULTILINE)
    require(authorities and authorities[0].startswith('Apple Development:'), 'reviewed Apple Development signing authority changed')
    audit = {
        'scope': 'development-signed headless workflow smoke; not notarized or distribution qualification',
        'app': str(app), 'executable': str(executable), 'executableSHA256': file_sha(executable),
        'bundleIdentifier': info['CFBundleIdentifier'], 'productVersion': info['CFBundleShortVersionString'], 'productBuild': info['CFBundleVersion'],
        'runtimeManifestSHA256': runtime_canonical, 'runtimeManifestFileSHA256': file_sha(runtime_path),
        'runtimeSourceRevision': binding['sourceRevision'], 'embeddedRuntimeReleaseStatusDeclaration': runtime['releaseStatus'],
        'signatureAuthorities': authorities, 'signatureDisplay': signature.stdout + signature.stderr,
        'entitlements': entitlements, 'releaseProvenanceClaims': {key: value for key, value in info.items() if key.startswith('MirmirV4')},
        'laneContract': str(paths['laneContract']), 'laneContractSHA256': file_sha(paths['laneContract']),
        'releaseContract': str(paths['releaseContract']), 'releaseContractSHA256': file_sha(paths['releaseContract']),
        'sourceManifest': str(paths['sourceManifest']), 'sourceManifestFileSHA256': file_sha(paths['sourceManifest']),
        'binding': str(paths['runtimeBinding']), 'bindingFileSHA256': file_sha(paths['runtimeBinding']),
        'fileInventory': str(paths['appFileInventory']), 'fileInventorySHA256': file_sha(paths['appFileInventory']),
        'reviewedInputs': reviewed,
        'notarizationAssessed': False, 'distributionSigningAssessed': False, 'independentReleaseQualificationAssessed': False,
    }
    return audit, actual, source_manifest

def check_zip(path, app, inventory):
    require(path.is_file() and not path.is_symlink(), 'a real local ZIP is required; no placeholder archive identity is accepted')
    contents = {}; prefix = app.name + '/'
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist(); require(len(names) == len(set(names)), 'ZIP has duplicate entry names')
        for item in archive.infolist():
            pure = PurePosixPath(item.filename)
            require(not pure.is_absolute() and '..' not in pure.parts, 'unsafe ZIP path')
            if item.is_dir() or item.filename.startswith('__MACOSX/'): continue
            require(item.filename.startswith(prefix), 'ZIP contains an unexpected top-level file')
            require(stat.S_IFMT(item.external_attr >> 16) in (0, stat.S_IFREG), 'ZIP contains a non-regular file')
            contents[item.filename[len(prefix):]] = sha(archive.read(item))
    require(contents == inventory, 'ZIP application bytes do not exactly match the reviewed default app')
    return file_sha(path)

RESULT_SCHEMA = 'mirmir-ash-v4-notarized-smoke-observer-result-v1'
EXPECTED_CHECKS = {
    'prepare': {'shippingExecutableIdentity', 'sandboxIsolation', 'productionP06Load', 'realMediaProbe', 'deterministicCPUProcess', 'durableCheckpointPause', 'userQueueUntouched'},
    'recover': {'shippingExecutableIdentity', 'sandboxIsolation', 'productionP06Load', 'phaseOneSealReplayVerified', 'durableQueueReopened', 'checkpointResumeCompleted', 'decodedSemanticEquality', 'userQueueUntouched'},
}

def decode_observer_stdout(stdout):
    prefix = b'MIRMIR_V4_NOTARIZED_SMOKE_RESULT '
    require(stdout.startswith(prefix) and stdout.endswith(b'\n') and stdout.count(b'\n') == 1, 'observer stdout marker shape differs')
    return base64.b64decode(stdout[len(prefix):-1], validate=True)

def read_live_result(path):
    try:
        require(path.is_file() and not path.is_symlink(), 'live result is absent or unsafe: ' + str(path))
        return path.read_bytes(), None
    except PermissionError as error:
        return None, {'path': str(path), 'errno': error.errno, 'error': str(error)}

def validate_observer_result(raw, request_bytes, audit, qualification, prepare_result=None):
    require(foundation_canonical_result(raw) == raw, 'observer result is not Foundation canonical JSON')
    result = json.loads(raw); request = json.loads(request_bytes); phase = request['phase']
    require(result['schemaVersion'] == RESULT_SCHEMA, 'observer result schema differs')
    for key in ('phase', 'requestID', 'sourceCommit', 'applicationArchiveSHA256'):
        require(result[key] == request[key], 'observer result/request identity differs: ' + key)
    require(result['requestSHA256'] == sha(request_bytes), 'observer result request seal differs')
    require(result['resultFileName'] == phase + '-result.json', 'observer result filename differs')
    for key in ('bundleIdentifier', 'productVersion', 'productBuild'):
        require(result['process'][key] == request[key] == audit[key], 'observer process identity differs: ' + key)
    require(result['process']['executableSHA256'] == request['expectedExecutableSHA256'] == audit['executableSHA256'], 'observer executable identity differs')
    require(Path(result['process']['executablePath']).resolve() == Path(audit['executable']).resolve(), 'observer executable path differs')
    require(Path(result['process']['bundlePath']).resolve() == Path(audit['app']).resolve(), 'observer app path differs')
    require(result['process']['qualificationRootPath'] == str(qualification), 'observer qualification root differs')
    for field, key in [('manifestSHA256', 'runtimeManifestSHA256'), ('manifestFileSHA256', 'runtimeManifestFileSHA256'), ('sourceRevision', 'runtimeSourceRevision')]:
        require(result['runtime'][field] == audit[key], 'observer runtime identity differs: ' + field)
    require(set(result['checks']) == EXPECTED_CHECKS[phase] and all(value is True for value in result['checks'].values()), 'observer checks differ or contain a nontrue result')
    if phase == 'recover':
        require(prepare_result is not None, 'recover validation requires the authenticated retained prepare result')
        require(result['phaseOneResultSHA256'] == request['phaseOneResultSHA256'], 'recover phase-one result seal differs')
        require(result['referenceSemantic'] == result['recoveredSemantic'] == prepare_result['directOutputSemantic'], 'recover decoded pixels/timing differ from prepare')
        require(result['artifacts']['directOutput'] == prepare_result['artifacts']['directOutput'], 'recover direct artifact differs from prepare')
        require(result['artifacts']['phaseOneState'] == prepare_result['artifacts']['phaseOneState'], 'recover phase-one state artifact differs')
        queue = result['queue']
        require(queue['jobID'] == prepare_result['queue']['jobID'] and queue['phaseOneQueueTreeSHA256'] == prepare_result['queue']['queueTreeSHA256'], 'recover queue identity differs from prepare')
        require(queue['launchLifecycle'] == 'paused' and queue['finalLifecycle'] == 'completed' and queue['launchRecoveryItemCount'] == 1 and queue['launchRecoveryStatus'] == 'idle' and queue['launchRecoveryObservedLifecycle'] == 'paused' and queue['launchRecoveryPresentedLifecycle'] == 'paused' and queue['launchRecoveryResumable'] is True and queue['launchRecoveryContainedFailureCount'] == 0, 'recover queue lifecycle differs')
        for key in ('actualBackendID', 'encodedHeight', 'encodedWidth', 'outputCodec', 'processedFrameCount'):
            require(result['resumedProcess'][key] == prepare_result['deterministicProcess'][key], 'recover processing identity differs: ' + key)
    return result

def retained_prepare_from_stdout(plan, supplied_path, request_bytes, audit, qualification):
    require(supplied_path.is_file() and not supplied_path.is_symlink(), 'explicit retained prepare source is absent or unsafe')
    supplied_path = supplied_path.resolve(strict=True); supplied = supplied_path.read_bytes()
    raw = decode_observer_stdout(supplied) if supplied.startswith(b'MIRMIR_V4_NOTARIZED_SMOKE_RESULT ') else supplied
    stdout_path = plan / 'prepare-stdout.txt'; run_path = plan / 'prepare-run.json'; invocation_path = plan / 'prepare-invocation.json'
    require(raw == decode_observer_stdout(stdout_path.read_bytes()), 'explicit prepare bytes differ from original retained stdout')
    run = load(run_path); invocation = load(invocation_path)
    require(run['returnCode'] == 0 and run['timedOut'] is False, 'original prepare app process did not exit successfully')
    require(run['requestSHA256'] == sha(request_bytes) and run['executableSHA256'] == audit['executableSHA256'], 'original prepare process identity differs')
    require(invocation['reviewedInputs'] == audit['reviewedInputs'], 'original prepare reviewed inputs differ')
    require(invocation['argv'][0] == audit['executable'] and invocation['argv'][1] == FLAG and base64.b64decode(invocation['argv'][2], validate=True) == request_bytes, 'original prepare invocation differs')
    result = validate_observer_result(raw, request_bytes, audit, qualification)
    return raw, result, {'explicitRetainedSource': str(supplied_path), 'explicitRetainedSourceSHA256': sha(supplied),
        'originalPrepareStdoutSHA256': file_sha(stdout_path), 'originalPrepareRunSHA256': file_sha(run_path),
        'originalPrepareInvocationSHA256': file_sha(invocation_path), 'phaseOneResultSHA256': sha(raw)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['audit', 'prepare', 'recover'])
    parser.add_argument('--app', type=Path, default=DEFAULT_APP)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--repository', type=Path, default=ROOT)
    parser.add_argument('--source-manifest', type=Path, default=SOURCE_MANIFEST)
    parser.add_argument('--runtime-binding', type=Path, default=BINDING)
    parser.add_argument('--app-file-inventory', type=Path, default=FILE_INVENTORY)
    parser.add_argument('--lane-contract', type=Path, default=LANE_CONTRACT)
    parser.add_argument('--release-contract', type=Path, default=RELEASE_CONTRACT)
    parser.add_argument('--source-commit')
    parser.add_argument('--phase-one-result-from-stdout', type=Path, help='Recover only: explicitly use retained original successful prepare stdout/raw bytes when external live reading returns PermissionError; the app must authenticate its own live seal.')
    parser.add_argument('--plan-dir', type=Path, required=True)
    args = parser.parse_args(); app = args.app.resolve(strict=True); plan = args.plan_dir.resolve()
    require(args.phase == 'recover' or args.phase_one_result_from_stdout is None, 'explicit retained prepare source is allowed only for recover')
    reviewed = capture_reviewed_inputs(args.repository, args.source_manifest, args.runtime_binding, args.app_file_inventory, args.lane_contract, args.release_contract)
    audit, inventory, manifest = check_app(app, reviewed)
    audit['sourceVerification'] = check_sources(manifest, args.source_commit, Path(reviewed['repository']))
    if args.phase == 'audit':
        require(not plan.exists(), 'audit output already exists')
        plan.mkdir(mode=0o700, parents=True)
        audit['notYetInvocableReasons'] = ['audit mode does not produce a request or verify a local ZIP']
        if args.source_commit is None: audit['notYetInvocableReasons'].append('exact committed production source not supplied and verified')
        write_new(plan / 'identity-audit.json', json.dumps(audit, indent=2).encode() + b'\n')
        print('Audit only; no request or app invocation generated: ' + str(plan)); return
    require(args.archive is not None and args.source_commit is not None, 'prepare/recover require an actual verified ZIP and actual committed source')
    archive = args.archive.resolve(strict=True); archive_sha = check_zip(archive, app, inventory)
    audit.update({'applicationArchive': str(archive), 'applicationArchiveSHA256': archive_sha, 'sourceCommit': args.source_commit})
    if args.phase == 'prepare':
        require(not plan.exists(), 'prepare plan directory already exists; preserve it and choose a new plan directory')
        request_id = str(uuid.uuid4()); nonce = secrets.token_hex(32)
        plan.mkdir(mode=0o700, parents=True)
        request = {'schemaVersion': SCHEMA, 'phase': 'prepare', 'requestID': request_id, 'nonce': nonce,
            'generatedAtUTC': utc(), 'laneContractSHA256': audit['laneContractSHA256'],
            'releaseContractSHA256': audit['releaseContractSHA256'], 'applicationArchiveSHA256': archive_sha,
            'sourceCommit': args.source_commit, 'bundleIdentifier': audit['bundleIdentifier'],
            'productVersion': audit['productVersion'], 'productBuild': audit['productBuild'],
            'runtimeManifestSHA256': audit['runtimeManifestSHA256'],
            'runtimeManifestFileSHA256': audit['runtimeManifestFileSHA256'],
            'expectedExecutableSHA256': audit['executableSHA256']}
        # Swift synthesized Encodable omits the nil phaseOneResultSHA256 key.
    else:
        require(plan.is_dir(), 'prepare plan directory does not exist')
        prepare_invocation = load(plan / 'prepare-invocation.json')
        require(prepare_invocation['reviewedInputs'] == reviewed, 'reviewed input paths or bytes differ from prepare')
        request = load(plan / 'prepare-request.json')
        for key, expected in [('applicationArchiveSHA256', archive_sha), ('sourceCommit', args.source_commit),
            ('expectedExecutableSHA256', audit['executableSHA256']), ('runtimeManifestSHA256', audit['runtimeManifestSHA256']),
            ('runtimeManifestFileSHA256', audit['runtimeManifestFileSHA256']), ('bundleIdentifier', audit['bundleIdentifier']),
            ('productVersion', audit['productVersion']), ('productBuild', audit['productBuild']),
            ('laneContractSHA256', audit['laneContractSHA256']), ('releaseContractSHA256', audit['releaseContractSHA256'])]:
            require(request[key] == expected, 'prepare identity changed: ' + key)
    qualification = Path.home() / 'Library/Containers' / audit['bundleIdentifier'] / 'Data/Library/Application Support/MirmirQualificationV4/notarized-smoke' / request['requestID']
    audit['expectedQualificationRoot'] = str(qualification)
    if args.phase == 'prepare': require(not qualification.exists(), 'qualification UUID root already exists')
    else:
        prepare_request_bytes = (plan / 'prepare-request.json').read_bytes()
        require(canonical(request) == prepare_request_bytes, 'retained prepare request is not canonical')
        result_path = qualification / 'prepare-result.json'
        live_bytes, live_error = read_live_result(result_path)
        validation = {'externalLiveFileEqualityVerified': live_error is None, 'externalLiveFileReadError': live_error,
            'phaseOneSealAuthenticatedByRecover': False, 'completePrepareClaim': False}
        if args.phase_one_result_from_stdout is not None:
            result_bytes, result, provenance = retained_prepare_from_stdout(plan, args.phase_one_result_from_stdout, prepare_request_bytes, audit, qualification)
            if live_error is None: require(result_bytes == live_bytes, 'explicit retained prepare result differs from live file')
            validation.update(provenance)
            validation['mode'] = 'app-owned-prepare-seal-required' if live_error is not None else 'external-live-prepare-equality-verified'
        else:
            require(live_error is None, 'external live prepare read failed; explicit --phase-one-result-from-stdout is required: ' + str(live_error))
            result_bytes = live_bytes
            result = validate_observer_result(result_bytes, prepare_request_bytes, audit, qualification)
            validation.update({'mode': 'external-live-prepare-equality-verified', 'phaseOneResultSHA256': sha(result_bytes)})
        audit['phaseOneResultValidation'] = validation
        request['phase'] = 'recover'; request['generatedAtUTC'] = utc(); request['phaseOneResultSHA256'] = sha(result_bytes)
        write_new(plan / 'prepare-result.json', result_bytes)
    data = canonical(request)
    write_new(plan / (args.phase + '-request.json'), data)
    invocation = {'scope': audit['scope'], 'argv': [audit['executable'], FLAG, base64.b64encode(data).decode('ascii')],
        'environmentAdditions': {'NSUnbufferedIO': 'YES'}, 'expectedExecutableSHA256': audit['executableSHA256'],
        'generatedAtUTC': request['generatedAtUTC'], 'maximumRequestAgeSeconds': 300,
        'expectedQualificationRoot': str(qualification), 'expectedPhase': args.phase, 'sourceCommit': args.source_commit,
        'actualApplicationArchive': str(archive), 'actualApplicationArchiveSHA256': archive_sha,
        'runtimeSourceRevision': audit['runtimeSourceRevision'], 'appFileInventory': inventory, 'reviewedInputs': reviewed}
    if args.phase == 'recover':
        invocation['phaseOneResultValidation'] = validation
        invocation['appOwnedLiveValidationRequired'] = validation['mode'] == 'app-owned-prepare-seal-required'
    write_new(plan / (args.phase + '-invocation.json'), json.dumps(invocation, indent=2).encode() + b'\n')
    write_new(plan / (args.phase + '-identity-audit.json'), json.dumps(audit, indent=2).encode() + b'\n')
    print('Prepared only; app NOT launched: ' + str(plan / (args.phase + '-invocation.json')))

if __name__ == '__main__':
    try: main()
    except Exception as error: raise SystemExit('Smoke request preparation refused: ' + str(error))

from pathlib import Path
from fractions import Fraction
import subprocess, json, re, hashlib, sys

attachments = Path(sys.argv[1])
destination = Path(sys.argv[2])
original_checker = Path('/private/tmp/mirmir-selected-primary-independent-media-20261026.py')
sha = lambda data: hashlib.sha256(data).hexdigest()

def run(arguments):
    result = subprocess.run(arguments, capture_output=True)
    assert result.returncode == 0, (arguments, result.stderr.decode(errors='replace'))
    return result.stdout

def probe(path, raw=False):
    return json.loads(run(['/opt/homebrew/bin/ffprobe', '-v', 'error',
        *(['-ignore_editlist', '1'] if raw else []), '-show_streams', '-show_format',
        '-show_packets', '-show_data_hash', 'sha256', '-of', 'json', str(path)]))

def packets(data, index):
    stream = data['streams'][index]
    clock = Fraction(stream['time_base'])
    return [{**{key: packet.get(key) for key in ['size', 'data_hash']},
             **{key: Fraction(int(packet[key])) * clock if key in packet else None
                for key in ['pts', 'dts', 'duration']}}
            for packet in data['packets'] if packet['stream_index'] == stream['index']]

def decode(path, index, video=False, raw=False):
    return run(['/opt/homebrew/bin/ffmpeg', '-v', 'error',
        *(['-ignore_editlist', '1'] if raw else []), '-i', str(path), '-map', '0:' + str(index),
        *(['-fps_mode', 'passthrough', '-pix_fmt', 'yuv420p', '-f', 'rawvideo']
          if video else ['-c:a', 'pcm_s32le', '-f', 's32le']), '-'])

groups = {}
for test in json.loads((attachments / 'manifest.json').read_text()):
    if 'SelectedMovingPrimary' not in test['testIdentifier']:
        continue
    for attachment in test['attachments']:
        match = re.fullmatch(r'(.+)-(source|output)_(\d+)_[A-Fa-f0-9-]+\.mov',
                             attachment['suggestedHumanReadableName'])
        if match:
            groups.setdefault((test['testIdentifier'], match[1], match[3]), {})[match[2]] = (
                attachments / attachment['exportedFileName'])

rows = []
reference_pictures = None
for (test, name, instance), pair in sorted(groups.items()):
    assert set(pair) == {'source', 'output'}
    source = probe(pair['source'])
    output = probe(pair['output'])
    source_raw = probe(pair['source'], True)
    output_raw = probe(pair['output'], True)
    preserve_audio = '-audio-true' in name
    retained = [(index, stream) for index, stream in enumerate(source['streams'])
                if preserve_audio or stream['codec_type'] != 'audio']
    output_streams = output['streams']
    raw_packets = packets(output_raw, 0)
    source_packets = packets(source_raw, 0)
    pictures = decode(pair['output'], 0, True, True)
    frame_bytes = output_streams[0]['width'] * output_streams[0]['height'] * 3 // 2
    if reference_pictures is None:
        reference_pictures = pictures
    presentation_source = packets(source, 0)
    presentation_output = packets(output, 0)
    checks = {
        'trackCountAndOrder': len(retained) == len(output_streams)
            and [stream['codec_type'] for _, stream in retained]
            == [stream['codec_type'] for stream in output_streams],
        'completeStored72FrameDecode': len(pictures) == 72 * frame_bytes,
        'stored72PacketCount': len(raw_packets) == 72,
        'storedPresentationTimesExact': sorted(packet['pts'] for packet in raw_packets)
            == sorted(packet['pts'] for packet in source_packets),
        'storedDecodeCadenceExact': [packet['dts'] for packet in raw_packets]
            == [Fraction(index, 24) for index in range(72)],
        'storedDurationsExact': all(packet['duration'] == Fraction(1, 24)
                                    for packet in raw_packets),
    }
    # Re-encoded H.264 packet ordering and exact cross-run decoded bytes are
    # observations. They are not stored-media timing or PCM acceptance checks.
    measurements = {
        'decodedFullMediaPicturesMatchFirstOutput': pictures == reference_pictures,
        'decodedStoredPicturesSHA256': sha(pictures),
        'decodedStoredFrameSHA256': [sha(pictures[index:index + frame_bytes])
                                     for index in range(0, len(pictures), frame_bytes)],
        'presentationPacketPTSInDemuxOrderMatchSource':
            [packet['pts'] for packet in presentation_output]
            == [packet['pts'] for packet in presentation_source],
        'presentationSortedPacketPTSMultisetMatchSource':
            sorted(packet['pts'] for packet in presentation_output)
            == sorted(packet['pts'] for packet in presentation_source),
        'sourcePresentationPacketCount': len(presentation_source),
        'outputPresentationPacketCount': len(presentation_output),
    }
    for output_index, (source_index, stream) in enumerate(retained):
        if source_index == 0:
            continue
        if stream['codec_type'] == 'video':
            checks['untouchedVideo' + str(source_index) + 'StoredPacketsExact'] = (
                packets(source_raw, source_index) == packets(output_raw, output_index))
        elif stream['codec_type'] == 'audio':
            checks['audio' + str(source_index) + 'PCMExact'] = (
                decode(pair['source'], source_index) == decode(pair['output'], output_index))
    checks['titlePreserved'] = (source['format'].get('tags', {}).get('title')
                                == output['format'].get('tags', {}).get('title'))
    rows.append({
        'test': test, 'case': name, 'instance': instance,
        'sourceSHA256': sha(pair['source'].read_bytes()),
        'outputSHA256': sha(pair['output'].read_bytes()),
        'checks': checks, 'measurements': measurements,
        'decodedStoredFrames': len(pictures) // frame_bytes,
        'creationDatePreserved': source['format'].get('tags', {}).get('creation_time')
            == output['format'].get('tags', {}).get('creation_time'),
    })
result = {
    'schema': 'selected-primary-independent-stored-media-v2',
    'pairs': len(rows),
    'allStoredMediaChecksPass': bool(rows) and all(all(row['checks'].values()) for row in rows),
    'scope': 'Stored sample inventory, rational clock, decoded count, retained stream payloads, PCM and title checks. Presentation demux order and cross-output decoded bytes are measurements. Native presentation-pair proof is retained separately.',
    'outputs': rows,
    'checkerSHA256': sha(Path(__file__).read_bytes()),
    'originalCheckerSHA256': sha(original_checker.read_bytes()),
}
destination.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({
    'pairs': len(rows), 'allStoredMediaChecksPass': result['allStoredMediaChecksPass'],
    'failures': {row['test'] + ':' + row['case']: [key for key, value in row['checks'].items() if not value]
                 for row in rows if not all(row['checks'].values())},
    'crossOutputDecodedByteVariations': [row['test'] + ':' + row['case'] for row in rows
        if not row['measurements']['decodedFullMediaPicturesMatchFirstOutput']],
}, indent=2))

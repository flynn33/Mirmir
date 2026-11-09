import hashlib,json,tarfile
from pathlib import Path
root=Path(__file__).resolve().parent;source=root/'ffmpeg-8.1.2';expected={};actual={}
with tarfile.open(root/'downloads/ffmpeg-8.1.2.tar.xz','r:xz') as tar:
 for entry in tar:
  if entry.isfile():expected[str(Path(entry.name).relative_to('ffmpeg-8.1.2'))]=hashlib.sha256(tar.extractfile(entry).read()).hexdigest()
for p in source.rglob('*'):
 if p.is_file() and not p.is_symlink():actual[str(p.relative_to(source))]=hashlib.sha256(p.read_bytes()).hexdigest()
report={'sourceMatchesAuthenticatedOfficialArchive':actual==expected,'officialFileCount':len(expected),'localFileCount':len(actual),'added':sorted(set(actual)-set(expected)),'missing':sorted(set(expected)-set(actual)),'changed':sorted(k for k in set(expected)&set(actual) if expected[k]!=actual[k]),'sourceFileSHA256':actual}
(root/'source-tree-audit.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k!='sourceFileSHA256'}));assert report['sourceMatchesAuthenticatedOfficialArchive']

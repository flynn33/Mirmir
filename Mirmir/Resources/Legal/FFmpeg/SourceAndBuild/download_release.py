import hashlib,json,urllib.request
from pathlib import Path
root=Path(__file__).resolve().parent;directory=root/'downloads';directory.mkdir(exist_ok=True);report=[]
for url,name in [('https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz','ffmpeg-8.1.2.tar.xz'),('https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz.asc','ffmpeg-8.1.2.tar.xz.asc'),('https://ffmpeg.org/ffmpeg-devel.asc','ffmpeg-devel.asc')]:
 target=directory/name
 if not target.exists():
  with urllib.request.urlopen(url,timeout=60) as response:body=response.read()
  target.write_bytes(body)
 body=target.read_bytes();report.append({'url':url,'file':name,'bytes':len(body),'sha256':hashlib.sha256(body).hexdigest()})
(root/'download-manifest.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))

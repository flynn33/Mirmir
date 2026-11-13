from pathlib import Path
from fractions import Fraction
import json,re,subprocess,hashlib
root=Path('/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01');attachments=root/'sealed-media-attachments'
sha=lambda b:hashlib.sha256(b).hexdigest()
def run(a):
 r=subprocess.run(a,capture_output=True);assert r.returncode==0,(a,r.stderr.decode(errors='replace'));return r.stdout
def probe(p):return json.loads(run(['/opt/homebrew/bin/ffprobe','-v','error',*(['-ignore_editlist','1'] if p.suffix.lower() != '.avi' else []),'-show_streams','-show_format','-show_packets','-show_data_hash','sha256','-of','json',str(p)]))
def decode(p,index,video):return run(['/opt/homebrew/bin/ffmpeg','-v','error',*(['-ignore_editlist','1'] if p.suffix.lower() != '.avi' else []),'-i',str(p),'-map','0:'+str(index),*(['-fps_mode','passthrough','-pix_fmt','yuv420p','-f','rawvideo']if video else['-c:a','pcm_s16le','-f','s16le']),'-'])
rows=[]
for test in json.loads((attachments/'manifest.json').read_text()):
 name=test['testIdentifier'];temporal='CPUTemporal'in name
 if not temporal and not any(x in name for x in ['testNativeMPEG4AVI','testNativeH264AVI','testProgressiveJFIFMovieCompletes']):continue
 pairs={}
 for a in test['attachments']:
  m=re.search(r'-(source|output|resolved)_\d+_[A-Fa-f0-9-]+\.',a['suggestedHumanReadableName'])
  if m:pairs[m[1]]=attachments/a['exportedFileName']
 assert {'source','output'}<=set(pairs),(name,pairs)
 out=probe(pairs['output']);video=[s for s in out['streams']if s['codec_type']=='video'];assert len(video)==1;s=video[0];packets=[p for p in out['packets']if p['stream_index']==s['index']];clock=Fraction(s['time_base']);pts=[int(p['pts'])*clock for p in packets];dts=[int(p['dts'])*clock for p in packets];durations=[int(p['duration'])*clock for p in packets];expected=5 if temporal else 72;step=Fraction(1,60)if temporal else Fraction(1,24);expectedDurations=[step]*(expected-1)+[Fraction(1,30)if temporal else step];pictures=decode(pairs['output'],s['index'],True);frameBytes=s['width']*s['height']*3//2
 checks={'packetCountExact':len(packets)==expected,'storedPresentationTimesExact':sorted(pts)==[i*step for i in range(expected)],'storedDurationsExact':durations==expectedDurations,'completeDecodedFrameCount':len(pictures)==expected*frameBytes,'targetRaster':(s['width'],s['height'])==(128,96),'formatDurationExact':Fraction(out['format']['duration'])==(Fraction(1,10)if temporal else 3)}
 if temporal:checks['decodeTimesExact']=dts==pts==[i*step for i in range(expected)]
 audio=[a for a in out['streams']if a['codec_type']=='audio'];checks['audioInventoryExact']=len(audio)==(0 if temporal else 1)
 if not temporal:
  source=probe(pairs['source']);sa=[a for a in source['streams']if a['codec_type']=='audio'];assert len(sa)==1;pcm=decode(pairs['source'],sa[0]['index'],False);opcm=decode(pairs['output'],audio[0]['index'],False);checks['pcm144000FramesExact']=len(pcm)==288000 and opcm==pcm
 rows.append({'test':name,'checks':checks,'files':{k:{'path':str(v),'sha256':sha(v.read_bytes())}for k,v in pairs.items()},'codec':s['codec_name'],'packets':len(packets),'storedPacketDurations':[str(x)for x in durations],'decodedFrames':len(pictures)//frameBytes,'decodedPicturesSHA256':sha(pictures),'rFrameRate':s.get('r_frame_rate'),'averageFrameRate':s.get('avg_frame_rate')})
assert len(rows)==8,len(rows)
r={'outputs':rows,'allChecksPass':all(all(x['checks'].values())for x in rows),'checkerSHA256':sha(Path(__file__).read_bytes())};(root/'sealed-format-and-tail-independent-media.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps({'outputs':len(rows),'allChecksPass':r['allChecksPass'],'failures':{x['test']:[k for k,v in x['checks'].items()if not v]for x in rows if not all(x['checks'].values())}},indent=2))

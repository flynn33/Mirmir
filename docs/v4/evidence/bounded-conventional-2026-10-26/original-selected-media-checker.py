from pathlib import Path
from fractions import Fraction
import subprocess,json,re,hashlib,sys
attachments=Path(sys.argv[1]);destination=Path(sys.argv[2]);sha=lambda b:hashlib.sha256(b).hexdigest()
def run(args):
 r=subprocess.run(args,capture_output=True);assert r.returncode==0,(args,r.stderr.decode(errors='replace'));return r.stdout
def probe(path,raw=False):
 return json.loads(run(['/opt/homebrew/bin/ffprobe','-v','error',*(['-ignore_editlist','1'] if raw else []),'-show_streams','-show_format','-show_packets','-show_data_hash','sha256','-of','json',str(path)]))
def packets(data,index):
 stream=data['streams'][index];clock=Fraction(stream['time_base'])
 return [{**{k:p.get(k) for k in ['size','data_hash']},**{k:Fraction(int(p[k]))*clock if k in p else None for k in ['pts','dts','duration']}} for p in data['packets'] if p['stream_index']==stream['index']]
def decode(path,index,video=False,raw=False):
 return run(['/opt/homebrew/bin/ffmpeg','-v','error',*(['-ignore_editlist','1']if raw else []),'-i',str(path),'-map','0:'+str(index),*(['-fps_mode','passthrough','-pix_fmt','yuv420p','-f','rawvideo'] if video else ['-c:a','pcm_s32le','-f','s32le']),'-'])
groups={}
for test in json.loads((attachments/'manifest.json').read_text()):
 if 'SelectedMovingPrimary' not in test['testIdentifier']:continue
 for a in test['attachments']:
  m=re.fullmatch(r'(.+)-(source|output)_(\d+)_[A-Fa-f0-9-]+\.mov',a['suggestedHumanReadableName'])
  if m:groups.setdefault((test['testIdentifier'],m[1],m[3]),{})[m[2]]=attachments/a['exportedFileName']
rows=[];reference=None
for (test,name,instance),pair in sorted(groups.items()):
 assert set(pair)=={'source','output'}
 source=probe(pair['source']);out=probe(pair['output']);sr=probe(pair['source'],True);orr=probe(pair['output'],True)
 preserve='-audio-true'in name;retained=[(i,s) for i,s in enumerate(source['streams']) if preserve or s['codec_type']!='audio'];ss=source['streams'];os=out['streams']
 checks={'trackCountAndOrder':len(retained)==len(os)and[s['codec_type']for _,s in retained]==[s['codec_type']for s in os]}
 raw=packets(orr,0);original=packets(sr,0);pictures=decode(pair['output'],0,True,True);frame_bytes=os[0]['width']*os[0]['height']*3//2
 if reference is None:reference=pictures
 checks.update({'completeStored72FrameDecode':len(pictures)==72*frame_bytes,'stored72PacketCount':len(raw)==72,'storedPresentationTimesExact':sorted(p['pts']for p in raw)==sorted(p['pts']for p in original),'storedDecodeCadenceExact':[p['dts']for p in raw]==[Fraction(i,24)for i in range(72)],'storedDurationsExact':all(p['duration']==Fraction(1,24)for p in raw),'decodedFullMediaPicturesMatchAcrossEdits':pictures==reference,'presentationPacketTimesMatchSource':[p['pts']for p in packets(out,0)]==[p['pts']for p in packets(source,0)]})
 for oi,(si,s) in enumerate(retained):
  if si==0:continue
  if s['codec_type']=='video':checks['untouchedVideo'+str(si)+'StoredPacketsExact']=packets(sr,si)==packets(orr,oi)
  elif s['codec_type']=='audio':checks['audio'+str(si)+'PCMExact']=decode(pair['source'],si)==decode(pair['output'],oi)
 checks['titlePreserved']=source['format'].get('tags',{}).get('title')==out['format'].get('tags',{}).get('title')
 rows.append({'test':test,'case':name,'instance':instance,'sourceSHA256':sha(pair['source'].read_bytes()),'outputSHA256':sha(pair['output'].read_bytes()),'checks':checks,'decodedStoredFrames':len(pictures)//frame_bytes,'decodedStoredPicturesSHA256':sha(pictures),'creationDatePreserved':source['format'].get('tags',{}).get('creation_time')==out['format'].get('tags',{}).get('creation_time')})
result={'pairs':len(rows),'allTrackClockDecodeChecksPass':bool(rows)and all(all(r['checks'].values())for r in rows),'outputs':rows,'checkerSHA256':sha(Path(__file__).read_bytes())}
destination.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'pairs':len(rows),'allTrackClockDecodeChecksPass':result['allTrackClockDecodeChecksPass'],'failures':{r['case']:[k for k,v in r['checks'].items()if not v]for r in rows if not all(r['checks'].values())}},indent=2))

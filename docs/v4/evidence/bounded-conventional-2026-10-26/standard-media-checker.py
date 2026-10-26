from pathlib import Path
from fractions import Fraction
import subprocess,json,re,hashlib,sys
base=Path('/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01');attachments=Path(sys.argv[1])if len(sys.argv)>1 else base/'media-table-attachments';destination=Path(sys.argv[2])if len(sys.argv)>2 else base/'media-table-independent-media.json';sha=lambda b:hashlib.sha256(b).hexdigest()
def run(args):
 r=subprocess.run(args,capture_output=True);assert r.returncode==0,(args,r.stderr.decode(errors='replace'));return r.stdout
def probe(path,raw=False):
 return json.loads(run(['/opt/homebrew/bin/ffprobe','-v','error',*(['-ignore_editlist','1']if raw else []),'-show_streams','-show_format','-show_packets','-show_data_hash','sha256','-of','json',str(path)]))
def packetRows(d,stream):
 scale=Fraction(stream['time_base']);return[{**{k:p.get(k)for k in ['size','data_hash']},**{k:str(int(p[k])*scale)if k in p else None for k in ['pts','dts','duration']}}for p in d['packets']if p['stream_index']==stream['index']]
def decode(path,index,video):
 return run(['/opt/homebrew/bin/ffmpeg','-v','error','-i',str(path),'-map','0:'+str(index),*(['-pix_fmt','yuv420p','-f','rawvideo']if video else['-c:a','pcm_s32le','-f','s32le']),'-'])
groups={}
for test in json.loads((attachments/'manifest.json').read_text()):
 if not any(name in test['testIdentifier']for name in ['testAvailableSpatialAppleRoutesPreserveWholeAssetAt2x', 'testStoredBFrameMediaAndEditMapsSurviveConventionalExport', 'testStoredBFrameMediaTablesSurviveConventionalExport', 'testDisabledFirstVideoRemainsUnmodifiedAndFirstEnabledVideoIsScaled', 'testExplicitAudioOmissionRetainsEveryOtherRichMovieLane', 'testRichMoviePreservesAlternateVideoAudioGroupsMetadataChaptersAndTimecode', 'testSubtitleAndCaptionPacketsSurviveConventionalExport']):continue
 for a in test['attachments']:
  m=re.fullmatch(r'(.+)-(source|output)_(\d+)_[A-Fa-f0-9-]+\.mov',a['suggestedHumanReadableName'])
  if m:groups.setdefault((test['testIdentifier'],m[1],m[3]),{})[m[2]]=attachments/a['exportedFileName']
rows=[]
for (test,name,instance),pair in sorted(groups.items()):
 assert set(pair)=={'source','output'};source=probe(pair['source']);out=probe(pair['output']);sourceRaw=probe(pair['source'],True);outRaw=probe(pair['output'],True);preserve='-audio-true'in name;ss=source['streams'];os=out['streams'];primary=next((i for i,s in enumerate(ss)if s['codec_type']=='video'and s['disposition']['default']),next(i for i,s in enumerate(ss)if s['codec_type']=='video'));retained=[(i,s)for i,s in enumerate(ss)if preserve or s['codec_type']!='audio'];checks={'trackCountAndOrder':len(retained)==len(os)and[s['codec_type']for _,s in retained]==[s['codec_type']for s in os]};preserved=[];processed={}
 if checks['trackCountAndOrder']:
  for oi,(si,s)in enumerate(retained):
   o=os[oi]
   if si!=primary and s['codec_type']=='video':
    a=packetRows(sourceRaw,sourceRaw['streams'][si]);b=packetRows(outRaw,outRaw['streams'][oi]);same=a==b;preserved.append({'sourceStream':si,'outputStream':oi,'storedPackets':len(a),'outputStoredPackets':len(b),'allPayloadSizePTSDTSDurationExact':same});checks['untouchedVideo'+str(si)+'StoredPacketIdentity']=same
   elif s['codec_type']=='audio':
    a=decode(pair['source'],si,False);b=decode(pair['output'],oi,False);checks['audio'+str(si)+'PCMExact']=a==b;preserved.append({'sourceStream':si,'outputStream':oi,'decodedPCMBytes':len(a),'PCMByteExact':a==b})
   elif si==primary:
    inp=packetRows(source,s);actual=packetRows(out,o);raw=packetRows(outRaw,outRaw['streams'][oi]);pts=sorted(Fraction(x['pts'])for x in inp if x['pts']is not None);outPTS=sorted(Fraction(x['pts'])for x in actual if x['pts']is not None);steps={b-a for a,b in zip(pts,pts[1:])};assert len(steps)==1,steps;step=next(iter(steps));decoded=decode(pair['output'],oi,True);frameBytes=o['width']*o['height']*3//2;checks['processedPresentationClockExact']=outPTS==pts;checks['processedStoredPacketDurationsExact']=all(x['duration']==str(step)for x in raw);checks['processedCompleteDecodedFrameCount']=len(decoded)==len(pts)*frameBytes
    processed={'sourceFrames':len(pts),'outputPackets':len(actual),'decodedFrames':len(decoded)//frameBytes,'expectedStep':str(step),'storedPacketDurations':sorted({x['duration']for x in raw}),'raster':[o['width'],o['height']],'decodedPictureSHA256':sha(decoded)}
  checks['titlePreserved']=source['format'].get('tags',{}).get('title')==out['format'].get('tags',{}).get('title')
 sourceDate=source['format'].get('tags',{}).get('creation_time');outputDate=out['format'].get('tags',{}).get('creation_time')
 rows.append({'test':test,'case':name,'instance':instance,'sourceSHA256':sha(pair['source'].read_bytes()),'outputSHA256':sha(pair['output'].read_bytes()),'checks':checks,'processedPrimary':processed,'preservedLanes':preserved,'creationDateCheck':{'source':sourceDate,'output':outputDate,'equal':sourceDate==outputDate}})
assert len(rows)==38,len(rows)
result={'outputs':rows,'trackAndTimingChecksPass':all(all(r['checks'].values())for r in rows),'allMeasuredCreationDatesPass':all(r['creationDateCheck']['equal']for r in rows),'allMeasuredChecksPass':all(all(r['checks'].values())and r['creationDateCheck']['equal']for r in rows),'checkerSHA256':sha(Path(__file__).read_bytes())};destination.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'pairs':len(rows),'trackAndTimingChecksPass':result['trackAndTimingChecksPass'],'allMeasuredCreationDatesPass':result['allMeasuredCreationDatesPass'],'failures':{r['case']:[k for k,v in r['checks'].items()if not v]for r in rows if not all(r['checks'].values())}},indent=2))

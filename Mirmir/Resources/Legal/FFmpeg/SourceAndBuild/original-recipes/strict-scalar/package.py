import hashlib,json,os,re,shutil,subprocess
from pathlib import Path
root=Path(__file__).resolve().parent
results=json.loads((root/'thin-build-results.json').read_text());assert all(x['state']=='complete' for x in results),results
out=root/'universal';out.mkdir(exist_ok=True);(out/'lib').mkdir(exist_ok=True);(out/'licenses').mkdir(exist_ok=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
headers={}
for arch in ['arm64','x86_64']:
 base=root/'install'/arch/'include';headers[arch]={str(p.relative_to(base)):sha(p) for p in base.rglob('*') if p.is_file()}
assert headers['arm64']==headers['x86_64'],[(k,headers['arm64'].get(k),headers['x86_64'].get(k)) for k in set(headers['arm64'])|set(headers['x86_64']) if headers['arm64'].get(k)!=headers['x86_64'].get(k)]
shutil.copytree(root/'install/arm64/include',out/'include',dirs_exist_ok=True)
for p in (root/'ffmpeg-8.1.2').glob('COPYING*'):shutil.copy2(p,out/'licenses'/p.name)
shutil.copy2(root/'ffmpeg-8.1.2/LICENSE.md',out/'licenses/LICENSE.md')
commands=[]
for p in sorted((root/'install/arm64/lib').glob('*.dylib')):
 target=out/'lib'/p.name
 if p.is_symlink():
  link=os.readlink(p)
  if target.is_symlink():assert os.readlink(target)==link
  elif not target.exists():target.symlink_to(link)
  continue
 other=root/'install/x86_64/lib'/p.name;assert other.is_file()
 command=['/usr/bin/lipo','-create',str(p),str(other),'-output',str(target)];subprocess.run(command,check=True);commands.append(command)
 command=['/usr/bin/codesign','--force','--sign','-',str(target)];done=subprocess.run(command,capture_output=True,check=True);commands.append(command)
 (root/f'codesign-{p.name}.log').write_bytes(done.stdout+done.stderr)
manifest={'headersIdenticalAcrossArchitectures':True,'headerFileCount':len(headers['arm64']),'headerSHA256':headers['arm64'],'libraries':[],'source':json.loads((root/'source-verification.json').read_text()),'codeSignature':'ad hoc development signature after lipo; not distribution signing'}
for p in sorted((out/'lib').glob('*.dylib')):
 if p.is_symlink():continue
 archs=subprocess.check_output(['/usr/bin/lipo','-archs',str(p)],text=True).strip().split();assert set(archs)=={'arm64','x86_64'},(p,archs)
 item={'path':str(p.relative_to(out)),'bytes':p.stat().st_size,'sha256':sha(p),'architectures':archs,'slices':{}}
 for arch in archs:
  dependencies=subprocess.check_output(['/usr/bin/otool','-arch',arch,'-L',str(p)],text=True)
  ids=subprocess.check_output(['/usr/bin/otool','-arch',arch,'-D',str(p)],text=True)
  loads=subprocess.check_output(['/usr/bin/otool','-arch',arch,'-l',str(p)],text=True)
  dep=[x.strip().split(' (compatibility')[0] for x in dependencies.splitlines()[1:] if x.strip()]
  for value in dep:
   assert value.startswith(('@rpath/','/usr/lib/','/System/Library/Frameworks/')),(p,arch,value)
   if value.startswith('@rpath/'):assert (out/'lib'/value[len('@rpath/'):]).is_file(),value
  assert re.search(r'\bminos 15\.4\b',loads),(p,arch,'wrong deployment target')
  install_id=ids.splitlines()[-1].strip()
  assert install_id.startswith('@rpath/') and (out/'lib'/install_id[len('@rpath/'):]).resolve()==p.resolve(),(p,arch,ids)
  item['slices'][arch]={'dependencies':dep,'installName':install_id,'minimumMacOS':'15.4'}
  (root/f'otool-{arch}-{p.name}.txt').write_text(dependencies+'\n'+ids+'\n'+loads)
 subprocess.run(['/usr/bin/codesign','--verify','--strict',str(p)],check=True,capture_output=True)
 manifest['libraries'].append(item)
assert len(manifest['libraries'])==5,len(manifest['libraries'])
(root/'package-commands.json').write_text(json.dumps(commands,indent=2)+'\n');(root/'package-audit.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({k:v for k,v in manifest.items() if k not in ['headerSHA256','source']},sort_keys=True))

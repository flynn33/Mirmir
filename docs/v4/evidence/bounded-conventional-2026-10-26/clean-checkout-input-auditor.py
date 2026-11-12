from pathlib import Path
import subprocess,json,hashlib
r=Path('/private/tmp/Mirmir-clean-checkout-c1dbe8509-20261026').resolve();out=Path('/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01');raw=subprocess.check_output(['plutil','-convert','json','-o','-',str(r/'Mirmir.xcodeproj/project.pbxproj')]);project=json.loads(raw);obj=project['objects'];parents={}
for key,x in obj.items():
 for child in x.get('children',[]):parents.setdefault(child,[]).append(key)
tracked=set(subprocess.check_output(['git','ls-files','-z'],cwd=r).decode().split('\0'))
def resolve(key,seen=()):
 assert key not in seen
 x=obj[key];tree=x.get('sourceTree','<group>');path=x.get('path','')
 if tree in ['SDKROOT','DEVELOPER_DIR','BUILT_PRODUCTS_DIR']:return None
 if tree=='SOURCE_ROOT':return r/path
 if tree=='<absolute>':return Path(path)
 assert tree=='<group>',(key,tree)
 ps=parents.get(key,[])
 if not ps:return r/path
 values=[resolve(p,(*seen,key))for p in ps];assert all(v==values[0]for v in values);return values[0]/path
inputs=[];bad=[]
for key,x in obj.items():
 if x.get('isa')!='PBXBuildFile' or 'fileRef'not in x:continue
 path=resolve(x['fileRef'])
 if path is None:continue
 path=path.resolve()
 try:relative=path.relative_to(r)
 except ValueError:bad.append({'kind':'outsideRepository','path':str(path)});continue
 if not path.exists():bad.append({'kind':'missing','path':str(relative)});continue
 files=[path]if path.is_file()else[x for x in path.rglob('*')if x.is_file()]
 for f in files:
  rel=str(f.relative_to(r))
  if f.is_symlink()or rel not in tracked:bad.append({'kind':'notRegularTrackedInput','path':rel})
 inputs.append({'reference':str(relative),'trackedFiles':len(files)})
packages=[x for x in obj.values()if x.get('isa')=='XCRemoteSwiftPackageReference'];scripts=[x for x in obj.values()if x.get('isa')=='PBXShellScriptBuildPhase'];assert not packages and not scripts
symlinks=[x for x in subprocess.check_output(['git','ls-files','-s'],cwd=r,text=True).splitlines()if x.startswith('120000 ')or x.startswith('160000 ')];assert not symlinks
lfs='filter=lfs'in(r/'.gitattributes').read_text();assert not lfs;assert not bad,bad
result={'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=r,text=True).strip(),'project':'Mirmir.xcodeproj','remoteSwiftPackages':len(packages),'shellBuildPhases':len(scripts),'trackedSymlinksOrSubmodules':len(symlinks),'buildInputs':inputs,'allProjectBuildInputsTrackedOrAppleSDK':True,'missingOrExternalInputs':bad,'gitLFSFilters':lfs,'auditorSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()};(out/'clean-checkout-input-audit.json').write_text(json.dumps(result,indent=2)+'\n');print({k:result[k]for k in ['sourceCommit','remoteSwiftPackages','shellBuildPhases','trackedSymlinksOrSubmodules','allProjectBuildInputsTrackedOrAppleSDK']},'inputReferences',len(inputs))

"""Test local LGPL library replacement on a new signed private app copy."""
from pathlib import Path
import argparse,hashlib,json,plistlib,shutil,subprocess,tempfile
p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--replacement-directory',type=Path,required=True);p.add_argument('--signing-identity',required=True);a=p.parse_args()
app=a.app.resolve(strict=True);out=a.output.absolute();replacement=a.replacement_directory.resolve(strict=True)
assert app.is_dir()and app.suffix=='.app'and out.suffix=='.app'and not out.exists()
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
expected=['libavcodec.62.dylib','libavformat.62.dylib','libavutil.60.dylib','libswresample.6.dylib','libswscale.9.dylib'];selected={}
for name in expected:
 candidate=replacement/name
 if not candidate.exists():continue
 data=candidate.resolve(strict=True);assert data.is_file()
 arch=subprocess.check_output(['/usr/bin/lipo','-archs',str(data)],text=True).split();assert set(arch)=={'arm64','x86_64'}
 for architecture in arch:
  ident=subprocess.check_output(['/usr/bin/otool','-arch',architecture,'-D',str(data)],text=True).splitlines()[-1].strip();assert ident=='@rpath/'+name,(name,ident)
 selected[name]=data
assert selected,'No matching ABI-named library supplied'
# Read the actual original app entitlements; never add library-validation or
# sandbox exceptions. A Store-installed package is a separate untested case.
entitlement=subprocess.run(['/usr/bin/codesign','-d','--entitlements',':-',str(app)],capture_output=True,check=True).stdout
assert isinstance(plistlib.loads(entitlement),dict)
shutil.copytree(app,out,symlinks=True)
sha=lambda f:hashlib.sha256(Path(f).read_bytes()).hexdigest();rows=[]
for name,source in selected.items():
 target=out/'Contents/Frameworks'/name;assert target.is_file()and not target.is_symlink();before=sha(target);shutil.copy2(source,target);rows.append({'library':name,'source':str(source),'beforeSHA256':before,'replacementInputSHA256':sha(source)})
for lib in(out/'Contents/Frameworks').glob('*.dylib'):
 subprocess.run(['/usr/bin/codesign','--force','--sign',a.signing_identity,str(lib)],check=True)
for plugin in (out/'Contents/PlugIns').glob('*.xctest'):
 subprocess.run(['/usr/bin/codesign','--force','--sign',a.signing_identity,str(plugin)],check=True)
mainExecutable=plistlib.loads((out/'Contents/Info.plist').read_bytes())['CFBundleExecutable']
for helper in (out/'Contents/MacOS').iterdir():
 if helper.is_file() and helper.name!=mainExecutable:
  subprocess.run(['/usr/bin/codesign','--force','--sign',a.signing_identity,'--options','runtime',str(helper)],check=True)
with tempfile.TemporaryDirectory(prefix='mirmir-lgpl-replacement-signing-')as temp:
 ent=Path(temp)/'entitlements.plist';ent.write_bytes(entitlement)
 subprocess.run(['/usr/bin/codesign','--force','--sign',a.signing_identity,'--options','runtime','--entitlements',str(ent),str(out)],check=True)
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(out)],check=True)
for row in rows:row['finalSHA256']=sha(out/'Contents/Frameworks'/row['library'])
receipt={'scope':'Local signed replacement mechanism only; not Store-installed replacement, EULA adoption or distribution approval','originalApp':str(app),'outputApp':str(out),'preservedEntitlements':plistlib.loads(entitlement),'replacements':rows}
(out.parent/(out.stem+'-replacement-receipt.json')).write_text(json.dumps(receipt,indent=2)+'\n');print(out)

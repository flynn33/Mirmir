"""Prepare or execute the retained strict-scalar LGPL library build locally."""
from pathlib import Path
import argparse,hashlib,json,shutil,subprocess,sys,tarfile
p=argparse.ArgumentParser();p.add_argument('--package',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--build',action='store_true');a=p.parse_args()
package=a.package.resolve(strict=True);out=a.output.absolute();assert not out.exists(),out
archive=package/'downloads/ffmpeg-8.1.2.tar.xz';expected='464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c';assert hashlib.sha256(archive.read_bytes()).hexdigest()==expected
out.mkdir(parents=True)
with tarfile.open(archive,mode='r:xz')as t:
 for item in t.getmembers():
  parts=Path(item.name).parts;assert parts and parts[0]=='ffmpeg-8.1.2' and '..'not in parts and not item.name.startswith('/') and (item.isfile()or item.isdir()),item.name
 t.extractall(out)  # Every member above is authenticated, relative, regular or a directory; links are forbidden.
shutil.copytree(package/'downloads',out/'downloads');shutil.copy2(package/'source-verification.json',out/'source-verification.json')
for name in ['build.py','package.py','audit_config.py']:shutil.copy2(package/'original-recipes/strict-scalar'/name,out/name)
# These are the exact retained recipes. Their root is derived from __file__;
# prefix/sysroot paths and actual compiler commands are recorded on each run.
commands=[[sys.executable,str(out/'build.py')],[sys.executable,str(out/'package.py')],[sys.executable,str(out/'audit_config.py')]]
(out/'REBUILD-INSTRUCTIONS.txt').write_text('The authenticated original source is extracted here. You may inspect or modify the LGPL component sources before executing the retained recipes. Each source file preserves its upstream notices. This procedure prepares only the FFmpeg libraries; it does not change or adopt Mirmir terms.\n\n'+'\n'.join(' '.join(x)for x in commands)+'\n')
(out/'preparation-receipt.json').write_text(json.dumps({'archiveSHA256':expected,'extractedSourceFiles':sum(x.is_file()for x in(out/'ffmpeg-8.1.2').rglob('*')),'commands':commands,'actualBuildExecuted':a.build},indent=2)+'\n')
if a.build:
 for command in commands:subprocess.run(command,cwd=out,check=True)
print(out)

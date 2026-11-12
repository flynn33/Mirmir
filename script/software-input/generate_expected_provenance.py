#!/usr/bin/env python3
"""Record expected build inputs; loaded signed images are observed separately."""
from pathlib import Path
import hashlib,json,sys
root=Path(__file__).resolve().parents[2]
package=Path(sys.argv[1]) if len(sys.argv)>1 else root/'Vendor/FFmpeg/strict-scalar-8.1.2'
recipes=Path(sys.argv[2]) if len(sys.argv)>2 else root/'Mirmir/Resources/Legal/FFmpeg/SourceAndBuild'
def record(p,base):
 data=p.read_bytes();return {'path':str(p.relative_to(base)),'bytes':len(data),'SHA256':hashlib.sha256(data).hexdigest()}
owned=sorted(p for p in (root/'Mirmir').rglob('*')if p.is_file()and 'SourceAndBuild'not in p.parts and p.suffix in ['.swift','.metal','.c','.h','.modulemap'])
owned += [root/'Mirmir.xcodeproj/project.pbxproj',Path(__file__).resolve()]
headers=sorted(p for p in(package/'include').rglob('*')if p.is_file());assert len(headers)==136
libraries=sorted({p.resolve()for p in(package/'lib').glob('*.dylib')});assert len(libraries)==5
recipeFiles=sorted(p for p in recipes.rglob('*')if p.is_file() and 'application-bridge-source'not in p.parts)
assert recipeFiles
archive=next(p for p in recipeFiles if p.name=='ffmpeg-8.1.2.tar.xz');assert hashlib.sha256(archive.read_bytes()).hexdigest()=='464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c'
body={'schemaID':'mirmir.software-input-expected-source-provenance.v1','scope':'Expected source and build inputs, distinct from observed signed implementation images. This inventory does not by itself attest a binary/source relationship.','ownedSources':[record(p,root)for p in sorted(set(owned))],'decoderHeaders':[record(p,package/'include')for p in headers],'expectedBuildLibraries':[record(p,package/'lib')for p in libraries],'correspondingSourceAndRecipes':[record(p,recipes)for p in recipeFiles]}
path=root/'Mirmir/SoftwareInputExpectedProvenance.json';data=(json.dumps(body,sort_keys=True,separators=(',',':'))+'\n').encode();assert len(data)<=1024*1024
if not path.exists()or path.read_bytes()!=data:path.write_bytes(data)
print(json.dumps({'manifestSHA256':hashlib.sha256(data).hexdigest(),'ownedSources':len(owned),'headers':len(headers),'libraries':len(libraries),'sourceRecipeFiles':len(recipeFiles),'bytes':len(data)}))

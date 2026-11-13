import hashlib,json,sys
from pathlib import Path
root=Path(__file__).resolve().parent
sys.path.insert(0,str(root/'verification-python'))
import pgpy
expected='FCF986EA15E6E293A5644F10B4322F04D67658D8'
archive=root/'downloads/ffmpeg-8.1.2.tar.xz'
key,_=pgpy.PGPKey.from_file(str(root/'downloads/ffmpeg-devel.asc'))
signature=pgpy.PGPSignature.from_file(str(root/'downloads/ffmpeg-8.1.2.tar.xz.asc'))
assert str(key.fingerprint)==expected,(key.fingerprint,expected)
assert bool(key.verify(archive.read_bytes(),signature)),'Official release signature did not verify'
result={'release':'8.1.2','tarballURL':'https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz','signatureURL':'https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz.asc','officialKeyURL':'https://ffmpeg.org/ffmpeg-devel.asc','fingerprintAuthorityURL':'https://ffmpeg.org/download.html','officialReleaseKeyFingerprint':str(key.fingerprint),'signatureVerified':True,'signatureCreated':signature.created.isoformat(),'signatureHashAlgorithm':signature.hash_algorithm.name,'bytes':archive.stat().st_size,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'sha512':hashlib.sha512(archive.read_bytes()).hexdigest(),'hashAuthority':'Computed archive hashes bind the tarball authenticated by the official detached signature. No separate official SHA256 list was found on the release index.','verificationLibrary':'PGPy 0.6.0 with pinned official fingerprint; dependencies isolated under verification-python'}
(root/'source-verification.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,sort_keys=True))

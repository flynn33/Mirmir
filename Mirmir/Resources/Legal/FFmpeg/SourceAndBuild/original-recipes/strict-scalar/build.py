import concurrent.futures,hashlib,json,os,subprocess,time
from pathlib import Path
root=Path(__file__).resolve().parent
source=root/'ffmpeg-8.1.2'
verification=json.loads((root/'source-verification.json').read_text())
assert verification['signatureVerified'] and hashlib.sha256((root/'downloads/ffmpeg-8.1.2.tar.xz').read_bytes()).hexdigest()==verification['sha256']
assert (source/'VERSION').read_text().strip()=='8.1.2'
sdk=subprocess.check_output(['/usr/bin/xcrun','--show-sdk-path'],text=True).strip()
env={k:v for k,v in os.environ.items() if k not in ['CFLAGS','CPPFLAGS','LDFLAGS','CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','LIBRARY_PATH','DYLD_LIBRARY_PATH','PKG_CONFIG_PATH','PKG_CONFIG_LIBDIR','SDKROOT','MACOSX_DEPLOYMENT_TARGET']}
env.update({'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LC_ALL':'C','LANG':'C','ZERO_AR_DATE':'1','SOURCE_DATE_EPOCH':'1781664539','MACOSX_DEPLOYMENT_TARGET':'15.4','SDKROOT':sdk})
common=['--target-os=darwin','--enable-cross-compile','--cc=/usr/bin/clang','--cxx=/usr/bin/clang++','--ar=/usr/bin/ar','--ranlib=/usr/bin/ranlib','--nm=/usr/bin/nm','--strip=/usr/bin/strip','--ld=/usr/bin/clang','--pkg-config=/usr/bin/false','--install-name-dir=@rpath','--enable-shared','--disable-static','--enable-pic','--disable-autodetect','--disable-asm','--disable-gpl','--disable-version3','--disable-nonfree','--disable-programs','--disable-doc','--disable-debug','--disable-network','--disable-protocols','--disable-avdevice','--disable-devices','--disable-avfilter','--disable-filters','--disable-encoders','--disable-muxers','--disable-hwaccels','--disable-audiotoolbox','--disable-videotoolbox','--enable-swscale','--enable-swresample','--enable-zlib','--enable-bzlib','--enable-iconv','--extra-libs=-liconv']
(root/'build-environment.json').write_text(json.dumps({'sdk':sdk,'environmentOverrides':{k:env[k] for k in ['PATH','LC_ALL','LANG','ZERO_AR_DATE','SOURCE_DATE_EPOCH','MACOSX_DEPLOYMENT_TARGET','SDKROOT']},'parallelArchitectures':2,'makeJobsPerArchitecture':4,'configurationIntent':'LGPL2.1-or-later software decoders/demuxers/parsers and swscale/swresample only; no external Homebrew dependencies, network, protocols, programs, encoders, muxers, devices, filters or hardware accelerators.'},indent=2)+'\n')
def build(architecture):
 out=root/'build'/architecture;out.mkdir(parents=True,exist_ok=True)
 prefix=root/'install'/architecture
 flags=f'-arch {architecture} -mmacosx-version-min=15.4 -isysroot {sdk} -ffp-contract=off'
 command=[str(source/'configure'),f'--prefix={prefix}',f'--arch={architecture}',f'--sysroot={sdk}',f'--extra-cflags={flags}',f'--extra-ldflags={flags} -Wl,-headerpad_max_install_names',*common]
 if architecture=='x86_64':command.append('--disable-x86asm')
 (out/'commands.json').write_text(json.dumps([command,['/usr/bin/make','-j4'],['/usr/bin/make','install']],indent=2)+'\n')
 start=time.time()
 for stage,args in [('configure',command),('make',['/usr/bin/make','-j4']),('install',['/usr/bin/make','install'])]:
  (out/'state.json').write_text(json.dumps({'architecture':architecture,'stage':stage,'state':'running','elapsedSeconds':time.time()-start})+'\n')
  with (out/f'{stage}.log').open('wb') as log:p=subprocess.run(args,cwd=out,env=env,stdout=log,stderr=subprocess.STDOUT)
  if p.returncode:
   result={'architecture':architecture,'stage':stage,'state':'failed','exit':p.returncode,'elapsedSeconds':time.time()-start};(out/'state.json').write_text(json.dumps(result)+'\n');return result
  print(architecture,stage,'passed',flush=True)
 result={'architecture':architecture,'state':'complete','elapsedSeconds':time.time()-start};(out/'state.json').write_text(json.dumps(result)+'\n');return result
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(build,['arm64','x86_64']))
(root/'thin-build-results.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results),flush=True)
raise SystemExit(0 if all(x['state']=='complete' for x in results) else 1)

import json,re,subprocess
from pathlib import Path
root=Path(__file__).resolve().parent;report=[]
for arch in ['arm64','x86_64']:
 directory=root/'build'/arch
 macros={k:int(v) for p in [directory/'config.h',directory/'config_components.h'] for k,v in re.findall(r'^#define ([A-Z0-9_]+) ([01])$',p.read_text(),re.M)}
 required_disabled=['CONFIG_GPL','CONFIG_VERSION3','CONFIG_NONFREE','CONFIG_NETWORK','CONFIG_AVDEVICE','CONFIG_AVFILTER','CONFIG_ENCODERS','CONFIG_MUXERS','CONFIG_HWACCELS','CONFIG_PROTOCOLS','CONFIG_AVUTIL']
 required_disabled.remove('CONFIG_AVUTIL')
 for name in required_disabled:assert macros[name]==0,(arch,name,macros.get(name))
 enabled_external={k:v for k,v in macros.items() if k.startswith('CONFIG_LIB') and v}
 assert not enabled_external,enabled_external
 for suffix in ['_ENCODER','_MUXER','_PROTOCOL','_INDEV','_OUTDEV','_HWACCEL']:assert not any(v for k,v in macros.items() if k.endswith(suffix)),(arch,suffix)
 report.append({'architecture':arch,'requiredDisabled':{k:macros[k] for k in required_disabled},'enabledExternalCONFIG_LIBMacros':enabled_external,'enabledAppleSDKSupport':{k:macros.get(k) for k in ['CONFIG_ZLIB','CONFIG_BZLIB','CONFIG_ICONV']},'enabledBuiltInDecoders':sum(v for k,v in macros.items() if k.endswith('_DECODER')),'enabledBuiltInDemuxers':sum(v for k,v in macros.items() if k.endswith('_DEMUXER')),'enabledParsers':sum(v for k,v in macros.items() if k.endswith('_PARSER')),'enabledBSFs':sum(v for k,v in macros.items() if k.endswith('_BSF')),'clangVersion':subprocess.check_output(['/usr/bin/clang','--version'],text=True).splitlines()[0]})
(root/'config-audit.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))

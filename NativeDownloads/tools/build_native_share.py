"""Compile the retained-field Swift bridge and return its clang link inputs.

Existing builders may import build_native_share(output, sdk, target). This does
not modify manifests, source trees, IPAs, signing metadata, or device state.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess

SOURCE=Path(__file__).resolve().parents[1]/'src/Export/NativeShareBridge.swift'

def build_native_share(output: Path, sdk: str, target: str='arm64-apple-ios15.0') -> dict:
    output=Path(output).resolve();output.parent.mkdir(parents=True,exist_ok=True)
    common=['-target',target,'-sdk',str(sdk)]
    subprocess.run(['xcrun','swiftc',*common,'-O','-parse-as-library','-module-name','PixieNativeShare',
                    '-emit-object',str(SOURCE),'-o',str(output)],check=True)
    # Use this installed Swift driver's compatibility archives and search paths,
    # rather than pinning runtime library names to a particular Xcode release.
    placeholder=str(output.with_suffix('.link-probe.dylib'))
    jobs=subprocess.check_output(['xcrun','swiftc',*common,'-driver-print-jobs','-emit-library',
                                  str(output),'-o',placeholder],text=True)
    lines=[shlex.split(line) for line in jobs.splitlines() if line.strip()]
    links=[line for line in lines if '-dynamiclib' in line and '-o' in line]
    if len(links)!=1:raise RuntimeError('Could not identify the Swift link command')
    command=links[0];start=next((i+1 for i,arg in enumerate(command) if arg=='--target='+target),None)
    if start is None:raise RuntimeError('Swift driver link target was not recognized')
    flags=command[start:command.index('-o')]
    return {'object':str(output),'link_args':[str(output),*flags],
            'objc_source':str(SOURCE.with_name('NativeShareHooks.m')),
            'bootstrap_call':'SAPInstallNativeShareHooks()',
            'target':target,'swift_source':str(SOURCE)}

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--sdk',default=None)
    parser.add_argument('--target',default='arm64-apple-ios15.0')
    args=parser.parse_args()
    sdk=args.sdk or subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip()
    print(json.dumps(build_native_share(args.output,sdk,args.target),indent=2))

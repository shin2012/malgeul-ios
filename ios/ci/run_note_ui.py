#!/usr/bin/env python3
"""중립적인 가짜 서버를 대상으로 실제 앱 UI 시험을 실행한다."""
import json
import os
from pathlib import Path
import subprocess
import sys

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
devices = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j']))['devices']
all_devices = [d for runtime, group in devices.items() if 'iOS' in runtime for d in group]
results=[]
for prefix, name in [('iPhone','phone'),('iPad Pro','ipad')]:
    candidates=[d for d in all_devices if d['name'].startswith(prefix)]
    if not candidates: raise RuntimeError('시뮬레이터 없음: '+prefix)
    d=sorted(candidates,key=lambda d:d['name'])[-1]
    result=out/(name+'.xcresult')
    args=['xcodebuild','-project','Malgeul.xcodeproj','-scheme','MalgeulUITests',
          '-configuration','Debug','-destination','platform=iOS Simulator,id='+d['udid'],
          '-derivedDataPath',str(out.parent/'note-derived'),'-clonedSourcePackagesDirPath',os.environ['RUNNER_TEMP']+'/spm',
          '-resultBundlePath',str(result),'-parallel-testing-enabled','NO',
          'CODE_SIGNING_ALLOWED=NO','-IDEBuildingContinueBuildingAfterErrors=YES','test']
    print('TEST',name,d['name'],flush=True)
    with (out/(name+'.log')).open('w') as log:
        p=subprocess.Popen(args,cwd='ios',stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        assert p.stdout is not None
        for line in p.stdout:
            log.write(line); log.flush()
            if any(s in line for s in ['error:','Test Case','TEST ','Executed','BUILD ','failed']): print(line,end='',flush=True)
        code=p.wait()
    results.append({'device':d['name'],'udid':d['udid'],'exit_code':code})
    (out/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
    if result.exists():
        subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(result),'--output-path',str(out/(name+'-attachments'))],check=False)
    subprocess.run(['xcrun','simctl','shutdown',d['udid']],check=False)
if any(r['exit_code'] for r in results): raise SystemExit(1)

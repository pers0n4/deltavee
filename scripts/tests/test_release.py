#!/usr/bin/env python3
"""Isolated release-script smoke tests; Apple/GitHub CLIs are local fixtures.

Uses real plist/ZIP/checksum tools, temporary HOME, and no credentials or network.
Run with: python3 scripts/tests/test_release.py
"""
import os, pathlib, tempfile, shutil, plistlib, subprocess, json
source = pathlib.Path(__file__).resolve().parents[2]
stub = '''#!/usr/bin/python3
import os,sys,pathlib,plistlib,json
args=sys.argv[1:]; tool=pathlib.Path(sys.argv[0]).name; state=pathlib.Path(os.environ['FIXTURE']); case=os.environ.get('CASE','ok')
def count(name):
 p=state/name;n=int(p.read_text())+1 if p.exists() else 1;p.write_text(str(n));return n
if tool=='git':
 a=' '.join(args)
 if '--show-toplevel' in a: print(os.environ['FIXTURE_ROOT'])
 elif 'status --porcelain' in a:
  if case=='dirty': print(' M changed.swift')
 elif 'cat-file -t' in a: print('tag')
 elif 'refs/tags/' in a:
  if case=='missingtag':sys.exit(1)
  print('a'*40 if '^{commit}' in a else 'b'*40)
 else: print('a'*40)
elif tool=='codesign':
 if '--display' in args: print('Timestamp=2026 Nov 18 at 00:00:00\\nflags=0x10000(runtime)\\nCDHash='+'c'*40,file=sys.stderr)
elif tool=='spctl':
 if not (pathlib.Path(args[-1])/'.ticket').exists():sys.exit(1)
elif tool=='xcrun':
 if args[:2]==['--find','notarytool']:print('/fixture/notarytool')
 elif args[:2]==['notarytool','submit']:
  n=count('submits');print('  id: 11111111-1111-1111-1111-111111111111')
  if case=='timeout' and n==1:sys.exit(1)
 elif args[:2]==['notarytool','info']:sys.stdout.buffer.write(plistlib.dumps({'id':'11111111-1111-1111-1111-111111111111','status':'Accepted'}))
 elif args[:2]==['notarytool','log']:pathlib.Path(args[-1]).write_text('{}')
 elif args[:2]==['stapler','staple']:(pathlib.Path(args[-1])/'.ticket').write_text('stapled')
 elif args[:2]==['stapler','validate']:
  if not (pathlib.Path(args[-1])/'.ticket').exists():sys.exit(1)
 else:raise SystemExit('Unexpected xcrun '+repr(args))
elif tool=='gh':
 if args[:2]==['release','create']:
  count('creates');assert '--verify-tag' in args and 'github.com/pers0n4/deltavee' in args
  if case=='partial':sys.exit(1)
 elif args[0]=='api':
  endpoint=next(x for x in args if x.startswith('repos/'))
  if '/git/ref/' in endpoint:
   sha=('d' if case=='remote-mismatch' else 'b')*40
   if '--jq' in args:print(sha)
   else:print(json.dumps({'ref':'refs/tags/v0.1.0','object':{'sha':sha,'type':'tag'}}))
  elif '/releases?' in endpoint:
   if case=='existing':print('v0.1.0')
  elif '/releases/tags/' in endpoint:print('false' if case=='digest-mismatch' else 'true')
  else:raise SystemExit('Unexpected endpoint '+endpoint)
 else:raise SystemExit('Unexpected gh '+repr(args))
else:raise SystemExit('Unexpected stub '+tool)
'''
with tempfile.TemporaryDirectory(prefix='deltavee-release-smoke-') as tmp:
 root=pathlib.Path(tmp).resolve()
 def fixture(name):
  base=root/name;base.mkdir();repo=base/'repo';(repo/'scripts').mkdir(parents=True)
  for f in ('release-common.sh','notarize.sh','publish-release.sh'):shutil.copy2(source/'scripts'/f,repo/'scripts'/f)
  bin=base/'bin';bin.mkdir()
  for tool in ('git','codesign','spctl','xcrun','gh'):
   p=bin/tool;p.write_text(stub);p.chmod(0o700)
  app=base/'home/Library/Caches/deltavee/dist/Deltavee.app';(app/'Contents/MacOS').mkdir(parents=True)
  (app/'Contents/MacOS/Deltavee').write_text('fixture executable')
  (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1','CFBundleIdentifier':'dev.pers0n4.deltavee','DeltaveeUpdateRepository':'pers0n4/deltavee','DeltaveeSourceRevision':'a'*40}))
  env=dict(os.environ,HOME=str(base/'home'),PATH=str(bin)+':/usr/bin:/bin',FIXTURE=str(base),FIXTURE_ROOT=str(repo),NOTARY_PROFILE='fixture-profile')
  return base,repo,env
 def run(repo,env,script,success=True):
  r=subprocess.run(['sh',str(repo/'scripts'/script)],env=env,capture_output=True,text=True)
  assert (r.returncode==0)==success,(script,r.returncode,r.stdout,r.stderr)
  return r
 def number(base,key):return int((base/key).read_text()) if (base/key).exists() else 0
 for name,payload,success in (
  ('portable-binary',b'\0/Applications/Deltavee.app/Contents/Resources\0',True),
  ('mac-home-binary',b'\0/Users/private-builder/Library/Caches/resources.bundle\0',False),
  ('linux-home-binary',b'\0/home/private-builder/build/resources.bundle\0',False),
  ('missing-binary',None,False),
 ):
  binary=root/name
  if payload is not None:binary.write_bytes(payload)
  r=subprocess.run(['sh','-eu','-c','. "$1"; release_verify_binary_paths "$2"','privacy-check',str(source/'scripts/release-common.sh'),str(binary)],capture_output=True,text=True)
  assert (r.returncode==0)==success,(name,r.returncode,r.stderr)
  assert 'private-builder' not in r.stderr
  print(name+': passed (isolated binary privacy check)')
 for case in ('ok','timeout','missingprofile','missingtag','dirty','tamper','remote-mismatch','existing','partial','digest-mismatch','no-ticket'):
  base,repo,env=fixture(case);env['CASE']=case
  if case=='missingprofile':env['NOTARY_PROFILE']=''
  if case in ('missingprofile','missingtag','dirty'):
   run(repo,env,'notarize.sh',False);assert number(base,'submits')==0
  else:
   if case=='timeout':
    run(repo,env,'notarize.sh',False);run(repo,env,'notarize.sh');assert number(base,'submits')==1
   else:run(repo,env,'notarize.sh')
   rel=base/'home/Library/Caches/deltavee/releases/0.1.0-1';archive=rel/'Deltavee-0.1.0-1.zip'
   assert archive.exists() and number(base,'submits')==1
   if case=='tamper':archive.write_bytes(archive.read_bytes()+b'tampered')
   if case=='no-ticket':(rel/'Deltavee.app/.ticket').unlink()
   success=case in ('ok','timeout')
   run(repo,env,'publish-release.sh',success)
   if case=='partial':run(repo,env,'publish-release.sh',False);assert number(base,'creates')==1
   if case in ('tamper','remote-mismatch','existing','no-ticket'):assert number(base,'creates')==0
   if success:assert number(base,'creates')==1
  print(case+': passed (isolated CLI fixtures; no Apple/GitHub requests)')

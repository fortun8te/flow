from pathlib import Path
import json,struct,re,hashlib,wave,io,os
archive=Path('/Applications/Wispr Flow.app/Contents/Resources/app.asar')
mapping={'start':'Qd','stop':'Zd','error':'ec','done':'ic','lock':'rc'}
root=Path.home()/'Library/Application Support/Flow/ReferenceSounds'
if root.parent.is_symlink() or root.is_symlink():
 raise SystemExit('Refusing a symbolic link in Flow reference sound storage.')
root.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
os.chmod(root.parent,0o700)
root.mkdir(parents=True,exist_ok=True,mode=0o700)
os.chmod(root,0o700)
manifest={}
with archive.open('rb') as f:
 head=f.read(16);data_start=8+struct.unpack('<I',head[4:8])[0];n=struct.unpack('<I',head[12:16])[0];index=json.loads(f.read(n))
 node=index
 for part in '.webpack/renderer/status/index.js'.split('/'):node=node['files'][part]
 f.seek(data_start+int(node['offset']));renderer=f.read(int(node['size']))
 if hashlib.sha256(renderer).hexdigest() != 'eca8d951c64b16265dad39f3917701e687d56b0a056326b940ff37e799450f65':
  raise SystemExit('This Wispr renderer version has not been verified. Re-trace its sound mapping before importing.')
 s=renderer.decode('utf-8')
 for cue,symbol in mapping.items():
  match=re.search(r'(?<![A-Za-z])'+symbol+r'=o\.p\+"([^"]+\.wav)"',s)
  if not match:raise RuntimeError('missing mapping '+cue)
  path='.webpack/renderer/'+match.group(1);node=index
  for part in path.split('/'):node=node['files'][part]
  f.seek(data_start+int(node['offset']));data=f.read(int(node['size']))
  with wave.open(io.BytesIO(data)) as w:duration=w.getnframes()/w.getframerate()
  out=root/(cue+'.wav');out.write_bytes(data);os.chmod(out,0o600)
  manifest[cue]={'member':path,'sha256':hashlib.sha256(data).hexdigest(),'durationSeconds':duration}
(root/'manifest.json').write_text(json.dumps(manifest,indent=2));os.chmod(root/'manifest.json',0o600)
print(json.dumps({k:round(v['durationSeconds']*1000,3) for k,v in manifest.items()}))

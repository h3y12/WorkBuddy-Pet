"""Create a complete, hash-checked script pet release using only the bundled stdlib."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--output-dir',type=Path,default=root/'dist')
parser.add_argument('--include-local-artwork',action='store_true',help='Include private artwork in a personal package only')
args=parser.parse_args()
version=re.search(r"\$script:version = '([^']+)'",(root/'app/Pet.ps1').read_text(encoding='utf-8-sig')).group(1)
number=version.removesuffix('-script')
output=args.output_dir.resolve()
output.mkdir(parents=True,exist_ok=True)
excluded={'dist','.git','__pycache__'}
files={}
for path in sorted(root.rglob('*')):
    relative=path.relative_to(root)
    if not path.is_file() or set(relative.parts)&excluded or path.suffix in {'.pyc','.pyo','.tmp','.log'} or path.name in {'MANIFEST.json','startup-error.txt'}:
        continue
    if path.resolve().is_relative_to(output):continue
    if path.name=='mascot.local.png' and not args.include_local_artwork:continue
    files[relative.as_posix()]=hashlib.sha256(path.read_bytes()).hexdigest()
manifest={'version':version,'files':files}
(root/'MANIFEST.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
archive=output/f'WbPet-script-{number}-win-x64.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for name in list(files)+['MANIFEST.json']:z.write(root/name,name)
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    actual=json.loads(z.read('MANIFEST.json'))
    for name,digest in actual['files'].items():
        assert hashlib.sha256(z.read(name)).hexdigest()==digest,name
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_name(archive.name+'.sha256').write_text(digest+'\n',encoding='ascii')
print(json.dumps({'archive':str(archive),'bytes':archive.stat().st_size,'version':version,'files_verified':len(files),'sha256':digest}))

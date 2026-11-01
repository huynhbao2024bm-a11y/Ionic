"""Download only pinned public model artifacts; never accepts user/post input."""
import hashlib
import json
import os
from pathlib import Path
import urllib.request

manifest = json.loads(Path(__file__).with_name('model_manifest.json').read_text('utf-8'))
root = Path(os.environ.get('IONIC_MODEL_DIR', '../../.models/e5-small')).resolve()
root.mkdir(parents=True, exist_ok=True)
for name, metadata in manifest['files'].items():
    target = root / name
    if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == metadata['sha256']:
        print(f'Verified {name}', flush=True)
        continue
    url = f"https://huggingface.co/{manifest['modelId']}/resolve/{manifest['revision']}/{metadata['remote']}"
    temporary = target.with_suffix('.part')
    digest, count = hashlib.sha256(), 0
    with urllib.request.urlopen(url, timeout=60) as response, temporary.open('wb') as output:
        while chunk := response.read(1024 * 1024):
            count += len(chunk)
            if count > metadata['bytes']:
                raise RuntimeError('Model download exceeds pinned byte size')
            digest.update(chunk)
            output.write(chunk)
    if count != metadata['bytes'] or digest.hexdigest() != metadata['sha256']:
        temporary.unlink(missing_ok=True)
        raise RuntimeError('Model artifact failed integrity check')
    temporary.replace(target)
    print(f'Verified {name}: {count} bytes', flush=True)
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')

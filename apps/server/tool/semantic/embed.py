"""Offline-only embedding process. stdin/stdout are bounded JSON lines.

No network, remote code loading, post logging, or per-user state is used here.
The Dart worker alone authorizes and persists derived public-content features.
"""
import hashlib
import json
import os
from pathlib import Path
import sys
import time

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer


class EmbeddingModel:
    def __init__(self):
        self.manifest = json.loads(Path(__file__).with_name('model_manifest.json').read_text('utf-8'))
        root = Path(os.environ.get('IONIC_MODEL_DIR', '../../.models/e5-small')).resolve()
        for name, metadata in self.manifest['files'].items():
            path = root / name
            if path.stat().st_size != metadata['bytes'] or hashlib.sha256(path.read_bytes()).hexdigest() != metadata['sha256']:
                raise RuntimeError('Pinned artifact integrity check failed')
        self.tokenizer = Tokenizer.from_file(str(root / 'tokenizer.json'))
        self.tokenizer.enable_truncation(max_length=512)
        self.tokenizer.enable_padding(pad_id=self.tokenizer.token_to_id('<pad>'), pad_token='<pad>')
        options = ort.SessionOptions()
        options.intra_op_num_threads = min(4, max(1, int(os.environ.get('IONIC_EMBED_THREADS', '2'))))
        options.inter_op_num_threads = 1
        self.session = ort.InferenceSession(str(root / 'model.onnx'), sess_options=options,
                                            providers=['CPUExecutionProvider'])
        self.inputs = {i.name for i in self.session.get_inputs()}

    def encode(self, texts):
        if not isinstance(texts, list) or not 1 <= len(texts) <= 16:
            raise ValueError('Batch must contain 1..16 texts')
        if any(not isinstance(t, str) or not t.strip() or len(t) > 1024 for t in texts):
            raise ValueError('Invalid bounded text')
        encoded = self.tokenizer.encode_batch([self.manifest['prefix'] + t.strip() for t in texts])
        values = {
            'input_ids': np.asarray([e.ids for e in encoded], dtype=np.int64),
            'attention_mask': np.asarray([e.attention_mask for e in encoded], dtype=np.int64),
            'token_type_ids': np.asarray([e.type_ids for e in encoded], dtype=np.int64),
        }
        hidden = self.session.run(None, {k: v for k, v in values.items() if k in self.inputs})[0]
        mask = values['attention_mask'][..., None].astype(np.float32)
        pooled = (hidden * mask).sum(axis=1) / np.maximum(mask.sum(axis=1), 1)
        normalized = pooled / np.maximum(np.linalg.norm(pooled, axis=1, keepdims=True), 1e-12)
        if normalized.shape != (len(texts), self.manifest['dimensions']) or not np.isfinite(normalized).all():
            raise RuntimeError('Invalid embedding output')
        return normalized.astype(np.float32)


def main():
    model = EmbeddingModel()
    print(json.dumps({'ready': model.manifest['version'], 'dimensions': model.manifest['dimensions']}), flush=True)
    while line := sys.stdin.readline(65537):
        try:
            if len(line) > 65536 or not line.endswith('\n'):
                raise ValueError('Input line exceeds limit')
            request = json.loads(line)
            started = time.perf_counter()
            result = model.encode(request['texts'])
            print(json.dumps({'version': model.manifest['version'], 'vectors': result.tolist(),
                              'inferenceMs': (time.perf_counter() - started) * 1000}), flush=True)
        except Exception as error:
            # Never echo input or model-runtime diagnostics containing content.
            print(json.dumps({'error': type(error).__name__}), flush=True)


if __name__ == '__main__':
    main()

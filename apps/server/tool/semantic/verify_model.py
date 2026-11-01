import ctypes
import json
from pathlib import Path
import time
import numpy as np
from embed import EmbeddingModel

started = time.perf_counter()
model = EmbeddingModel()
load_ms = (time.perf_counter() - started) * 1000
dataset = json.loads((Path(__file__).parents[2] / 'data/recommendation/semantic-challenge-v1.json').read_text('utf-8'))
results, latencies = [], []
for case in dataset['cases']:
    begin = time.perf_counter()
    vectors = model.encode([case['seed'], case['related'], case['unrelated']])
    latencies.append((time.perf_counter() - begin) * 1000)
    positive, negative = float(vectors[0] @ vectors[1]), float(vectors[0] @ vectors[2])
    results.append({'id': case['id'], 'relatedCosine': positive, 'unrelatedCosine': negative,
                    'margin': positive - negative, 'correctOrder': positive > negative})
repeat = model.encode(['Kiểm tra tính ổn định của mô hình.'] * 2)
if not np.allclose(repeat[0], repeat[1], atol=1e-5):
    raise RuntimeError('Embedding repeatability failure')
memory_mib = None
try:
    class Counters(ctypes.Structure):
        _fields_ = [('cb', ctypes.c_ulong), ('PageFaultCount', ctypes.c_ulong)] + [
            (name, ctypes.c_size_t) for name in ['PeakWorkingSetSize', 'WorkingSetSize', 'QuotaPeakPagedPoolUsage',
                'QuotaPagedPoolUsage', 'QuotaPeakNonPagedPoolUsage', 'QuotaNonPagedPoolUsage', 'PagefileUsage',
                'PeakPagefileUsage', 'PrivateUsage']]
    counters = Counters()
    counters.cb = ctypes.sizeof(counters)
    ctypes.windll.kernel32.GetCurrentProcess.restype = ctypes.c_void_p
    ctypes.windll.psapi.GetProcessMemoryInfo.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong]
    if ctypes.windll.psapi.GetProcessMemoryInfo(ctypes.windll.kernel32.GetCurrentProcess(), ctypes.byref(counters), counters.cb):
        memory_mib = counters.WorkingSetSize / 1024**2
except (AttributeError, OSError):
    pass
print(json.dumps({'datasetVersion': dataset['version'], 'source': dataset['source'], 'model': model.manifest['version'],
    'dimensions': model.manifest['dimensions'], 'loadMs': load_ms, 'threeTextBatchMedianMs': float(np.median(latencies)),
    'workingSetMiB': memory_mib, 'correctPairs': sum(r['correctOrder'] for r in results), 'pairCount': len(results),
    'repeatabilityVerified': True, 'results': results}, indent=2))

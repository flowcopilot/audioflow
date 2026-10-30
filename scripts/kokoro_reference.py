"""Record independent Kokoro durations with ONNX Runtime.

Run: uv run --with numpy --with onnxruntime scripts/kokoro_reference.py MODEL_DIR
MODEL_DIR must contain the pinned ONNX graph, tokenizer.json, and voice files.
The upstream graph phase correction changes audio samples, not their count.
"""
import json
import pathlib
import sys
import numpy as np
import onnxruntime as ort

root = pathlib.Path(sys.argv[1])
vocabulary = json.loads((root / 'tokenizer.json').read_text())['model']['vocab']
options = ort.SessionOptions()
options.intra_op_num_threads = 2
options.inter_op_num_threads = 1
session = ort.InferenceSession(str(root / 'onnx/model.onnx'), options, providers=['CPUExecutionProvider'])
cases = [
    {'phonemes': 'həlˈO.', 'voice': 'af_heart', 'speed': 1.0},
    {'phonemes': 'həlˈO.', 'voice': 'am_adam', 'speed': 1.0},
    {'phonemes': 'həlˈO.', 'voice': 'af_heart', 'speed': 1.2},
    {'text': 'Hello, my dog is cute.', 'phonemes': 'həlˈO, mI dˈɑɡ ɪz kjˈut.', 'voice': 'af_heart', 'speed': 1.0},
]
for case in cases:
    phonemes = case['phonemes']
    style = np.fromfile(root / f"voices/{case['voice']}.bin", dtype='<f4').reshape(-1, 256)
    ids = np.array([[0] + [vocabulary[c] for c in phonemes] + [0]], dtype=np.int64)
    output = session.run(None, {
        'input_ids': ids,
        'style': style[len(phonemes) - 1:len(phonemes)],
        'speed': np.array([case['speed']], dtype=np.float32),
    })[0]
    case['samples'] = int(output.size)
print(json.dumps({'repository': 'onnx-community/Kokoro-82M-v1.0-ONNX',
    'revision': '1939ad2a8e416c0acfeecc08a694d14ef25f2231', 'cases': cases}, indent=2))

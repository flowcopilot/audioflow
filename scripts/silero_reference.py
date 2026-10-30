"""Record an independent ONNX Runtime reference for the pinned Silero export.

Run: uv run --with numpy --with onnxruntime scripts/silero_reference.py MODEL
The reference uses deterministic PCM; it needs no speech recording.
"""
import json
import sys
import numpy as np
import onnxruntime as ort

session = ort.InferenceSession(sys.argv[1], providers=["CPUExecutionProvider"])
state = np.zeros((2, 1, 128), dtype=np.float32)
context = np.zeros((1, 64), dtype=np.float32)
probabilities = []
for frame in range(4):
    pcm = np.array([((frame * 512 + i) * 7919) % 65536 - 32768 for i in range(512)], dtype=np.int16)
    samples = pcm.astype(np.float32).reshape(1, 512) / 32768
    probability, state = session.run(None, {
        "input": np.concatenate([context, samples], axis=1),
        "state": state,
        "sr": np.array(16000, dtype=np.int64),
    })
    context = samples[:, -64:]
    probabilities.append(float(probability.item()))
print(json.dumps({"probabilities": probabilities}))

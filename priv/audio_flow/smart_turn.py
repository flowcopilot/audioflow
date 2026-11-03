"""Persistent Smart Turn v3.1 CPU worker; no implicit network/model downloads.

Reference: pipecat-ai/smart-turn@4786657e242dfe77dd138699ac564ee074a2a543
Model: pipecat-ai/smart-turn-v3@f766f81d3cfdf7737ac64aad813d91bbfd56bf93
"""

import hashlib
import struct
import sys

import numpy as np
import onnxruntime as ort
from transformers import WhisperFeatureExtractor


def send(payload):
    sys.stdout.buffer.write(struct.pack(">I", len(payload)) + payload)
    sys.stdout.buffer.flush()


def read_exact(n):
    data = bytearray()
    while len(data) < n:
        chunk = sys.stdin.buffer.read(n - len(data))
        if not chunk:
            raise EOFError("truncated packet")
        data.extend(chunk)
    return bytes(data)


def main():
    with open(sys.argv[1], "rb") as model_file:
        digest = hashlib.file_digest(model_file, "sha256").hexdigest()
    if digest != "fb68d55c2d542ce79e44b12013bfd571e90df8594ab096d757198e851b0c6594":
        raise ValueError(
            "expected pinned smart-turn-v3.1-cpu.onnx; see docs/input-processing.md"
        )
    options = ort.SessionOptions()
    options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    options.inter_op_num_threads = 1
    options.intra_op_num_threads = 1
    session = ort.InferenceSession(
        sys.argv[1], sess_options=options, providers=["CPUExecutionProvider"]
    )
    extractor = WhisperFeatureExtractor(chunk_length=8)
    send(b"ready")
    while True:
        header = sys.stdin.buffer.read(4)
        if not header:
            return
        if len(header) != 4:
            raise EOFError("truncated header")
        (length,) = struct.unpack(">I", header)
        if length > 256000 or length % 2:
            raise ValueError("expected at most eight seconds of s16le PCM")
        audio = (
            np.frombuffer(read_exact(length), dtype="<i2").astype(np.float32) / 32768.0
        )
        audio = np.pad(audio[-128000:], (max(0, 128000 - len(audio)), 0))
        inputs = extractor(
            audio,
            sampling_rate=16000,
            return_tensors="np",
            padding="max_length",
            max_length=128000,
            truncation=True,
            do_normalize=True,
        )
        features = inputs.input_features.astype(np.float32)
        probability = float(
            session.run(None, {"input_features": features})[0].reshape(-1)[0]
        )
        if not np.isfinite(probability) or not 0 <= probability <= 1:
            raise ValueError("invalid completion probability")
        send(str(probability).encode("ascii"))


if __name__ == "__main__":
    main()

# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["mlx-audio==0.6.3"]
# ///
"""Qwen3-ASR on the Apple GPU through mlx-audio, for the chat example.

Protocol: one JSON object per line on stdin and stdout.
  {"id": 1, "model": "mlx-community/Qwen3-ASR-0.6B-8bit", "revision": "<commit>",
   "pcm": "<base64 16 kHz s16le>"}
  -> {"id": 1, "text": "..."} or {"id": 1, "error": "..."}
The first request for a model loads it. One model stays loaded. A request
without "pcm" only loads the model.
"""

import base64
import json
import sys

import numpy as np
from mlx_audio.stt.utils import load_model

loaded = {}


def model_for(name, revision):
    key = (name, revision)
    if key not in loaded:
        loaded.clear()
        loaded[key] = load_model(name, revision=revision)
    return loaded[key]


def reply(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    request = json.loads(line)
    try:
        model = model_for(request["model"], request.get("revision"))
        if "pcm" not in request:
            reply({"id": request["id"], "text": ""})
            continue
        pcm = np.frombuffer(base64.b64decode(request["pcm"]), dtype="<i2")
        audio = pcm.astype(np.float32) / 32768.0
        result = model.generate(audio, language=request.get("language"))
        reply({"id": request["id"], "text": result.text.strip()})
    except Exception as error:  # noqa: BLE001 - the caller receives every failure
        reply({"id": request.get("id"), "error": f"{type(error).__name__}: {error}"})

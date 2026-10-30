"""Independent CPU references for the pinned embedding and caption models.

env -u HF_TOKEN -u HUGGING_FACE_HUB_TOKEN HF_TOKEN_PATH=/dev/null \
  uv run --with transformers==4.57.1 --with torch==2.15.0 --with pillow==13.0.0 \
  scripts/multimodal_reference.py > test/fixtures/multimodal_reference.json

Uses the cat image from the Transmuter revision in mix.lock. No AudioFlow code
is imported. Text vectors use attention-masked mean pooling and normalization.
CLIP vectors use the trained visual projection and normalization.
"""
import hashlib
import json
from pathlib import Path

import torch
import transformers
import PIL
from PIL import Image
from transformers import AutoModel, AutoTokenizer, BlipForConditionalGeneration, BlipProcessor
from transformers import CLIPModel, CLIPProcessor

torch.set_num_threads(2)
torch.manual_seed(0)
fixture = Path(__file__).resolve().parents[1] / "deps/transmuter/test/fixtures/cats.png"
image = Image.open(fixture).convert("RGB")
text_repository = "sentence-transformers/all-MiniLM-L6-v2"
text_revision = "1110a243fdf4706b3f48f1d95db1a4f5529b4d41"
clip_repository = "openai/clip-vit-base-patch32"
clip_revision = "3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268"
caption_repository = "Salesforce/blip-image-captioning-base"
caption_revision = "82a37760796d32b1411fe092ab5d4e227313294b"
texts = ["Two cats are resting on a couch.", "A spacecraft orbits a distant planet."]

with torch.inference_mode():
    tokenizer = AutoTokenizer.from_pretrained(text_repository, revision=text_revision, token=False)
    model = AutoModel.from_pretrained(text_repository, revision=text_revision, token=False).eval()
    inputs = tokenizer(texts, padding="max_length", truncation=True, max_length=64, return_tensors="pt")
    hidden = model(**inputs).last_hidden_state
    mask = inputs["attention_mask"].unsqueeze(-1)
    vectors = torch.nn.functional.normalize((hidden * mask).sum(1) / mask.sum(1), dim=-1)
    text_vectors = vectors.tolist()
    del model

    processor = CLIPProcessor.from_pretrained(clip_repository, revision=clip_revision, token=False, use_fast=False)
    model = CLIPModel.from_pretrained(clip_repository, revision=clip_revision, token=False).eval()
    pixels = processor(images=image, return_tensors="pt")["pixel_values"]
    vector = torch.nn.functional.normalize(model.get_image_features(pixel_values=pixels), dim=-1)
    image_vector = vector[0].tolist()
    del model

    processor = BlipProcessor.from_pretrained(caption_repository, revision=caption_revision, token=False, use_fast=False)
    model = BlipForConditionalGeneration.from_pretrained(
        caption_repository, revision=caption_revision, token=False
    ).eval()
    inputs = processor(images=image, return_tensors="pt")
    ids = model.generate(**inputs, max_new_tokens=32, do_sample=False, num_beams=1)
    caption = processor.decode(ids[0], skip_special_tokens=True)

print(json.dumps({
    "torch": torch.__version__, "transformers": transformers.__version__, "pillow": PIL.__version__,
    "image": {"repository": "georgeguimaraes/transmuter",
        "revision": "231028d9ff6f53bd58fa15d9f24d632258369805",
        "file": "test/fixtures/cats.png", "width": image.width, "height": image.height,
        "rgb_sha256": hashlib.sha256(image.tobytes()).hexdigest()},
    "text": {"repository": text_repository, "revision": text_revision,
        "sequence_length": 64, "inputs": texts, "vectors": text_vectors},
    "clip": {"repository": clip_repository, "revision": clip_revision, "vector": image_vector},
    "caption": {"repository": caption_repository, "revision": caption_revision,
        "max_new_tokens": 32, "text": caption}
}, indent=2))

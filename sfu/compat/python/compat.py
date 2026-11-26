"""Checks that the LiveKit Python SDK works with the AudioFlow SFU.

Alice publishes a 440 Hz tone; Bob subscribes and must hear it. The SFU must
run at SFU_URL with API_KEY and API_SECRET.
"""

import asyncio
import base64
import hashlib
import hmac
import json
import math
import os
import time

import numpy as np
from livekit import rtc

URL = os.environ.get("SFU_URL", "ws://127.0.0.1:7880")
KEY = os.environ.get("API_KEY", "devkey")
SECRET = os.environ.get("API_SECRET", "devsecret")
ROOM = f"py-compat-{int(time.time() * 1000)}"
RATE = 48_000


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token(identity: str) -> str:
    now = int(time.time())
    claims = {
        "iss": KEY,
        "sub": identity,
        "nbf": now,
        "exp": now + 600,
        "video": {
            "room": ROOM,
            "roomJoin": True,
            "canPublish": True,
            "canSubscribe": True,
        },
    }
    body = (
        b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
        + "."
        + b64(json.dumps(claims).encode())
    )
    signature = hmac.new(SECRET.encode(), body.encode(), hashlib.sha256).digest()
    return body + "." + b64(signature)


async def tone(source: rtc.AudioSource, stop: asyncio.Event) -> None:
    samples = RATE // 100
    n = 0
    while not stop.is_set():
        t = (np.arange(samples) + n) / RATE
        data = (np.sin(2 * math.pi * 440 * t) * 12_000).astype(np.int16)
        await source.capture_frame(rtc.AudioFrame(data.tobytes(), RATE, 1, samples))
        n += samples


async def main() -> None:
    alice, bob = rtc.Room(), rtc.Room()
    heard = asyncio.Event()
    loud = 0

    async def listen(track: rtc.Track) -> None:
        nonlocal loud
        async for event in rtc.AudioStream(track, sample_rate=RATE, num_channels=1):
            if np.abs(np.frombuffer(event.frame.data, dtype=np.int16)).max() > 2_000:
                loud += 1
            if loud >= 25:
                heard.set()
                return

    @bob.on("track_subscribed")
    def on_track(
        track: rtc.Track, _publication, participant: rtc.RemoteParticipant
    ) -> None:
        print("bob subscribed to", participant.identity, track.sid)
        if track.kind == rtc.TrackKind.KIND_AUDIO:
            asyncio.ensure_future(listen(track))

    await alice.connect(URL, token("alice"))
    print("alice joined", alice.local_participant.sid)
    source = rtc.AudioSource(RATE, 1)
    track = rtc.LocalAudioTrack.create_audio_track("microphone", source)
    options = rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
    await alice.local_participant.publish_track(track, options)
    stop = asyncio.Event()
    sender = asyncio.ensure_future(tone(source, stop))

    await bob.connect(URL, token("bob"))
    print("bob joined", bob.local_participant.sid)
    try:
        await asyncio.wait_for(heard.wait(), 20)
        print("PASS livekit Python SDK compatibility")
    finally:
        stop.set()
        await sender
        await bob.disconnect()
        await alice.disconnect()


if __name__ == "__main__":
    asyncio.run(main())

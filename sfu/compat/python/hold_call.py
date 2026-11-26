"""Holds a two-party call through the SFU and reports audio gaps.

Alice sends a 440 Hz tone; Bob listens. After the call carries audio, the
script writes READY_FILE. It stops when STOP_FILE exists and prints JSON with
the longest gap between audible frames and the number of reconnects.
"""

import asyncio
import json
import os
import time
from pathlib import Path

import numpy as np
from compat import RATE, URL, token, tone
from livekit import rtc

READY = os.environ["READY_FILE"]
STOP = os.environ["STOP_FILE"]


async def main() -> None:
    alice, bob = rtc.Room(), rtc.Room()
    last = None
    max_gap = 0.0
    audible = 0
    reconnects = 0

    async def listen(track: rtc.Track) -> None:
        nonlocal last, max_gap, audible
        async for event in rtc.AudioStream(track, sample_rate=RATE, num_channels=1):
            if np.abs(np.frombuffer(event.frame.data, dtype=np.int16)).max() > 2_000:
                now = time.monotonic()
                if last is not None and audible > 50:
                    max_gap = max(max_gap, now - last)
                last = now
                audible += 1

    @bob.on("track_subscribed")
    def on_track(track: rtc.Track, _publication, _participant) -> None:
        asyncio.ensure_future(listen(track))

    def reconnected(*_args) -> None:
        nonlocal reconnects
        reconnects += 1

    for room in (alice, bob):
        room.on("reconnecting", reconnected)

    await alice.connect(URL, token("alice"))
    source = rtc.AudioSource(RATE, 1)
    track = rtc.LocalAudioTrack.create_audio_track("microphone", source)
    await alice.local_participant.publish_track(
        track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
    )
    stop = asyncio.Event()
    sender = asyncio.ensure_future(tone(source, stop))
    await bob.connect(URL, token("bob"))

    while audible < 100:
        await asyncio.sleep(0.05)
    await asyncio.to_thread(Path(READY).touch)
    while not os.path.exists(STOP):
        await asyncio.sleep(0.05)

    stop.set()
    await sender
    print(
        json.dumps(
            {
                "max_gap_ms": round(max_gap * 1000),
                "audible": audible,
                "reconnects": reconnects,
            }
        )
    )
    await bob.disconnect()
    await alice.disconnect()


if __name__ == "__main__":
    asyncio.run(main())

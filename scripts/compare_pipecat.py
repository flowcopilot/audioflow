# /// script
# requires-python = ">=3.12"
# dependencies = ["pipecat-ai==1.14.0"]
# ///
"""Compare orchestration over identical shared Nx models. See scripts/COMPARISON.md.

Run with `uv run scripts/compare_pipecat.py --help`. Models stay in one Elixir
process. Pipecat uses a private pipe for each inference stage. There is no
network listener or sound device. All raw attempt rows are saved as JSON.
"""
import argparse
import asyncio
import base64
from datetime import datetime, timezone
from dataclasses import dataclass
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import sys
import time

from loguru import logger
logger.remove()
logger.add(sys.stderr, level="WARNING")
from pipecat.frames.frames import (
    DataFrame, EndFrame, InterruptionFrame, OutputAudioRawFrame, StartFrame,
    TextFrame, TranscriptionFrame,
)
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineParams, PipelineWorker
from pipecat.processors.frame_processor import FrameProcessor
from pipecat.workers.runner import WorkerRunner

PREFIX = b"AUDIOFLOW_BENCH "
ROOT = Path(__file__).resolve().parents[1]


class Bridge:
    def __init__(self, process, log):
        self.process, self.log = process, log
        self.pending = {}
        self.sequence = 0
        self.lock = asyncio.Lock()
        self.ready = asyncio.get_running_loop().create_future()
        self.reader = asyncio.create_task(self.read())

    async def read(self):
        try:
            while line := await self.process.stdout.readline():
                if not line.startswith(PREFIX):
                    self.log.write(line)
                    self.log.flush()
                    continue
                message = json.loads(line[len(PREFIX):])
                if message.get("ready"):
                    self.ready.set_result(message)
                elif queue := self.pending.get(message["id"]):
                    await queue.put(message)
            raise RuntimeError(f"Model bridge stopped: {await self.process.wait()}")
        except Exception as error:
            if not self.ready.done():
                self.ready.set_exception(error)
            for queue in list(self.pending.values()):
                await queue.put({"error": str(error), "done": True})

    async def send(self, message):
        async with self.lock:
            self.process.stdin.write(json.dumps(message).encode() + b"\n")
            await self.process.stdin.drain()

    async def stream(self, **request):
        self.sequence += 1
        request_id = self.sequence
        queue = self.pending[request_id] = asyncio.Queue(maxsize=8)
        finished = False
        try:
            await self.send(dict(request, id=request_id))
            while True:
                message = await queue.get()
                if message.get("error"):
                    raise RuntimeError(message["error"])
                if message.get("done"):
                    finished = True
                    if message.get("result") is not None:
                        yield message["result"]
                    break
                yield message["output"]
        finally:
            self.pending.pop(request_id, None)
            # Release a reader that was waiting on this request's bounded queue.
            while not queue.empty():
                queue.get_nowait()
            if not finished and self.process.returncode is None:
                await self.send({"op": "cancel", "target": request_id})

    async def call(self, **request):
        result = [item async for item in self.stream(**request)]
        if len(result) != 1:
            raise RuntimeError("Expected one bridge result")
        return result[0]

    async def close(self):
        self.process.stdin.close()
        try:
            await asyncio.wait_for(self.process.wait(), 15)
        except TimeoutError:
            self.process.terminate()
            await self.process.wait()
        self.reader.cancel()
        await asyncio.gather(self.reader, return_exceptions=True)


@dataclass
class FileFrame(DataFrame):
    path: str


@dataclass
class UtteranceFrame(DataFrame):
    audio: str


@dataclass
class TurnDoneFrame(DataFrame):
    pass


def now_us():
    return time.perf_counter_ns() // 1000


class Processor(FrameProcessor):
    """Acknowledge each data frame to bound queues between benchmark stages."""
    async def push_ack(self, frame, direction):
        frame.bench_ack = asyncio.get_running_loop().create_future()
        await self.push_frame(frame, direction)
        await frame.bench_ack

    async def process_frame(self, frame, direction):
        await super().process_frame(frame, direction)
        try:
            await self.process(frame, direction)
        finally:
            ack = getattr(frame, "bench_ack", None)
            if ack is not None and not ack.done():
                ack.set_result(None)

    async def process(self, frame, direction):
        await self.push_frame(frame, direction)


class Ingress(Processor):
    def __init__(self, bridge, state):
        super().__init__()
        self.bridge, self.state = bridge, state

    async def process(self, frame, direction):
        if isinstance(frame, FileFrame):
            result = await self.bridge.call(op="ingress", path=frame.path)
            self.state.update(utterance_sha256=result["sha256"], utterance_bytes=result["bytes"])
            await self.push_ack(UtteranceFrame(result["audio"]), direction)
            await self.push_frame(TurnDoneFrame(), direction)
        else:
            await self.push_frame(frame, direction)


class Stage(Processor):
    def __init__(self, bridge, stage, state):
        super().__init__()
        self.bridge, self.stage, self.state = bridge, stage, state

    async def process(self, frame, direction):
        kind = {"stt": UtteranceFrame, "llm": TranscriptionFrame, "tts": TextFrame}[self.stage]
        if not isinstance(frame, kind):
            await self.push_frame(frame, direction)
            return
        value = frame.audio if self.stage == "stt" else frame.text
        async for item in self.bridge.stream(op="stage", stage=self.stage, input=value):
            elapsed = now_us() - self.state["started"]
            if self.stage == "stt":
                self.state["first_transcript_us"] = self.state["first_transcript_us"] or elapsed
                self.state["transcript"] += item["text"]
                output = TranscriptionFrame(item["text"], "recording", "", finalized=True)
            elif self.stage == "llm":
                self.state["first_text_us"] = self.state["first_text_us"] or elapsed
                self.state["reply"] += item["text"]
                output = TextFrame(item["text"])
            else:
                self.state["first_audio_us"] = self.state["first_audio_us"] or elapsed
                output = OutputAudioRawFrame(base64.b64decode(item["audio"]), item["sample_rate"], 1)
            await self.push_ack(output, direction)


class Sink(Processor):
    def __init__(self, state, interrupt):
        super().__init__()
        self.state, self.interrupt = state, interrupt
        self.started = asyncio.Event()
        self.first = asyncio.Event()
        self.done = asyncio.Event()
        self.flushed = asyncio.Event()
        self.hold = asyncio.Event()
        self.hasher = hashlib.sha256()

    async def process(self, frame, direction):
        if isinstance(frame, StartFrame):
            self.started.set()
        elif isinstance(frame, OutputAudioRawFrame):
            self.state["first_output_us"] = self.state["first_output_us"] or now_us() - self.state["started"]
            self.state["output_bytes"] += len(frame.audio)
            self.hasher.update(frame.audio)
            self.first.set()
            if self.interrupt:
                await self.hold.wait()
        elif isinstance(frame, InterruptionFrame):
            self.flushed.set()
        elif isinstance(frame, TurnDoneFrame):
            self.done.set()
        await self.push_frame(frame, direction)


async def pipecat_turn(bridge, path, interrupt):
    state = dict(started=0, first_transcript_us=None, first_text_us=None,
                 first_audio_us=None, first_output_us=None, duration_us=None,
                 interrupt_us=None, transcript="", reply="", output_bytes=0, status="ok")
    sink = Sink(state, interrupt)
    pipeline = Pipeline([Ingress(bridge, state), Stage(bridge, "stt", state),
                         Stage(bridge, "llm", state), Stage(bridge, "tts", state), sink])
    worker = PipelineWorker(pipeline, params=PipelineParams(), enable_rtvi=False,
                            enable_turn_tracking=False, idle_timeout_secs=None)
    runner = WorkerRunner(handle_sigint=False, handle_sigterm=False, force_gc=False)
    await runner.add_workers(worker)
    running = asyncio.create_task(runner.run())
    try:
        await asyncio.wait_for(sink.started.wait(), 30)
        state["started"] = now_us()
        await worker.queue_frame(FileFrame(str(path)))
        if interrupt:
            await asyncio.wait_for(sink.first.wait(), 180)
            at = now_us()
            await worker.queue_frame(InterruptionFrame())
            await asyncio.wait_for(sink.flushed.wait(), 5)
            state["interrupt_us"] = now_us() - at
            state["status"] = "cancelled"
            count = state["output_bytes"]
            await asyncio.sleep(0.1)
            if state["output_bytes"] != count:
                raise RuntimeError("Audio arrived after interruption acknowledgement")
        else:
            await asyncio.wait_for(sink.done.wait(), 180)
        state["duration_us"] = now_us() - state["started"]
        await worker.queue_frame(EndFrame())
        await asyncio.wait_for(running, 30)
        if state["output_bytes"] == 0:
            raise RuntimeError("No output audio")
        state["output_sha256"] = sink.hasher.hexdigest()
        return {key: value for key, value in state.items() if key != "started"}
    finally:
        if not running.done():
            await worker.cancel()
            await asyncio.wait_for(running, 30)


async def main(args):
    paths = [Path(path).resolve() for path in args.inputs]
    for path in paths:
        if not path.is_file():
            raise ValueError(f"Missing input: {path}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    log = args.output.with_suffix(".log").open("wb")
    environment = dict(os.environ, AUDIOFLOW_ML="1", AUDIOFLOW_MEDIA="1",
                       AUDIOFLOW_LLM="Qwen/Qwen3-0.6B", AUDIOFLOW_LLM_ENGINE="nx",
                       AUDIOFLOW_LLM_REVISION="c1899de289a04d12100db370d81485cdf75e47ca",
                       AUDIOFLOW_HISTORY="0", AUDIOFLOW_TTS="kokoro", AUDIOFLOW_VOICE="af_heart")
    environment.pop("AUDIOFLOW_TTS_CONFIG", None)
    process = await asyncio.create_subprocess_exec(
        "elixir", "-S", "mix", "run", "scripts/compare_bridge.exs", cwd=ROOT,
        env=environment, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=log, limit=2_000_000)
    bridge = Bridge(process, log)
    rows = []
    metadata = dict(schema_version=1, python=sys.version, platform=platform.platform(),
                    started_utc=datetime.now(timezone.utc).isoformat(),
                    pipecat=importlib.metadata.version("pipecat-ai"), arguments=vars(args).copy(),
                    runner_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                    capacity_rule=dict(max_error_rate=0, p95_first_output_us=args.max_first_output_ms * 1000,
                                       percentile="nearest_rank", workload="closed_fixed_groups"),
                    inputs=[dict(path=str(p), bytes=p.stat().st_size,
                                 sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in paths])
    metadata["arguments"]["output"] = str(args.output)
    setup_at = now_us()

    async def attempt(framework, path, interrupt, phase, concurrency, index):
        started = now_us()
        try:
            async with asyncio.timeout(200):
                if framework == "audioflow":
                    result = await bridge.call(op="native", path=str(path), interrupt=interrupt)
                else:
                    result = await pipecat_turn(bridge, path, interrupt)
        except Exception as error:
            result = dict(status="error", error=str(error), duration_us=now_us() - started)
        row = dict(framework=framework, input=path.name, input_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                   phase=phase, concurrency=concurrency, run=index, interrupt=interrupt, **result)
        rows.append(row)
        args.output.write_text(json.dumps(dict(metadata=metadata, rows=rows), indent=2) + "\n")
        print(f"{framework} c={concurrency} {phase} {index}: {result['status']}", flush=True)

    try:
        metadata["bridge"] = await asyncio.wait_for(bridge.ready, 600)
        metadata["setup_us"] = now_us() - setup_at
        for level, concurrency in enumerate(args.concurrency):
            frameworks = args.frameworks if level % 2 == 0 else list(reversed(args.frameworks))
            for framework in frameworks:
                for phase, count in (("warmup", args.warmup), ("measured", args.runs)):
                    # Fixed groups reach the requested concurrency. This is a closed workload.
                    for start in range(0, count, concurrency):
                        await asyncio.gather(*(attempt(framework, paths[i % len(paths)], False,
                                                     phase, concurrency, i + 1)
                                               for i in range(start, min(start + concurrency, count))))
                for index in range(args.interrupt_runs):
                    await attempt(framework, paths[index % len(paths)], True, "interruption", concurrency, index + 1)
    finally:
        metadata["finished_utc"] = datetime.now(timezone.utc).isoformat()
        args.output.write_text(json.dumps(dict(metadata=metadata, rows=rows), indent=2) + "\n")
        await bridge.close()
        log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", help="Mono s16le PCM files at 16 kHz; one utterance each")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--concurrency", nargs="+", type=int, default=[1, 2, 4])
    parser.add_argument("--frameworks", nargs="+", choices=["audioflow", "pipecat"], default=["audioflow", "pipecat"])
    parser.add_argument("--runs", type=int, default=8)
    parser.add_argument("--warmup", type=int, default=4)
    parser.add_argument("--interrupt-runs", type=int, default=2)
    parser.add_argument("--max-first-output-ms", type=int, default=10_000)
    args = parser.parse_args()
    if args.runs < 1 or args.warmup < 0 or args.interrupt_runs < 0 or any(c < 1 for c in args.concurrency):
        parser.error("runs and concurrency must be positive; warmup and interrupt-runs must be non-negative")
    if args.runs < max(args.concurrency):
        parser.error("runs must be at least the highest requested concurrency")
    if args.max_first_output_ms <= 0:
        parser.error("max-first-output-ms must be positive")
    asyncio.run(main(args))

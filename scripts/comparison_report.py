"""Create a static HTML report from compare_pipecat.py output. Standard library only."""
import argparse
from collections import defaultdict
from html import escape
import json
import math
from pathlib import Path

NAMES = {"audioflow": "AudioFlow", "pipecat": "Pipecat"}

def percentile(values, fraction):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def summarize(data):
    metadata, rows = data["metadata"], data["rows"]
    arguments = metadata["arguments"]
    levels = sorted(set(arguments["concurrency"]))
    frameworks = arguments["frameworks"]
    expected = arguments["runs"]
    limit = metadata["capacity_rule"]["p95_first_output_us"]
    groups = {}
    metrics = ("first_transcript_us", "first_text_us", "first_audio_us", "first_output_us", "duration_us")
    for framework in frameworks:
        for level in levels:
            attempts = [row for row in rows if row["framework"] == framework
                        and row["concurrency"] == level and row["phase"] == "measured"]
            valid = [row for row in attempts if row["status"] == "ok"
                     and all(isinstance(row.get(key), int) and row[key] > 0 for key in metrics)]
            summary = dict(attempts=len(attempts), errors=len(attempts) - len(valid),
                           complete=len(attempts) == expected, samples=valid)
            for key in metrics:
                values = [row[key] for row in valid]
                summary[key] = dict(p50=percentile(values, .5), p95=percentile(values, .95))
            summary["passes"] = (summary["complete"] and summary["errors"] == 0
                                 and summary["first_output_us"]["p95"] is not None
                                 and summary["first_output_us"]["p95"] <= limit)
            groups[(framework, level)] = summary

    agreement = defaultdict(lambda: defaultdict(set))
    outputs = defaultdict(lambda: defaultdict(set))
    for row in rows:
        if row["phase"] == "measured" and row["status"] == "ok":
            agreement[row["input_sha256"]][row["framework"]].add(
                (row.get("utterance_sha256"), row.get("utterance_bytes")))
            outputs[row["input_sha256"]][row["framework"]].add(
                (row.get("transcript"), row.get("reply"), row.get("output_sha256"), row.get("output_bytes")))
    expected_inputs = {item["sha256"] for item in metadata["inputs"]}

    def agrees(values):
        return (set(values) == expected_inputs and all(
            set(by_framework) == set(frameworks)
            and all(len(samples) == 1 and all(value is not None for value in next(iter(samples)))
                    for samples in by_framework.values())
            and len(set.union(*by_framework.values())) == 1
            for by_framework in values.values()))

    input_agreement, output_agreement = agrees(agreement), agrees(outputs)
    capacity = {}
    for framework in frameworks:
        highest = None
        for level in levels:
            if not input_agreement or not groups[(framework, level)]["passes"]:
                break
            highest = level
        capacity[framework] = dict(highest=highest, bounded=highest != levels[-1])
    return dict(groups=groups, levels=levels, frameworks=frameworks, capacity=capacity,
                input_agreement=input_agreement, output_agreement=output_agreement, limit=limit)


def chart(summary, metric, title, threshold=False):
    groups, levels, frameworks = summary["groups"], summary["levels"], summary["frameworks"]
    samples = [row[metric] / 1e6 for group in groups.values() for row in group["samples"]]
    maximum = max(samples + ([summary["limit"] / 1e6] if threshold else []) + [1])
    maximum = math.ceil(maximum * 1.05)
    width, height = 720, max(230, len(levels) * 35 + 90)
    panel = width / len(frameworks)
    parts = [f'<svg viewBox="0 0 {width} {height}" style="height:{height}px" role="img" aria-label="{escape(title)}">',
             f'<title>{escape(title)}. Each dot is one complete turn. Vertical marks show p50 and p95.</title>']
    for column, framework in enumerate(frameworks):
        left, right = column * panel + 42, (column + 1) * panel - 20
        x = lambda value: left + value / maximum * (right - left)
        parts.append(f'<text x="{left}" y="18" class="label">{escape(NAMES[framework])}</text>')
        for index, level in enumerate(levels):
            y = 45 + index * 35
            parts.append(f'<text x="{left-12}" y="{y+4}" text-anchor="end">{level}</text>')
            group = groups[(framework, level)]
            for attempt, row in enumerate(group["samples"]):
                value = row[metric] / 1e6
                jitter = ((attempt * 7) % 9) - 4
                parts.append(f'<circle cx="{x(value):.2f}" cy="{y+jitter}" r="2" class="sample">'
                             f'<title>{escape(row["input"])}: {value:.3f} s</title></circle>')
            for quantile in ("p50", "p95"):
                value = group[metric][quantile]
                if value is not None:
                    value /= 1e6
                    style = "focus" if threshold and quantile == "p95" and value > summary["limit"] / 1e6 else "mark"
                    size = 8 if quantile == "p50" else 13
                    parts.append(f'<path d="M {x(value):.2f} {y-size} v {size*2}" class="{style}">'
                                 f'<title>{quantile}: {value:.3f} s</title></path>')
        baseline = 45 + (len(levels) - 1) * 35 + 25
        parts.append(f'<path d="M {left} {baseline} H {right}" class="axis"/>')
        for tick in range(5):
            value = maximum * tick / 4
            parts.append(f'<text x="{x(value)}" y="{baseline+18}" text-anchor="middle">{value:g}</text>')
        parts.append(f'<text x="{left}" y="{baseline+39}">Seconds; concurrent turns at left</text>')
        if threshold:
            position = x(summary["limit"] / 1e6)
            parts.append(f'<path d="M {position} 28 V {baseline}" class="limit"/>')
    parts.append('</svg>')
    return "".join(parts)


def report(data, source):
    summary = summarize(data)
    metadata = data["metadata"]
    def pair(group, metric):
        values = group[metric]
        return " / ".join(f'{values[key] / 1e6:.2f}' if values[key] is not None else "missing"
                          for key in ("p50", "p95"))
    capacities = []
    for framework, capacity in summary["capacity"].items():
        count = capacity["highest"]
        text = "No tested level passed" if count is None else f'Highest passing tested concurrency: {count}'
        if not capacity["bounded"]:
            text += ". The upper capacity limit was not found"
        capacities.append(f'<li>{escape(NAMES[framework])}: {text}.</li>')
    tables = []
    for framework in summary["frameworks"]:
        rows = []
        for level in summary["levels"]:
            group = summary["groups"][(framework, level)]
            status = "Pass" if group["passes"] and summary["input_agreement"] else "Fail"
            if not group["complete"]:
                status = "Incomplete"
            rows.append(f'<tr><th scope="row">{level}</th><td>{group["attempts"]} / {group["errors"]}</td>'
                        f'<td>{pair(group,"first_transcript_us")}</td><td>{pair(group,"first_audio_us")}</td>'
                        f'<td>{pair(group,"first_output_us")}</td><td>{status}</td></tr>')
        tables.append(f'<h3>{escape(NAMES[framework])}</h3><div class="table-scroll"><table>'
                      '<thead><tr><th>Turns</th><th>Attempts / errors</th><th>Transcript</th>'
                      '<th>PCM</th><th>Output sink</th><th>Rule</th></tr></thead><tbody>'
                      + "".join(rows) + '</tbody></table></div>')
    control = []
    for framework in summary["frameworks"]:
        attempts = [r for r in data["rows"] if r["framework"] == framework and r["phase"] == "interruption"]
        values = [r["interrupt_us"] for r in attempts if r["status"] == "cancelled"
                  and isinstance(r.get("interrupt_us"), int)]
        values_text = ", ".join(str(value) for value in sorted(values)) or "none"
        control.append(f'<p>{escape(NAMES[framework])}: {len(values)} of {len(attempts)} stopped; '
                       f'p50 {percentile(values,.5)}, p95 {percentile(values,.95)} µs. '
                       f'<small>All control times: {values_text} µs.</small></p>')
    input_note = "Detected utterance hashes agree" if summary["input_agreement"] else "Detected utterance hashes differ or are missing"
    output_note = "Transcripts, replies, and PCM hashes agree" if summary["output_agreement"] else "Some transcripts, replies, or PCM hashes differ or are missing"
    return f'''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Native media comparison</title>
<style>
:root{{--foreground:light-dark(#222,#ddd);--muted-foreground:light-dark(#666,#aaa);--border:light-dark(#bbb,#555);--destructive:light-dark(#b33630,#f0847d);--font-sans:system-ui,sans-serif;color-scheme:light dark}}
html,body{{margin:0;background:none;color:var(--foreground);font-family:var(--font-sans)}}
main{{max-width:900px;margin:auto}}h1{{font-size:23px;font-weight:600}}h2{{font-size:19px;margin-top:26px}}h3{{font-size:16px;font-weight:600}}
p,li{{font-size:14px;line-height:1.5}}small{{display:block;color:var(--muted-foreground);font-size:12px}}
svg{{width:100%;height:230px;overflow:visible}}svg text{{fill:var(--muted-foreground);font-size:12px;font-family:var(--font-sans)}}svg .label{{fill:var(--foreground);font-size:14px}}
.sample{{fill:var(--foreground);opacity:.45}}.mark{{stroke:var(--foreground);stroke-width:1.5}}.focus{{stroke:var(--destructive);stroke-width:2.5}}.axis{{stroke:var(--border);stroke-width:.6}}.limit{{stroke:var(--destructive);stroke-width:.8;stroke-dasharray:3 4}}
table{{border-collapse:collapse;width:100%;font-size:12px;font-variant-numeric:tabular-nums}}th,td{{text-align:right;padding:7px 4px;border-bottom:1px solid var(--border)}}th:first-child{{text-align:left}}th{{font-weight:500}}
.table-scroll{{overflow-x:auto}}a{{color:inherit}}@media(max-width:450px){{svg text{{font-size:13px}}}}
</style><main><h1>Native media comparison</h1>
<p>AudioFlow and Pipecat {escape(metadata["pipecat"])} use the same shared Nx models. Pipecat includes local pipe transfer cost. Input and output use software sinks with no real-time pacing.</p>
<p>{escape(metadata.get("hardware_label", "Hardware label not supplied"))}. {len(metadata["inputs"])} recordings. {metadata["arguments"]["runs"]} measured attempts and {metadata["arguments"]["warmup"]} warmup attempts per framework and level. Warmup is excluded below.</p>
<p>Rule set before the run: no measured errors; p95 output time at most {summary["limit"]/1e6:g} seconds. All lower tested levels must also pass. Percentiles use nearest rank.</p>
<ul>{"".join(capacities)}</ul><h2>Time to first output at the sink</h2>
<p>Each dot is one complete turn. Short marks show p50; long marks show p95. Red marks exceed the {summary["limit"]/1e6:g}-second rule. The dashed line shows that limit.</p>
{chart(summary,"first_output_us","Time to first output",True)}
<h2>Time to first transcript</h2>{chart(summary,"first_transcript_us","Time to first transcript")}
<p>Times start before file ingress and include Membrane resampling, Silero endpoint detection, model queues, and inference. Microphone capture and speaker delay are excluded. The charts use separate time scales.</p>
<p>Table times are p50 / p95 in seconds. PCM means the first generated chunk; output sink means its delivery.</p>{"".join(tables)}
<h2>Output interruption control</h2><p>These checks use one turn at a time. Each sink holds after its first PCM chunk. Times end when output stop is acknowledged. These are software control times; they are not acoustic stop times.</p>{"".join(control)}
<h2>Input and output checks</h2><p>{input_note}. {output_note}. These checks do not establish language or speech quality.</p>
<p>This is a short closed workload on a shared computer. The result does not establish production capacity or compare Nx against a Python inference engine. A larger sustained load and device loopback checks remain necessary for deployment decisions.</p>
<p><a href="{escape(source.name)}">Raw attempts and model metadata</a>. Source commit: <code>{escape(metadata["bridge"]["source_commit"])}</code>.</p></main></html>'''


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    data = json.loads(args.source.read_text())
    args.output.write_text(report(data, args.source))

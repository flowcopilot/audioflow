"""Check report decisions at the saved-result boundary; no model downloads."""
import copy
import unittest
from comparison_report import percentile, summarize


def fixture():
    metadata = dict(arguments=dict(concurrency=[1, 2], frameworks=["audioflow", "pipecat"], runs=4),
                    capacity_rule=dict(p95_first_output_us=10_000_000),
                    inputs=[dict(sha256="recording")])
    rows = []
    for framework in ("audioflow", "pipecat"):
        for concurrency in (1, 2):
            for value in (1, 2, 3, 4):
                rows.append(dict(framework=framework, concurrency=concurrency, phase="measured",
                                 status="ok", input_sha256="recording", utterance_sha256="utterance",
                                 utterance_bytes=100, transcript="Hello", reply="Good morning",
                                 output_sha256="pcm", output_bytes=200,
                                 first_transcript_us=value * 100_000,
                                 first_text_us=value * 200_000, first_audio_us=value * 300_000,
                                 first_output_us=value * 1_000_000, duration_us=value * 2_000_000))
    return dict(metadata=metadata, rows=rows)


class ReportTest(unittest.TestCase):
    def test_nearest_rank_preserves_tail_samples(self):
        self.assertEqual(percentile([40, 10, 30, 20], .5), 20)
        self.assertEqual(percentile(list(range(1, 101)), .95), 95)
        self.assertIsNone(percentile([], .95))

    def test_errors_missing_timings_and_incomplete_groups_cannot_pass(self):
        for change in ("error", "missing", "incomplete"):
            with self.subTest(change=change):
                data = fixture()
                if change == "error":
                    data["rows"][0]["status"] = "error"
                elif change == "missing":
                    data["rows"][0]["first_output_us"] = None
                else:
                    data["rows"].pop(0)
                result = summarize(data)
                self.assertIsNone(result["capacity"]["audioflow"]["highest"])
                self.assertEqual(result["capacity"]["pipecat"]["highest"], 2)

    def test_passing_top_level_is_reported_as_an_unbounded_test_range(self):
        result = summarize(fixture())
        self.assertEqual(result["capacity"]["audioflow"], dict(highest=2, bounded=False))
        data = fixture()
        data["rows"][7]["first_output_us"] = 11_000_000
        result = summarize(data)
        self.assertEqual(result["capacity"]["audioflow"], dict(highest=1, bounded=True))

    def test_equal_recordings_with_different_detected_utterances_block_capacity(self):
        data = fixture()
        data["rows"][-1]["utterance_sha256"] = "different"
        result = summarize(data)
        self.assertFalse(result["input_agreement"])
        self.assertTrue(result["output_agreement"])
        self.assertTrue(all(value["highest"] is None for value in result["capacity"].values()))

    def test_warmup_and_interruption_rows_do_not_change_latency_percentiles(self):
        data = fixture()
        for phase in ("warmup", "interruption"):
            extra = copy.deepcopy(data["rows"][0])
            extra.update(phase=phase, first_output_us=999_000_000, status="error")
            data["rows"].append(extra)
        result = summarize(data)
        self.assertEqual(result["groups"][("audioflow", 1)]["first_output_us"],
                         dict(p50=2_000_000, p95=4_000_000))
        self.assertEqual(result["groups"][("audioflow", 1)]["errors"], 0)


if __name__ == "__main__":
    unittest.main()

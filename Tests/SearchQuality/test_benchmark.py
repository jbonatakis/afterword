"""Regression checks for the offline scorer and text-only snapshot."""
import json
from pathlib import Path
import runpy
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
bench = runpy.run_path(str(SCRIPTS / "benchmark-search.py"))
from search_quality_snapshot import copy_recordings, silence


class SearchQualityTests(unittest.TestCase):
    def test_only_cited_evidence_from_the_accepted_source_counts(self):
        class Corpus:
            def texts(self, item):
                return {"first": "Looking into it.", "answer": "Write a temporary file and rename it."}
        source = Corpus()
        case = {"kind": "supported", "id": "atomic"}
        labels = {"right": ["rename it"]}
        other = {"kind": "coding", "session_id": "other", "text": "rename it"}
        result = {"kind": "coding", "session_id": "right", "message_id": "first", "text": "Looking into it."}
        scores = bench["score"](case, [other, result], labels, source)
        self.assertEqual(scores["rank"], 2)
        self.assertFalse(scores["preview"])
        self.assertFalse(scores["evidence"])
        result["more_passages"] = [{"message_id": "answer"}]
        self.assertTrue(bench["score"](case, [other, result], labels, source)["evidence"])

    def test_near_miss_can_be_topical_and_still_lack_support(self):
        result = bench["score"]({"id": "cost", "kind": "near_miss"},
                                [{"kind": "call", "call_id": "tour"}], {"tour": []}, None)
        metrics = bench["metrics"]([result])
        self.assertEqual(metrics["near_miss_topic@3"], [1, 1])
        self.assertEqual(metrics["near_miss_with_results"], [1, 1])
        self.assertEqual(metrics["evidence@3"], [0, 0])

    def test_loose_snapshot_only_copies_transcripts_belonging_to_shared_audio(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp).resolve()
            source = base / "source"
            source.mkdir()
            silence(source / "shared.wav")
            for name in ("shared", "missing", ".hidden"):
                run = source / "Transcripts" / name
                run.mkdir(parents=True)
                recording = "shared" if name == ".hidden" else name
                (run / "Transcript.json").write_text(json.dumps(
                    {"recording": recording, "sources": {"mixed": recording + ".wav"}}))
            dest = base / "copy"
            copy_recordings(source, dest)
            self.assertEqual([f.parent.name for f in dest.glob("Transcripts/*/Transcript.json")], ["shared"])


if __name__ == "__main__":
    unittest.main()

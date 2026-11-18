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
review = runpy.run_path(str(SCRIPTS / "review-call-excerpts.py"))
from search_quality_snapshot import copy_recordings, silence


class SearchQualityTests(unittest.TestCase):
    def test_auditor_rejects_a_hidden_neighbor_in_the_citation(self):
        class Corpus:
            def texts(self, item):
                return {0: "Ask finance.", 1: "Pay on Friday."}
        item = {"kind": "call", "version_id": "v1", "title": "Budget",
                "paragraph_ids": [0, 1], "text": "Pay on Friday."}
        with self.assertRaises(ValueError):
            review["check_citations"](item, Corpus())
        item["text"] = "finance. Pay on"
        self.assertEqual(review["check_citations"](item, Corpus()), 1)

    def test_three_visible_excerpts_have_one_budget_across_sources(self):
        class Corpus:
            def texts(self, item):
                return {0: "answer"}
        case = {"kind": "supported", "id": "budget"}
        labels = {"right": ["answer"]}
        wrong = {"kind": "call", "call_id": "wrong", "text": "answer", "paragraph_ids": [0],
                 "more_passages": [{"text": "irrelevant"}, {"text": "irrelevant"}]}
        right = {"kind": "call", "call_id": "right", "text": "question", "paragraph_ids": [0],
                 "more_passages": [{"text": "answer", "paragraph_ids": [0]}]}
        row = bench["score"](case, [wrong, right], labels, Corpus())
        self.assertTrue(row["evidence"])
        self.assertFalse(row["visible_three"])
        wrong.pop("more_passages")
        row = bench["score"](case, [wrong, right], labels, Corpus())
        self.assertTrue(row["visible_three"])
        self.assertFalse(row["first_source_three"])
        self.assertFalse(row["preview"])

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

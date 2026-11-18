#!/usr/bin/env python3
"""Audit paired benchmark reports and shuffle their visible evidence for review."""
import argparse
import os
from pathlib import Path
import random
import runpy
from collections import Counter

from search_quality_snapshot import corpus_digest, digest, read_json, write_json

bench = runpy.run_path(str(Path(__file__).with_name("benchmark-search.py")))
norm = bench["norm"]


def displayed(items):
    excerpts = []
    for item in items:
        for p in [item, *item.get("more_passages", [])]:
            excerpts.append({"source": item["title"], "text": p["text"]})
    return excerpts[:3]


def check_citations(item, sources):
    if item["kind"] != "call":
        return 0
    passages = [item, *item.get("more_passages", [])]
    if not item.get("paragraph_ids"):
        if len(passages) > 1:
            raise ValueError("Missing primary call citation.")
        return 0
    if len(passages) > 3 or not item.get("version_id"):
        raise ValueError("Missing transcript version or excessive passages.")
    paragraphs = sources.texts(item)
    seen = set()
    for p in passages:
        ids = p["paragraph_ids"]
        if not ids or seen.intersection(ids) or len(ids) != len(set(ids)) or len(p["text"]) > 260:
            raise ValueError("Invalid excerpt size or overlapping citations.")
        seen.update(ids)
        text = norm(p["text"]).strip("… ").strip()
        parts = [norm(paragraphs[i]) for i in ids]
        combined = " ".join(parts)
        offset = combined.find(text)
        if not text or offset < 0 or offset >= len(parts[0]) or offset + len(text) <= len(combined) - len(parts[-1]):
            raise ValueError(f"Displayed words do not match cited paragraphs {ids} of {item['title']}.")
    return len(passages)


def prepare(args):
    before, after = read_json(args.before), read_json(args.after)
    for key in ("format", "snapshot", "split", "cases", "model", "mode"):
        if before[key] != after[key]:
            raise ValueError(f"Mismatched {key}.")
    if after["cases"] != digest(args.cases) or after["snapshot"] != corpus_digest(args.snapshot / "corpus"):
        raise ValueError("Snapshot or cases differ from the reports.")
    cases = {c["id"]: c for c in read_json(args.cases) if c["split"] == after["split"]}
    variants = {"before": before["results"], "after": after["results"]}
    if any([r["id"] for r in rows] != list(cases) for rows in variants.values()):
        raise ValueError("Incomplete or unpaired results.")
    args.directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    key, packet = {}, []
    citations = changed_order = control_changes = control_count = 0
    rng = random.SystemRandom()
    def source_ids(row):
        return [i.get("call_id") or i["session_id"] for i in row["items"]]
    with bench["mcp"](args.helper, args.snapshot.resolve() / "state") as call:
        sources = bench["Sources"](call, args.snapshot.resolve())
        for baseline, candidate in zip(*variants.values()):
            case = cases[baseline["id"]]
            changed_order += source_ids(baseline) != source_ids(candidate)
            if case["source"] == "coding":
                control_count += 1
                control_changes += baseline["items"] != candidate["items"]
            citations += sum(check_citations(i, sources) for i in candidate["items"])
            if case["source"] != "calls" or case["kind"] != "supported":
                continue
            rows = [("before", baseline), ("after", candidate)]
            rng.shuffle(rows)
            key[case["id"]] = [variant for variant, _ in rows]
            packet.append({"id": case["id"], "query": case["query"], "options": [
                {"grade": None, "excerpts": displayed(r["items"])} for _, r in rows]})
    rng.shuffle(packet)
    metrics = {}
    for variant, rows in variants.items():
        metrics[variant] = bench["metrics"]([r for r in rows if cases[r["id"]]["source"] == "calls"])
    audit = {"call_only_metrics": metrics, "queries": len(cases), "source_order_changes": changed_order,
             "coding_only_changes": control_changes, "coding_only_queries": control_count,
             "verified_candidate_excerpts": citations}
    write_json(args.directory / "audit.json", audit)
    write_json(args.directory / "review.json", packet)
    write_json(args.directory / "key.json", key)


def reveal(directory):
    grades = {"none": 0, "partial": 1, "answers": 2}
    key = read_json(directory / "key.json")
    packet = read_json(directory / "review.json")
    if len(packet) != len(key) or {r["id"] for r in packet} != set(key):
        raise ValueError("Review is incomplete.")
    counts = Counter()
    for row in packet:
        if len(row["options"]) != 2:
            raise ValueError("Expected two ratings per question.")
        ratings = [grades[option["grade"]] for option in row["options"]]
        pair = dict(zip(key[row["id"]], ratings))
        diff = pair["after"] - pair["before"]
        counts["improved" if diff > 0 else "worse" if diff < 0 else "tied"] += 1
        for variant, grade in pair.items():
            counts[variant + "_answers"] += grade == grades["answers"]
    print(dict(counts))


if __name__ == "__main__":
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    cmds = parser.add_subparsers(dest="command", required=True)
    p = cmds.add_parser("prepare")
    for arg in ("before", "after", "cases", "snapshot", "helper", "directory"):
        p.add_argument(arg, type=Path)
    cmds.add_parser("reveal").add_argument("directory", type=Path)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args)
    else:
        reveal(args.directory)

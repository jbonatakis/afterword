#!/usr/bin/env python3
"""Score public MCP results against a frozen text library and source-specific evidence labels."""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import select
import shutil
import sqlite3
import subprocess
import time

from search_quality_snapshot import APP_DATA, FIXTURES, corpus_digest, digest, prepare, read_json, sqlite_backup, write_json

MODELS = {"Qwen3-Embedding-0.6B-Q8_0.gguf": "qwen3-0.6b", "bge-small-en-v1.5-f16.gguf": "bge-small"}
TOP_K = 3


@contextmanager
def mcp(executable, state):
    proc = subprocess.Popen([str(executable.resolve()), "--state-directory", str(state)],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    seq = 0

    def rpc(method, params, notify=False):
        nonlocal seq
        request = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notify:
            seq += 1
            request["id"] = seq
        proc.stdin.write(json.dumps(request) + "\n")
        proc.stdin.flush()
        if notify:
            return
        if not select.select([proc.stdout], [], [], 150)[0]:
            raise TimeoutError(f"MCP timed out in {method}")
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError(f"MCP helper exited during {method}")
        reply = json.loads(line)
        if reply.get("id") != seq or "error" in reply:
            raise RuntimeError(f"MCP request failed: {reply.get('error', 'unexpected request ID')}")
        return reply["result"]

    def call(name, args):
        result = rpc("tools/call", {"name": name, "arguments": args})
        if result.get("isError"):
            raise ValueError(f"{name}: {result['content'][0]['text']}")
        return result["structuredContent"]

    try:
        rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                           "clientInfo": {"name": "search-quality-benchmark", "version": "1"}})
        rpc("notifications/initialized", {}, notify=True)
        yield call
    finally:
        proc.stdin.close()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        proc.stdout.close()


def pages(call, name, args, revision_key):
    args = dict(args, limit=100)
    while True:
        result = call(name, args)
        yield from result["items"]
        if "next_offset" not in result:
            break
        args.update(offset=result["next_offset"], expected_revision=result[revision_key])


def configure(snapshot, mode, weights):
    corpus, state = snapshot / "corpus", snapshot / "state"
    state.mkdir(exist_ok=True)
    roots = [str(p) for p in sorted(corpus.iterdir()) if p.is_dir()]
    history = corpus / "History.sqlite"
    if history.exists():
        directory = state / "CodingSessions"
        directory.mkdir(exist_ok=True)
        sqlite_backup(history, directory / history.name)
    write_json(state / "Access.json", dict(version=1, enabled=True, folders=roots, allowCodingSessions=history.exists()))
    embedding = state / "Embeddings"
    embedding.mkdir(exist_ok=True)
    model = None
    if mode == "hybrid":
        if weights.name not in MODELS or not weights.is_file():
            raise ValueError("Supply a locally downloaded supported GGUF with --weights.")
        model = MODELS[weights.name]
        models = embedding / "Models"
        models.mkdir(exist_ok=True)
        installed = models / weights.name
        if not installed.exists():
            shutil.copyfile(weights, installed)
    write_json(embedding / "Settings.json", {"enabled": bool(model), "modelID": model or "qwen3-0.6b"})
    return state, model


def norm(text):
    return " ".join(text.casefold().split())


class Sources:
    def __init__(self, call, snapshot):
        self.call = call
        self.by_title = {}
        for item in pages(call, "search_activity", {}, "library_revision"):
            key = (item["kind"], item["title"])
            self.by_title.setdefault(key, []).append(item)
        self.calls = {}
        self.history = snapshot / "corpus/History.sqlite"
        self.messages = {}

    def texts(self, item):
        if item["kind"] == "call":
            key = item["call_id"], item.get("version_id")
            if key not in self.calls:
                args = {"call_id": key[0]}
                if key[1]:
                    args["version_id"] = key[1]
                # get_transcript paginates using call.revision rather than a top-level revision.
                text = {}
                while True:
                    res = self.call("get_transcript", dict(args, limit=100))
                    text.update((p["paragraph_id"], p["text"]) for p in res["items"])
                    if "next_offset" not in res:
                        break
                    args.update(offset=res["next_offset"], expected_revision=res["call"]["revision"])
                self.calls[key] = text
            return self.calls[key]
        sid = item["session_id"]
        if sid not in self.messages:
            db = sqlite3.connect(self.history.as_uri() + "?mode=ro&immutable=1", uri=True)
            try:
                row = db.execute("SELECT history FROM sessions WHERE id=?", (sid,)).fetchone()
                self.messages[sid] = {m["id"]: m["text"] for m in json.loads(row[0])["messages"]}
            finally:
                db.close()
        return self.messages[sid]

    def resolve(self, case, label):
        kind = label.get("kind", {"calls": "call", "coding": "coding"}.get(case["source"]))
        items = self.by_title.get((kind, label["title"]), [])
        if "id" in label:
            items = [i for i in items if label["id"] in (i.get("call_id"), i.get("session_id"))]
        if len(items) != 1:
            raise ValueError(f"{case['id']}: missing or ambiguous source {label['title']}")
        return items[0]

    def gold(self, case):
        labels = {}
        for g in case.get("gold", []):
            item = self.resolve(case, g)
            anchors = [norm(a) for a in g["anchors"]]
            if case["kind"] == "near_miss" and anchors:
                raise ValueError(f"{case['id']}: near-miss labels describe a topic without supporting evidence")
            if case["kind"] == "supported":
                texts = [norm(t) for t in self.texts(item).values()]
                if not anchors or any(not a or not any(a in t for t in texts) for a in anchors):
                    raise ValueError(f"{case['id']}: evidence label missing from frozen source")
            labels[item.get("call_id") or item["session_id"]] = anchors
        return labels


def score(case, items, labels, sources):
    row = {"id": case["id"], "kind": case["kind"], "returned": bool(items)}
    if case.get("distractors"):
        traps = [sources.resolve(case, d) for d in case["distractors"]]
        trap_ids = {i.get("call_id") or i["session_id"] for i in traps}
        if trap_ids.intersection(labels):
            raise ValueError(f"{case['id']}: a source cannot be both relevant and a distractor")
        row["distractor"] = any((i.get("call_id") or i.get("session_id")) in trap_ids for i in items)
    if not labels:
        return row
    row["rank"] = None
    if case["kind"] == "supported":
        row.update(preview=False, evidence=False)
    for rank, item in enumerate(items, 1):
        anchors = labels.get(item.get("call_id") or item.get("session_id"))
        if anchors is None:
            continue
        if row["rank"] is None:
            row["rank"] = rank
        if case["kind"] != "supported":
            continue
        if rank == 1:
            row["preview"] = any(a in norm(item["text"]) for a in anchors)
        if item["kind"] == "coding":
            ids = [p["message_id"] for p in [item, *item.get("more_passages", [])] if "message_id" in p]
        else:
            ids = item.get("paragraph_ids", [])
        texts = sources.texts(item)
        row["evidence"] |= any(a in norm(texts[i]) for i in ids for a in anchors)
    return row


def metrics(rows):
    supported = [r for r in rows if r["kind"] == "supported"]
    near = [r for r in rows if r["kind"] == "near_miss"]
    off = [r for r in rows if r["kind"] == "off_topic"]
    def count(items, test):
        return [sum(bool(test(r)) for r in items), len(items)]
    return {"source@1": count(supported, lambda r: r["rank"] == 1),
            "source@3": count(supported, lambda r: r["rank"]),
            "preview@1": count(supported, lambda r: r["preview"]),
            "evidence@3": count(supported, lambda r: r["evidence"]),
            "near_miss_topic@3": count(near, lambda r: r["rank"]),
            "near_miss_with_results": count(near, lambda r: r["returned"]),
            "known_distractor@3": count([r for r in rows if "distractor" in r], lambda r: r["distractor"]),
            "off_topic_empty": count(off, lambda r: not r["returned"])}


def run(args):
    snapshot = args.snapshot.resolve()
    expected = read_json(snapshot / "snapshot.json")
    fingerprint = corpus_digest(snapshot / "corpus")
    if expected != {"format": 1, "corpus_sha256": fingerprint}:
        raise ValueError("Snapshot changed. Freeze a new corpus for a new benchmark.")
    cases = read_json(args.cases)
    if len({c["id"] for c in cases}) != len(cases):
        raise ValueError("Duplicate case IDs.")
    for c in cases:
        if (c["kind"] not in ("supported", "near_miss", "off_topic") or c["split"] not in ("dev", "holdout")
                or c["source"] not in ("coding", "calls", "all") or not c["query"].strip()
                or bool(c.get("gold")) != (c["kind"] != "off_topic")):
            raise ValueError(f"Invalid case: {c['id']}")
    source_splits = {}
    for c in cases:
        for g in c.get("gold", []):
            source = (g.get("kind", {"calls": "call", "coding": "coding"}.get(c["source"])), g.get("id", g["title"]))
            if source_splits.setdefault(source, c["split"]) != c["split"]:
                raise ValueError(f"{source}: related questions must stay in the same split.")
    cases = [c for c in cases if c["split"] == args.split]
    if not cases:
        raise ValueError("Empty split.")
    with (snapshot / "run.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state, model = configure(snapshot, args.mode, args.weights)
        with mcp(args.executable, state) as call:
            deadline = time.monotonic() + args.index_timeout
            while model:
                status = call("list_calls", {"limit": 1})["search_status"]
                if status["coverage_complete"]:
                    break
                if status["state"] != "indexing" or time.monotonic() >= deadline:
                    raise RuntimeError(f"Cannot score an incomplete index: {status}")
                time.sleep(0.5)
            sources = Sources(call, snapshot)
            rows = []
            for c in cases:
                labels = sources.gold(c)
                result = call("search_activity", dict(query=c["query"], source=c["source"], mode=args.mode, limit=TOP_K))
                status = result["search_status"]
                if status["mode"] != args.mode or (model and not status["coverage_complete"]):
                    raise RuntimeError(f"{c['id']}: unexpected search mode or coverage: {status}")
                rows.append(score(c, result["items"], labels, sources))
    report = {"format": 1, "snapshot": fingerprint, "cases": digest(args.cases), "split": args.split,
              "mode": args.mode, "model": model, "executable": digest(args.executable),
              "metrics": metrics(rows), "results": rows}
    print(json.dumps(report["metrics"]))
    if args.report:
        write_json(args.report, report)


def compare(before, after):
    a, b = read_json(before), read_json(after)
    for k in ("format", "snapshot", "cases", "split"):
        if a[k] != b[k]:
            raise ValueError(f"Cannot compare reports with different {k}.")
    if [r["id"] for r in a["results"]] != [r["id"] for r in b["results"]]:
        raise ValueError("Case IDs differ.")
    for name, report in [("before", a), ("after", b)]:
        print(f"{name} {report['mode']} {report['model'] or ''} · MCP {report['executable'][:12]}")
    for k, v in a["metrics"].items():
        print(f"{k}: {v[0]}/{v[1]} -> {b['metrics'][k][0]}/{b['metrics'][k][1]}")
    for old, new in zip(a["results"], b["results"]):
        changes = [f"{k} {v} -> {new[k]}" for k, v in old.items() if new[k] != v]
        if changes:
            print(old["id"], ", ".join(changes))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    freeze = sub.add_parser("freeze")
    freeze.add_argument("snapshot", type=Path)
    freeze.add_argument("--from-library", action="store_true", help="Copy locally shared text and coding history.")
    bench = sub.add_parser("run")
    bench.add_argument("snapshot", type=Path)
    bench.add_argument("--executable", type=Path, required=True, help="Bundled AfterwordMCP executable")
    bench.add_argument("--cases", type=Path, default=FIXTURES / "cases.json")
    bench.add_argument("--split", choices=["dev", "holdout"], required=True)
    bench.add_argument("--mode", choices=["keyword", "hybrid"], default="hybrid")
    bench.add_argument("--weights", type=Path, default=APP_DATA / "Embeddings/Models/Qwen3-Embedding-0.6B-Q8_0.gguf")
    bench.add_argument("--index-timeout", type=int, default=600)
    bench.add_argument("--report", type=Path)
    diff = sub.add_parser("compare")
    diff.add_argument("before", type=Path)
    diff.add_argument("after", type=Path)
    args = parser.parse_args()
    if args.action == "freeze":
        prepare(args.snapshot, args.from_library)
    elif args.action == "compare":
        compare(args.before, args.after)
    else:
        run(args)


if __name__ == "__main__":
    main()

"""Freeze text inputs for the local search-quality benchmark."""
import hashlib
import json
import shutil
import sqlite3
import subprocess
import tempfile
import wave
from pathlib import Path

APP_DATA = Path.home() / "Library/Application Support/Afterword"
FIXTURES = Path(__file__).resolve().parents[1] / "Tests/SearchQuality"
TRACKS = {"Microphone.m4a", "Mixed.m4a", "System.m4a"}
AUDIO = {".m4a", ".wav", ".caf", ".mp3", ".aiff"}


def read_json(path):
    return json.loads(path.read_text())


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def corpus_digest(root):
    files = [(p.relative_to(root).as_posix(), digest(p)) for p in sorted(root.rglob("*")) if p.is_file()]
    return hashlib.sha256(json.dumps(files).encode()).hexdigest()


def silence(path):
    with wave.open(str(path), "wb") as output:
        output.setparams((1, 2, 16000, 1600, "NONE", ""))
        output.writeframes(b"\0" * 3200)


def sqlite_backup(source, destination):
    src = sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)
    dst = sqlite3.connect(destination)
    try:
        src.backup(dst)
        dst.execute("PRAGMA journal_mode=DELETE")
    finally:
        dst.close()
        src.close()


def sample(root):
    for index, call in enumerate(read_json(FIXTURES / "calls.json")):
        path = root / "calls" / f"sample-{index:02d}"
        run = path / "Transcripts" / "original"
        run.mkdir(parents=True)
        silence(path / "Mixed.m4a")
        write_json(path / "CallDetails.json", dict(version=4, title=call["title"], participants=[], tags=[], description=""))
        segments = [dict(source="mixed", start=i*10, end=i*10+3, text=text, timing="segment")
                    for i, text in enumerate(call["turns"])]
        write_json(run / "Transcript.json", dict(version=2, recording=path.name, createdAt="2026-01-10T10:00:00Z",
                   modelID="fixture", modelName="Fixture", modelSHA256="fixture", engine="fixture", language="en",
                   sources={"mixed": "Mixed.m4a"}, segments=segments))
    with tempfile.TemporaryDirectory(dir=root.parent) as tmp:
        work = Path(tmp)
        project = work / "projects/example"
        project.mkdir(parents=True)
        for i, session in enumerate(read_json(FIXTURES / "coding.json")):
            rows = [
                dict(type="user", uuid="request", cwd="/fixture", timestamp="2026-01-10T10:00:00Z",
                     message={"content": session["request"]}),
                dict(type="assistant", uuid="reply", parentUuid="request", timestamp="2026-01-10T10:01:00Z",
                     message={"content": session["reply"]}),
                dict(type="custom-title", customTitle=session["title"]),
            ]
            path = project / f"00000000-0000-4000-a000-{i:012d}.jsonl"
            path.write_text("".join(json.dumps(r) + "\n" for r in rows))
        subprocess.run(["bash", str(FIXTURES / "import.sh"), str(project.parent), str(work)], check=True)
        sqlite_backup(work / "History.sqlite", root / "History.sqlite")
        sqlite_backup(work / "GitHub/History.sqlite", root / "GitHub.sqlite")


def regular(path):
    return path.is_file() and path == path.resolve()


def copy_text(source, target):
    if regular(source):
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def copy_transcripts(source, target, loose_names=None):
    for file in source.glob("Transcripts/*/Transcript.json"):
        if file.parent.name.startswith(".") or not regular(file):
            continue
        if loose_names is not None:
            doc = read_json(file)
            audio = doc.get("sources", {}).get("mixed", "")
            if audio not in loose_names or doc.get("recording") != Path(audio).stem:
                continue
        copy_text(file, target / file.relative_to(source))


def copy_recordings(source, destination):
    destination.mkdir(parents=True)
    if not source.is_absolute() or source != source.resolve() or not source.is_dir():
        raise ValueError(f"Unavailable or linked recording folder: {source}")
    # Mirror the scanner's two layouts. A valid, silent WAV stands in for each audio track.
    if any(regular(source / name) for name in TRACKS):
        entries = [source]
    else:
        entries = sorted(p for p in source.iterdir() if not p.name.startswith(".") and not p.is_symlink())
    loose = set()
    for entry in entries:
        if entry.is_dir() and any(regular(entry / name) for name in TRACKS):
            call = destination / entry.name
            call.mkdir()
            silence(call / "Mixed.m4a")
            for name in ("CallDetails.json", "Summary.json"):
                copy_text(entry / name, call / name)
            copy_transcripts(entry, call)
        elif regular(entry) and entry.suffix.lower() in AUDIO and entry.name not in TRACKS:
            loose.add(entry.name)
            silence(destination / entry.name)
            for suffix in (".call.json", ".summary.json"):
                copy_text(Path(str(entry) + suffix), destination / (entry.name + suffix))
    if loose:
        copy_transcripts(source, destination, loose)


def prepare(destination, from_library):
    destination = destination.resolve()
    if destination.exists():
        raise ValueError("Choose a new snapshot directory. Existing snapshots are kept for comparisons.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as stage:
        work = Path(stage) / "snapshot"
        corpus = work / "corpus"
        corpus.mkdir(parents=True)
        if from_library:
            access = APP_DATA / "MCP/Access.json"
            config = read_json(access)
            if not config["enabled"]:
                raise ValueError("Agent Access is disabled.")
            for i, folder in enumerate(config["folders"]):
                copy_recordings(Path(folder), corpus / f"root-{i}")
            history = APP_DATA / "CodingSessions/History.sqlite"
            if config.get("allowCodingSessions") and regular(history):
                sqlite_backup(history, corpus / "History.sqlite")
            # Only the benchmark's writable cache is seeded, using already computed vectors.
            vectors = APP_DATA / "Embeddings/Vectors-v1.sqlite"
            if regular(vectors):
                embeddings = work / "state/Embeddings"
                embeddings.mkdir(parents=True)
                sqlite_backup(vectors, embeddings / vectors.name)
            if read_json(access) != config:
                raise ValueError("Agent Access changed while freezing the library. Retry.")
        else:
            sample(corpus)
        write_json(work / "snapshot.json", {"format": 1, "corpus_sha256": corpus_digest(corpus)})
        work.rename(destination)

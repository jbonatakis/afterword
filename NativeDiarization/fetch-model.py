"""Fetch and validate the pinned Core ML model when packaging Afterword."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

revision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
root = Path(sys.argv[1])
manifest = json.loads(Path(__file__).with_name("model-files.json").read_text())
for name, digest in manifest.items():
    path = root / name
    if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
        continue
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as pending:
        tmp = Path(pending.name)
    try:
        url = f"https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/{revision}/{name}"
        subprocess.run(["curl", "-q", "-fsSL", "--retry", "3", "-o", str(tmp), url], check=True)
        if hashlib.sha256(tmp.read_bytes()).hexdigest() != digest:
            raise ValueError(f"Invalid checksum for {name}")
        tmp.replace(path)
    finally:
        tmp.unlink(missing_ok=True)
(root / ".fluidaudio-revision").write_text(revision + "\n")

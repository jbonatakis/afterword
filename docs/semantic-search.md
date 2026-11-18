# Local semantic search

Enable **Settings → Search → Semantic search**, choose a model, and download it. The feature starts off; Qwen3 Embedding 0.6B is the preselected model. Download, cancel, and remove controls are independent of transcription models. Downloads use HTTPS, immutable revisions, exact sizes, and SHA-256 verification before publication and first use. All text inference stays on the Mac.

| Model | Download | Dimensions | Retrieval input |
|---|---:|---:|---|
| BGE Small English v1.5, F16 | 67 MB | 384 | CLS pooling; BGE instruction on queries only |
| Qwen3 Embedding 0.6B, Q8_0 | 639 MB | 1,024 | Last-token pooling with EOS; retrieval instruction on queries only |

[BGE's model card](https://huggingface.co/BAAI/bge-small-en-v1.5) describes its English retrieval instruction and CLS pooling. Its pinned GGUF conversion comes from CompendiumLabs. [Qwen's official GGUF release](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF) supplies the Qwen weights. The catalog pins each revision, file size, and SHA-256. Model license links appear in Settings.

## Runtime and lifecycle

`EmbeddingWorker` is a bundled Objective-C++ helper linked statically with [llama.cpp b6900](https://github.com/ggml-org/llama.cpp/tree/c22473b580807929fd9e3a3344a48e8cfbe6c88f), using Metal on Apple Silicon. GGUF files contain weights and tokenizer data. No Python environment, separate runtime installation, network listener, or inference service is required at runtime. Transcription and embedding GGML libraries live in separate processes.

The app and MCP server share implementation, settings, verified model downloads, and a derived vector cache. A helper loads one model for a batch of up to 24 passages, returns L2-normalized vectors through private JSON files, and exits to release its memory. Query embeddings are cached in memory (up to 32 per engine). A process-wide file lock bounds simultaneous inference to one helper across app/MCP instances. Cross-process leases let queries interrupt background indexing and let recording/transcription interrupt all inference. Cancellation is polled every 20 ms; unresponsive helpers are killed after a one-second grace period. A batch has a 120-second timeout. A competing query can cause explicit keyword fallback rather than an unbounded wait.

Background indexing starts after saved library refreshes or MCP requests; latest versions are processed first. The native app retries paused work on a two-second timer. MCP has no source polling or daemon: a later request resumes work after a pause. Disabling semantic search, removing the selected model, or changing models cancels obsolete work. No model is downloaded automatically.

## Chunks, updates, and search

Reading paragraphs provide speaker turns and stable references within a transcript version. Short exchanges are combined for context, while their individual turns are also indexed for speaker-specific retrieval. Long turns are divided at sentence boundaries, with at most one short sentence of overlap. Text is bounded to about 900 characters per chunk; the runtime enforces the actual 512-token limit. Unusually token-dense text is recursively divided and its normalized sub-vectors combined by text length, so the tail is never silently truncated. This fallback is a pragmatic bounded-memory policy, not identical to embedding an unlimited context.

Only speech text and neutral separators enter document embeddings. Current speaker names, titles, participants, timestamps, paragraph IDs, and revisions are resolved from saved source snapshots at retrieval time. Renames, attendance changes, or speaker reassignment reuse unchanged input hashes. If assignment changes paragraph grouping, affected chunk inputs change and are indexed again. Edited text invalidates only changed inputs; old versions remain separately retrievable when history is requested.

Keyword search remains the baseline. With semantic search available, normalized-vector similarity adds candidates, and reciprocal-rank fusion combines lexical and semantic passage ranks. Explicit quoted phrases remain literal constraints. Date, tag, participant, allowed-folder, latest/history, and exact speaker filters are enforced. The speaker filter restricts matching speech; neighboring speakers can still appear in clearly labeled context. A speaker-filtered semantic candidate must contain only that speaker's paragraphs. Semantic candidates are bounded to the top 60 eligible passages, with conservative model-specific similarity floors; scores are ranking heuristics, not confidence probabilities.

The library and MCP return current source passages rather than generated answers. MCP includes actual search mode and indexing coverage, and search pagination revisions incorporate model/coverage/fallback state. Content and change-checkpoint revisions remain independent of derived vectors. Off, missing, paused, busy, or failed inference falls back to keyword search. Partial indexing is reported explicitly.

Coding search ranks sessions. A full-word keyword match in the title takes precedence over incidental mentions in other sessions. For semantic search, the session title and its strongest matching message each contribute their similarity above the selected model’s retrieval threshold. Repeated passages from a long conversation contribute once. Keyword and semantic session ranks are combined, and each result can cite up to three distinct messages. Title embeddings use the existing text-hash cache.

## Storage

`~/Library/Application Support/Afterword/Embeddings` contains `Settings.json`, `Models/`, `Vectors-v1.sqlite`, and process-coordination lock files. The vector database stores model-space keys, text hashes, and vectors, not transcript text. Private temporary inference files are removed after each batch; an abrupt parent-process crash can leave a private `.worker-*` directory, which may be removed while helpers are stopped. This is not encryption or secure deletion.

The model-space key includes weights, pooling, query preprocessing, and chunk-format version. Vectors are read only for chunks currently visible in the source index; cached vectors do not grant access to deleted calls or revoked folders. Model removal keeps reusable vectors but prevents semantic use until the model is installed again. Clearing the vector database while helpers are stopped rebuilds it from saved JSON. Custom MCP `--state-directory` isolates embedding settings/models/cache under `Embeddings` in that directory.

## Evaluation and verification

For repeatable end-to-end comparisons, use the [search quality benchmark](search-quality.md). It exercises MCP source ranking, excerpt selection, cited evidence, and negative controls on frozen calls and coding sessions.

A local smoke test used six paraphrased questions with source-text anchors. On the final nineteen chunks (individual turns and short exchanges), Qwen ranked the anchored passage first in 5/6 questions; BGE did in 4/6, and both found it in the top three in 6/6. This is a tiny, manually selected sample, not a general quality benchmark. It motivated Qwen as the preselected model while retaining the faster BGE option.

On the M4 Air, with model files and Metal kernels warm, nineteen chunks plus six queries across two helper batches took about 1.70 seconds for Qwen and 0.51 seconds for BGE. Maximum resident set size was approximately 740 MiB and 112 MiB respectively. These include process setup and model loading; OS file caching and GPU allocations make RSS different from permanent physical-memory cost. First-run kernel compilation can add seconds. Helpers exit after each batch.

Core tests use injected vectors and cover cache reuse/invalidation, model-space changes, source filters, exact phrases, speaker attribution, partial coverage/revisions, cancellation, priority, malformed vectors, and fallback. The opt-in real-model integration check exercises the signed MCP executable and worker against synthetic speech:

```sh
uv run --with mcp==1.28.1 Scripts/check-embedding-mcp.py \
  'build/Afterword.app/Contents/Helpers/AfterwordMCP' build/embedding-models
```

`Tests/EmbeddingBenchmark.swift` exports current-version chunks to an explicitly chosen private local artifact. `Scripts/benchmark-embeddings.py` compares the two downloaded models locally against the source anchors. Neither uploads recordings or changes production settings. Run `python3 Scripts/benchmark-embeddings.py CORPUS.json CASES.json`. Supply a private JSON array of question and source-anchor string pairs for that corpus. With only a corpus path, the runner reads the adjacent `CORPUS.cases.json` file.

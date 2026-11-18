# Search quality benchmark

The runner calls `search_activity` on a local AfterwordMCP executable over stdio. It tests the same keyword and hybrid retrieval paths used by clients. The versioned sample contains eight synthetic calls, four synthetic coding sessions, and 24 questions. Lookback imports the sample sessions through the production archive indexer. Each split has ten answerable questions, one related question with an unsupported premise, and one off-topic question.

## Run it

From the repository root, freeze the sample once. Keep the directory for subsequent comparisons. The Mac needs the Swift build tools for the fixture importer. Hybrid runs also need the app's bundled EmbeddingWorker and a downloaded, supported GGUF. Keyword runs work without a model.

```sh
python3 Scripts/benchmark-search.py freeze build/search-quality/sample

helper=build/coding-sessions/Afterword.app/Contents/Helpers/AfterwordMCP
python3 Scripts/benchmark-search.py run build/search-quality/sample \
  --executable "$helper" --split dev --report build/search-quality/before.json
```

After building the candidate, run the same command with `--report build/search-quality/after.json`, then compare.

```sh
python3 Scripts/benchmark-search.py compare \
  build/search-quality/before.json build/search-quality/after.json
```

Use `--mode keyword` for a literal-search control. Hybrid defaults to the locally installed Qwen model. Use `--weights /path/to/bge-small-en-v1.5-f16.gguf` to compare BGE. The runner waits for complete embedding coverage and fails if a hybrid query falls back to keywords. Run `--split holdout` with both executables after fixing the candidate. If the baseline executable will be replaced, keep it and its sibling EmbeddingWorker together.

## Scorecard

| Measure | What counts |
|---|---|
| Source @1 and @3 | At least one accepted call or session appears within that rank on an answerable question. |
| Preview @1 | The first result is an accepted source and its displayed excerpt contains a labeled evidence phrase. |
| Evidence @3 | One of the first three results cites a paragraph or coding message from an accepted source containing a labeled phrase. Additional citations on a coding hit count. The scorer checks the original frozen text. |
| Near-miss topic @3 | A question with an unsupported premise retrieves an expected source that actually discusses the topic. |
| Near-miss with results | Any result is returned for that question. A useful passage can correct its premise. |
| Known distractor @3 | An explicitly labeled misleading source appears in the first three. Lower is better. Only cases with distractor labels contribute. |
| Off-topic empty | A question labeled unrelated to this snapshot produces zero hits. |

Every score is a numerator and denominator. Evidence anchors are human-selected alternatives, matched case-insensitively with whitespace normalized. Use a short phrase specific enough to establish the relevant fact. This measures delivery of labeled evidence. Judging whether an agent drew the correct conclusion from it requires a separate answer evaluation. The current labels cover transcript paragraphs and coding messages.

## Use a private library

```sh
python3 Scripts/benchmark-search.py freeze .search-benchmarks/my-snapshot --from-library
python3 Scripts/benchmark-search.py run .search-benchmarks/my-snapshot \
  --cases .search-benchmarks/my-cases.json --executable "$helper" --split dev
```

Freeze while saved recordings are idle. The snapshot copies transcript versions and call metadata from the recording folders shared in Agent Access. It substitutes silent audio and takes a consistent SQLite backup of the coding archive when coding access is enabled. The separate people directory and voice samples are outside the snapshot. The private runtime cache can reuse vectors from this Mac. Snapshot data persists independently of later edits, deletions, or changes to sharing, so keep private snapshots and their labels in the Git-ignored `.search-benchmarks/` directory. Removing a snapshot removes that benchmark's copy.

The snapshot fingerprint covers the frozen files. Search settings, writable indexes, and the runner lock are separate. Reports identify the corpus, exact case file, executable, mode, model, split, and individual case outcomes. Comparison rejects a change to the corpus, labels, or split. Use the *same* snapshot directory for a paired experiment. Fresh imports have their own archive identities. The frozen coding archive includes its text index, so this workflow measures retrieval over already-imported sessions.

## Add cases without training to the test

Add questions to the case file before comparing builds. A case can accept multiple genuinely relevant sources. An explicit source ID can disambiguate duplicate titles. Use `source: "all"` and give each label its `kind` when testing across calls and code. For example:

```json
{
  "id": "receipt-retry",
  "split": "dev",
  "kind": "supported",
  "source": "all",
  "query": "How do we avoid emailing the same purchase confirmation twice?",
  "gold": [
    {"kind": "coding", "title": "Mail delivery retries", "anchors": ["idempotency key"]}
  ]
}
```

For `near_miss`, give the related source an empty anchor list. For `off_topic`, omit `gold`. Optional `distractors` take source labels. The runner rejects missing sources, ambiguous titles, missing evidence anchors, duplicate case IDs, and the same gold source appearing on both sides of the split.

Keep paraphrases, recurring meetings about the same decision, and sessions implementing that decision on the same side of the split. The source check catches repeated sources; grouping related topics across distinct sources requires human judgment. Include exact queries, paraphrases, mixed-source searches, plausible near misses, and clearly unrelated questions. Diagnose misses on development cases. If a label is wrong or misses a valid source, document the correction and rerun **both** builds. Once a held-out result informs a change, keep it as a regression case and reserve fresh topics or a later week's calls for the next independent evaluation.

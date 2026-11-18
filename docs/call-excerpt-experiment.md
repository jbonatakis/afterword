# Call excerpt experiment

Does competing lexical and semantic evidence help someone answer a question from the first three excerpts in `search_activity`? The baseline is the coding-session build at `243199e`. Both helpers use the existing Qwen3 0.6B weights, same frozen corpus, case labels, result ordering logic and model threshold. The candidate changes only how call excerpts are delivered. It ranks body snippets with SQLite BM25, combines their per-call ranks with embedding ranks using reciprocal-rank fusion (constant 4), prioritizes visible quoted phrases and offers up to three disjoint excerpts of 260 characters each.

## Decision and measures

- Primary regression measure is the fraction of supported call-only questions with an accepted source and labeled answer in the **first three displayed excerpts**. Read results in order and exhaust each result's excerpts before moving on. The old helper contributes one excerpt per call. Evaluate both splits separately.
- Also report the first excerpt alone at equal excerpt count, the first result's three excerpts, source ordering, and whether candidate call citations resolve to the displayed text. A citation to a long paragraph by itself earns zero visible-evidence credit.
- Include the complete mixed and coding runs as controls. Keep unsupported questions separate. The candidate changes no off-topic acceptance thresholds.
- In a shuffled review of real regression calls, score the displayed evidence on its own. Mark whether it answers the question (including a clear paraphrase), provides only partial evidence, or supplies no answer. For quoted lookups, require the complete quote. Score before opening the assignment key. A reviewer here knows the design and may recognize the output styles.
- Freeze the candidate before scoring. Keep an improvement on the real questions as a reason to continue if source order and citation integrity hold. Deployment requires replication on later calls, with new questions and accepted evidence labeled before inspecting either build. Keep meetings about the same decision together.

## November 17 results

Each numerator counts answerable call-only questions for which the displayed text from an accepted call contains a labeled answer phrase. Each pair is baseline → candidate.

| Questions | First excerpt | First three excerpts |
|---|---:|---:|
| Real, development (3) | 2 → 1 | 2 → 2 |
| Real, previously inspected holdout (7) | 0 → 2 | 0 → 3 |
| Sample, development (8) | 7 → 5 | 7 → 8 |
| Sample, previously inspected holdout (8) | 8 → 8 | 8 → 8 |

Three regression questions gained a visible answer. Two tested the same decision. One result lost useful evidence when excerpts from the first source exhausted the reading budget.

All 48 paired searches returned the same sources in the same order through rank three. All 243 returned candidate call excerpts with transcript citations resolved to the words in the frozen transcript versions. The ten coding-only control queries returned identical captured items. Neither build rejected the previously inspected off-topic question on either corpus. On the seven real regression holdout questions, median total excerpt text in the three-result response increased from 425 to 1,202 characters. The median text in just the first three excerpts went from 425 to 367.

The author's shuffled review rated six real questions better, one worse and three tied across both splits. Four of ten exposed a full answer, up from zero under that rubric. This counts paraphrases and requires answering the question, so a snippet can pass the literal-anchor metric and still only partially answer it. The reviewer knew the design, saw the queries previously and could recognize formatting differences. This was a qualitative check.

Keep this as an experiment. In particular, test whether one source should consume the entire reading budget when the runner-up has useful evidence. For the prospective check, collect real questions before searching, identify accepted calls and answer passages directly in the new transcripts, and freeze both library and labels. Run these same two helpers first, without further tuning. Report per-question outcomes with related questions grouped by decision.

## Repeat the comparison

Follow the snapshot instructions in [search-quality.md](search-quality.md). On a Mac with an available local model, build the candidate with `./Scripts/swift-command.sh build -c release --product AfterwordMCP`. Copy its binary to a separate directory with the baseline's sibling `EmbeddingWorker`. Point `before` and `after` below at the respective MCP executables. Use a private directory for reports containing transcript text.

```sh
mkdir -p "$reports"
for split in dev holdout; do
  for variant in before after; do
    if [ "$variant" = before ]; then helper="$before"; else helper="$after"; fi
    python3 Scripts/benchmark-search.py run "$snapshot" --cases "$cases" \
      --executable "$helper" --split "$split" --capture-excerpts \
      --report "$reports/$split-$variant.json" || exit 1
  done
  python3 Scripts/review-call-excerpts.py prepare \
    "$reports/$split-before.json" "$reports/$split-after.json" \
    "$cases" "$snapshot" "$after" "$reports/$split-review" || exit 1
done
```

Each review directory contains `audit.json` with call-only scores and citation checks, a shuffled `review.json`, and a separate `key.json`. Grade each option in `review.json` as `answers`, `partial`, or `none` before opening the key, then run `python3 Scripts/review-call-excerpts.py reveal "$reports/holdout-review"`. Use a new review directory on repeat runs to preserve completed ratings.

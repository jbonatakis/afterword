# Main-thread responsiveness experiment

The experiment moves mixed-library ordering, audio-player preparation, and the new-contact attendance transaction off the main actor. UI publication, selection, player commands, and capture priority stay on the main actor. All three candidates run in the existing app process.

## Method

The control is `f1ad3bc`. The candidate is `e2f01d8`. Both use the same release-optimized core and native fixture. The control includes a search-debounce compatibility change. Before that change the optimized fixture twice aborted in the Swift concurrency runtime during debounced search. Both measured builds use the same 150 ms debounce with the nanoseconds overload.

All fixture data is generated locally. Each call has a one-minute AAC track, half have transcripts, and each call contributes two coding sessions, four GitHub items and four initial directory contacts to the fixture. Search deliberately returns results across all three sources. All measurements are warm, with two excluded iterations per process, on one Apple silicon Mac running macOS 15.8.3 and Swift 6.2.3.

Each sample records elapsed time through the usable result and the longest interval between opportunities to service a 1 ms main-queue timer. The measurement includes the start and end of the operation. A synchronous operation therefore records its whole duration as a main-queue gap. The gap includes timer scheduling jitter. Search includes querying, ranking and publication after debounce. Playback includes opening the file and preparing a usable player. Playback switching also includes disposing of the previous player. Attendance includes writing both files and publishing the directory, with a separate fixture coordinator to keep the subsequent scan out of the next sample. The contention fixture takes the real call write lock and schedules its release after 50 ms.

The timings cover the model through publication. SwiftUI rendering, typing latency on a physical keyboard, indexing throughput, battery use and memory growth are outside this measurement. Offscreen native fixtures exercise rendering and functional behavior separately.

## Reproduction

Run the same commands in a checkout of each revision. The first positional argument after `--release` is the call count. The second is the measured trial count. Each process generates a fresh library.

```sh
./Scripts/check-library.sh Tests/MainThreadBenchmark.swift --release 12 15
./Scripts/check-library.sh Tests/MainThreadBenchmark.swift --release 150 25
./Scripts/check-library.sh Tests/MainThreadBenchmark.swift --release 500 41
```

Run one benchmark at a time, and repeat in the opposite order. The fixture prints the median and nearest-rank 95th percentile for both measurements and checks result membership and ordering. The running Afterword app can stay open.

## Results

Times are milliseconds. A range spans the two independently measured run statistics. Each large-library run had 41 measured trials. The medium-library runs had 25 each, and the small-library runs had 15.

### 1,050 mixed rows

| Operation | Main gap p95, control | Main gap p95, candidate | Elapsed median, control | Elapsed median, candidate | Elapsed p95, control | Elapsed p95, candidate |
|---|---:|---:|---:|---:|---:|---:|
| Search across sources | 5.1–5.4 | 2.1–3.5 | 20.5–21.4 | 20.8–27.7 | 21.3–22.3 | 22.3–34.2 |
| Switch to GitHub during search | 1.8 | 0.6–1.3 | 1.7 | 0.5–0.7 | 1.8 | 0.6–1.3 |
| Switch to With transcripts | 0.6 | 0.4–1.4 | 0.5–0.6 | 0.4–0.7 | 0.6 | 0.4–1.4 |
| Switch to All activity | 1.8–1.9 | 0.9–2.9 | 1.6–1.7 | 0.9–1.3 | 1.8–1.9 | 0.9–2.9 |
| Clear search | 1.9–2.1 | 1.2–2.8 | 1.7–1.9 | 1.0–1.7 | 1.9–2.1 | 1.2–2.8 |
| Refresh the library | 2.9–3.0 | 2.1–3.9 | 37.8–39.4 | 37.0–53.9 | 40.6–40.9 | 38.4–88.5 |
| Open a recording | 13.7–13.8 | 7.4 | 13.6 | 13.5–14.4 | 13.7–13.8 | 13.9–15.3 |
| Switch recordings | 13.9–14.2 | 7.3–7.4 | 13.8 | 13.5–14.5 | 13.9–14.2 | 14.1–15.8 |
| Save a new contact and attendance | 4.5–4.9 | 1.3 | 4.1 | 4.1–5.8 | 4.5–4.9 | 4.5–8.7 |
| Save while the call lock is held | 59.9–60.2 | 1.3–3.6 | 58.0–58.3 | 54.5–56.2 | 59.9–60.2 | 54.9–57.8 |

### 3,500 mixed rows

| Operation | Main gap p95, control | Main gap p95, candidate | Elapsed median, control | Elapsed median, candidate | Elapsed p95, control | Elapsed p95, candidate |
|---|---:|---:|---:|---:|---:|---:|
| Search across sources | 16.2–20.7 | 5.3–5.8 | 69.5–70.4 | 68.3–68.8 | 81.5–123.2 | 74.4–75.7 |
| Switch to GitHub during search | 6.1–7.7 | 1.6–1.7 | 5.8 | 1.4 | 6.1–7.7 | 1.6–1.7 |
| Switch to With transcripts | 1.6–2.2 | 1.2 | 1.5 | 1.1 | 1.6–2.2 | 1.2 |
| Switch to All activity | 6.9–7.3 | 3.9–4.0 | 6.2–6.3 | 3.5 | 6.9–7.3 | 3.9–4.0 |
| Clear search | 7.3–9.6 | 4.6–4.9 | 6.6–6.8 | 4.0 | 7.3–9.6 | 4.6–4.9 |
| Refresh the library | 8.1–9.6 | 5.3–5.6 | 125.7–126.2 | 125.4–125.7 | 131.8–146.8 | 140.2–153.9 |
| Open a recording | 13.8–14.1 | 7.4 | 13.5–13.7 | 13.7–13.8 | 13.8–14.1 | 14.4 |
| Switch recordings | 14.4–14.9 | 7.3–7.4 | 13.8–13.9 | 13.5 | 14.4–14.9 | 14.0–14.1 |
| Save a new contact and attendance | 11.1–16.4 | 1.3 | 10.4–10.6 | 10.7–10.8 | 11.1–16.4 | 11.7 |
| Save while the call lock is held | 66.8–67.2 | 1.3 | 65.1–65.4 | 61.0–61.1 | 66.8–67.2 | 61.9–62.0 |

At 84 rows the search gap p95 was 2.0 ms in the control and 1.3 ms in the candidate. With transcripts was 0.5 and 0.5 ms respectively. Opening audio was 16.6 and 7.5 ms. Contended attendance was 60.7 and 1.5 ms.

## Interpretation

- **Attendance has the largest benefit.** The 50 ms hold models another writer owning the same file lock. At 3,500 rows the UI could service the queue within 1.3 ms at p95 while the transaction still took about 62 ms to finish. An uncontended save also released the UI during the directory write.
- **Search ordering pays off as the library grows.** At 3,500 rows, both runs cut the p95 main-queue gap by more than 10 ms with similar median time to usable results. Switching sources while searching also became faster end to end. At 84 rows the With transcripts operation was already about half a millisecond. This fixture cannot account for a multi-second visible delay there.
- **Opening audio releases roughly half the main-thread stall.** At 3,500 rows p95 readiness took 14.4 ms against 13.8–14.1 ms in the control. The fixture polls readiness every 0.25 ms while preparation is pending, so part of this sub-millisecond difference can be observation delay. File selection, seeking, and the pause action remain usable while preparation is pending.
- **Full refresh timing varied.** In one paired stress run p95 elapsed rose from 131.8 to 153.9 ms. In the other it fell from 146.8 to 140.2 ms. Both runs kept the median near 126 ms and reduced the p95 main gap. One 1,050-row candidate run was slower across several operations, including refresh. The repeat returned to the control's range. The timing benefit is repeatable for main-queue responsiveness. Full-refresh elapsed time is inconclusive.

The three scoped changes merit integration for responsiveness. Keep the existing UI and capture ownership. All measured gains came from work scheduled within the existing process.

## Correctness checks

The benchmark compares row ordering to the original mixed-source ranking contract, checks filtered membership and restores the original ordered timeline after clearing the query. It also exercises superseded searches, immediate work/personal isolation, and a scope round trip. Timed operations require usable audio or durable call information and linked contacts before the sample is accepted.

The native playback fixture exercises queued play, pause and seek, rapid track and call changes, capture taking priority, clearing a pending selection, and recovery after a missing file. Calendar checks exercise overlapping directory edits, a stale call revision, and forced failure of the call-details write after saving the contact. Both files and the in-memory directory must agree after rollback.

The core suite and native library, source-selection, long-transcript reader and calendar fixtures passed. The native fixtures ran offscreen. To repeat them, run the following commands from the candidate checkout.

```sh
./Scripts/test.sh
./Scripts/check-library.sh --release
'build/Library Check.app/Contents/MacOS/LibraryCheck' --sources
'build/Library Check.app/Contents/MacOS/LibraryCheck' --reader
./Scripts/check-calendar-integration.sh
```

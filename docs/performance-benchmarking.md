# Performance benchmarking

## Audio capture hardware check

After configuring local Team ID signing, run `RUN_AUDIO_CAPTURE_SMOKE=1 scripts/dev.sh test`
to include three rapid microphone stop/restart cycles. This check uses real
capture controllers and different setup queues through the shared restart gate.
It counts callbacks and discards audio samples. It requires microphone permission
already granted to the Debug app and skips without prompting when permission is
unavailable. Normal test runs skip this hardware check. Full dictation checks on
speaker and Bluetooth/headphone routes remain useful for output restoration and
recognizer-level engine switching.

Run the repeatable benchmark suite from the repository root:

```sh
./scripts/dev.sh benchmark --release
```

The Release command targets the host's native macOS architecture (arm64 on
Apple Silicon, x86_64 on Intel) with local Team ID development signing and
testable Release optimization. Run `./scripts/dev.sh signing TEAM_ID` once to
create the ignored local signing configuration. The default `benchmark` command
instead runs Debug and is useful for relative comparisons, not absolute
production latency. Repeat with `DICTATE_ANYWHERE_PERF_TRACE=0` to measure
instrumentation overhead. Preserve the device, OS, model revision, and build
configuration with results; local Release benchmarks trace by default even
though distributed Release archives do not. The trace records device, OS, and
build configuration, while model revision must be recorded separately. The app and
dependencies are Release-optimized; benchmark runs also compile the XCTest
harness with `-O`. Synthetic test-loop timings still exclude full app rendering
and are not production absolute timings.

Use registered groups to run focused benchmarks:

```sh
./scripts/dev.sh benchmark --list
./scripts/dev.sh benchmark --only overlay
./scripts/dev.sh benchmark --release --only audio,overlay
./scripts/dev.sh benchmark --only insertion --only recovery
```

`--only` accepts comma-separated groups and can be repeated. Repeated groups
are deduplicated. The default is `all`; unknown or empty groups fail before
building. Groups are registered with their descriptions and Xcode test
selectors in one catalog in `scripts/dev.sh`. Add new benchmark selectors
there to make them available through `--list` and focused runs. Benchmarks
compile both app and tests with `-O` for consistent helper comparisons.

| Component | Coverage |
| --- | --- |
| Offline ASR | Replays the bundled speech fixture through installed Parakeet and available Apple Speech engines. Reports latency, duration, median real-time factor, and beginning/end recognition sentinels. |
| Vocabulary preflight | Uses a human proper-name recording to require that eligible corrections still run and unrelated vocabulary preserves the original transcript on both separate and shared CTC paths. Requires installed Parakeet v3 or 110M and CTC assets; never downloads models. |
| Mandarin ASR quality | Replays the four bundled, referenced Mandarin fixtures through installed SenseVoice. Reports CER and per-fixture p50/p95; skips if the model is not installed. |
| User audio quality | If both `PIPELINE_BENCHMARK_AUDIO_PATH` and `PIPELINE_BENCHMARK_REFERENCE_PATH` are provided, replays a local 16 kHz mono fixture and reports WER. No audio or reference content is uploaded or logged by the harness. |
| Audio polling | Processes fixed sample windows and measures RMS/smoothing plus meaningful-display-change decisions. |
| PCM buffer creation | Repeatedly calls the app's 4096-frame 16 kHz buffer builder. XCTest records clock, CPU, and memory metrics. |
| Cloud request encoding | Converts 60 s of synthetic samples to PCM16 and builds AssemblyAI's multipart body, without network access. XCTest records clock, CPU, and memory. |
| Recovery I/O | Enqueues 30 s of synthetic audio through the real recovery writer, preserves it, reloads, and reads bounded chunks. Reports save and read p50/p95. |
| Long transcript | Joins 300 disjoint transcript segments and normalizes the result. XCTest records clock, CPU, and memory. |
| Insertion preparation | Replays whitespace, list, CJK, and boundary fixtures through insertion formatting. |
| Paste script compilation | Compares repeated AppleScript compilation with the production precompile and cached path, without sending keystrokes. |
| S1-mini policy | Exercises the production startup-prewarm decision matrix. |
| S1-mini model load | Measures production prewarm with the app's validated installed model, or an explicit `S1_MINI_MODEL_PATH`; never downloads. |
| S1-mini cleanup | With the app's validated installed model, or `S1_MINI_MODEL_PATH`, runs short and long text through the real local cleanup service and reports cold/warm request timings. |
| Apple Intelligence cleanup | Runs a fixed cleanup prompt through the on-device Foundation Models service when available. Schema success and fallback are visible in performance traces. |
| Model switching | With `RUN_MODEL_SWITCH_BENCHMARK=1` and at least two installed models, times a fixed model-switch sequence. |

Set `PIPELINE_BENCHMARK_MODEL=all` to sweep models already installed on this
Mac; the default is `parakeetEou320`. The suite does not download models.
The benchmark command forwards the documented environment variables to the
XCTest host using Xcode's `TEST_RUNNER_` convention
([Xcode 13 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-13-release-notes));
setting them on a bare `xcodebuild` invocation does not have the same effect.
Use `PIPELINE_BENCHMARK_ITERATIONS=5` for longer runs (default 3), and save the
`.xcresult` bundle for XCTest's per-iteration CPU/memory/clock measurements.
For a meaningful offline ASR p95 comparison, use at least 20 iterations; with
three samples, nearest-rank p95 is simply the slowest observation. The workload
tests cap their iteration count at 10, so their p95 values are exploratory.
S1-mini's first request after unload measures model initialization, but the
operating system's file and Metal shader caches may already be warm; restart
the test host for a truly cold-process comparison.
When supplying your own audio, optionally set `PIPELINE_BENCHMARK_MAX_WER=0.3`
to enforce an agreed quality gate. An external real-voice fixture is useful
because the bundled Mandarin recordings are synthetic speech; see the
[LibriSpeech corpus](https://openslr.org/12) (CC BY 4.0) for a source with
reference transcripts. Keep any separately sourced fixture's license and
provenance with that fixture.

These benchmarks do not measure real Accessibility activation, target-app paste
latency, Core Audio or Bluetooth routing, or microphone startup. Those remain
covered by performance traces from live app runs. The offline ASR test skips
Parakeet when the selected model is not installed and skips Apple Speech when
its assets or authorization are unavailable. Each run reuses an engine across
iterations: it is not a cold-process/warm-model/warm-session matrix. The
offline ASR and recovery timings report p50/p95, and XCTest records CPU/memory
for the synchronous workload tests. These are not whole-app CPU or peak-memory
measurements. Energy, thermal state, microphone callback overruns, and live UI
latency still require Instruments and real app runs before product decisions.

For vocabulary preflight changes, compare final text with the always-run
acoustic path using identical SDK, model files and correction settings. This
checks optimization equivalence. Vocabulary accuracy against the recording's
reference is a separate check: an existing over-correction in both paths is not
a regression caused by skipping inference. The preflight must still run CTC
whenever the SDK's candidate or acoustic-rescue rules require evidence.

`OverlayContentTests` always runs in the normal test suite. It evaluates the
production preview and waveform bodies under Observation tracking and proves
that 600 level-only updates cause zero transcript-content invalidations. It
also covers preview disabled, same-length corrections, empty/resumed text, and
character-boundary/Unicode output. These are dependency checks rather than
counts of frames rendered by SwiftUI.

Run the focused overlay comparison after configuring local Team ID signing:

```sh
./scripts/dev.sh benchmark --only overlay
```

This command runs the dependency checks and compares the production bounded
suffix helper with the historical full-count algorithm on identical short/long
English and long CJK text. It compiles **both** the Debug app and test target
with `SWIFT_OPTIMIZATION_LEVEL=-O`. It alternates measurement order, consumes results, checks matching
output, and reports median microseconds per call over five rounds. Timings have
no pass/fail threshold. The separate `DictateAnywhere-Benchmark.xcresult` bundle
preserves the normal test result bundle. These optimized Debug helper timings
do not measure whole-app CPU, UI frames, or energy use.

XCTest performance tests run one unrecorded warm-up plus the configured
measurement iterations ([Apple documentation](https://developer.apple.com/documentation/xctest/xctmeasureoptions/iterationcount)).
XCTest memory metrics measure memory change during the block, not the app's
high-water mark ([Apple documentation](https://developer.apple.com/documentation/xctest/xctmemorymetric)).

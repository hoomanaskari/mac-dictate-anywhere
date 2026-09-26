# Performance tracing

`PerfTrace` emits `OSSignposter` intervals and unified-log notice records.
Records contain static trace names, timings, outcomes, session configuration,
and numeric workload facts. They never contain audio, transcripts, prompts,
file paths, or the target application's identity. Session labels include the
selected engine/model/language, a random session ID, device model, OS version,
and build configuration; treat exported logs as diagnostic data. Intervals
snapshot their session labels when they begin, so an async operation finishing
after a new dictation starts retains its original session ID. A request-to-recording
span explicitly refreshes its configuration labels after an awaited input-profile
apply without changing its start time or session ID. Tracing defaults on in local
Debug and Release builds, including Release benchmarks. The distributed app
archived by `scripts/release-macos.sh` defaults it off via `DISTRIBUTION_BUILD`.
At launch, `DICTATE_ANYWHERE_PERF_TRACE=1` enables tracing or
`DICTATE_ANYWHERE_PERF_TRACE=0` disables it in either build; an unset value uses
the build default. This is a launch-time developer diagnostic, not a Settings
toggle. When disabled, spans reuse an inert token and skip signposts, clocks,
interval locks, and lazily supplied count dictionaries and session labels.
Ending an inert token returns false; it must not gate cleanup of an aborted session.

Aborted recording starts clear their session labels; resumed recovery dictations
create a new session so their capture and insertion spans can be correlated.

## Capture a dictation

Use Instruments with the `os_signpost` instrument and filter to the app's
`Performance` category. For a historical text view, run:

```sh
log show --style compact --predicate 'category == "Performance" AND composedMessage CONTAINS "trace "' --last 15m
```

An interval produces `trace <name> duration_ms=<milliseconds> outcome=<value>`.
Durations use a monotonic clock. Manually scoped spans default to `ended`,
which does not imply success; measured throwing operations report `completed`,
`failed`, or `cancelled`. `dictation.stopToInsertion` reports `success`,
`copiedOnly`, or `failed` for delivery, `noText` for an empty result, and
`cancelled` or `aborted` for an interrupted stop. A point marker
produces `trace <name> event=observed` and is therefore visible both in
Instruments and in historical logs.

Filter by `session_id` to compare one dictation. `input_samples`, `new_samples`,
and `reprocessed_samples` on `stt.batchPreview` describe each call, not the
entire recording. `stt.transcribe` nests beneath preview, commit, or final-tail
spans. The first-partial event means recognition produced nonempty, non-final
live text; it is not a UI-render or audio-callback timestamp. A missing event
means no live partial appeared. `audio.captureSummary` records captured and
dropped pending samples for Parakeet; it does not measure Core Audio hardware overruns.
`stt.appleSpeechInputSummary` records attempted, converted, and rejected input
buffers but not analyzer queue depth or processing lag.
S1-mini's `input_tokens`, `prompt_tokens`, and `output_tokens` are request-local;
`output_bytes` measures UTF-8 output size.

## Pipeline map

| User-visible boundary | Trace names |
| --- | --- |
| Startup and switching | `app.startup`, `app.permissionCheck`, `app.appleSpeechAssetRefresh`, `app.inputSourceApply`, `stt.prepare`, `stt.modelSwitch`, `stt.enginePrepare`, `stt.modelLoad` |
| Accepted hotkey request to confirmed microphone capture | `dictation.requestToRecording`, `dictation.inputSourceApply`, `dictation.capture`, `dictation.contextCapture`, `dictation.start`, `audio.startup`, `audio.controllerWait`, `audio.controllerCreate`, `audio.microphoneBoost`, `audio.systemMute` |
| Live recognition availability | `stt.firstPartial`, `stt.batchPreview`, `stt.chunkCommit`, `stt.streamingProcess`, `stt.transcribe`, `audio.captureSummary`; Apple Speech reports `stt.appleSpeechSessionStart`, `stt.appleSpeechAssetInstall`, `stt.appleSpeechAnalyzerPrepare`, `stt.appleSpeechInputSummary`; AssemblyAI also reports `stt.livePreviewStart` and `stt.assemblyAIWarmConnection` |
| Automatic end-of-utterance | `eou.detected`, `eou.stop`, followed by the regular stop path |
| Stop recording to final transcript | `dictation.stopToInsertion`, `stt.stopToFinal`, `audio.teardown` (first controller shutdown), `stt.livePreviewStop` (AssemblyAI preview), `stt.finalize`, `stt.finalTail`, `stt.streamingFinish`, `stt.finalVocabulary`, `stt.transcribe` |
| FluidAudio vocabulary final pass | `stt.vocabularyBoost`, `stt.ctcModelLoad`, `stt.ctcTokenizerLoad`, `stt.vocabularyEncode`, `stt.vocabularyManagerSetup`, `stt.vocabularyInference`, `stt.vocabularyCleanup` |
| AssemblyAI final request | `stt.assemblyAIFinal`, `stt.assemblyAIRequestBuild`, `stt.assemblyAIRequest`, `stt.assemblyAIResponseDecode`, `stt.warmConnectionWait` |
| Local cleanup | `cleanup.validate`, `cleanup.request`, `cleanup.modelLoad`, `cleanup.tokenize`, `cleanup.promptEval`, `cleanup.decode`, `cleanup.generate` |
| Apple Intelligence cleanup | `cleanup.appleIntelligenceSchema`, `cleanup.appleIntelligenceSchemaAccepted`, `cleanup.appleIntelligenceToolsFallback`, `cleanup.appleIntelligenceTools` |
| Remote cleanup | `cleanup.ollamaReasoningLookup`, `cleanup.ollamaRequest`, `cleanup.ollamaServerTimings`, `cleanup.openRouterRequest`, `cleanup.openAICompatibleRequest`; Ollama's server-reported timings follow the same trace switch |
| Delivery and restoration | `transcript.normalize`, `transcript.history`, `insertion.targetActivation`, `insertion.deliver`, `insertion.prepare`, `insertion.listEdit`, `insertion.clipboard`, `insertion.pasteScript`, `insertion.pasteScriptCreate`, `insertion.pasteEvent`, `insertion.listEditVerify`, `dictation.teardown`, `audio.microphoneRestore`, `audio.systemRestore` |
| Cancel and recovery paths | `dictation.cancel`, `recovery.captureStart`, `recovery.preserve`, `recovery.discard`, `recovery.reload`, `recovery.transcribe`, `recovery.continue` |

Compare one trace at a time: `dictation.stopToInsertion` ends when delivery
returns (including copied-only or failed delivery), before post-delivery audio
restoration and recovery discard. For an empty transcript or recognition failure,
it ends before the corresponding cleanup. A delivery attempt has a separate
`dictation.teardown` span. Then inspect the nested ASR, cleanup, activation,
and insertion spans
to identify the largest cost. For recording-start regressions, start from
`dictation.requestToRecording` and distinguish context capture, audio routing,
audio-controller creation, and engine session startup before changing behavior.
`audio.controllerWait` includes queueing and the caller's timeout; `audio.controllerCreate`
tracks actual construction and may finish later if CoreAudio is blocked. The
request-to-recording span ends before an immediate hold-to-record stop begins.
`insertion.pasteScriptCreate` times object creation only; any implicit AppleScript
compilation or execution remains inside `insertion.pasteScript`.
Use Instruments' Time Profiler, Allocations, Energy Log, and audio diagnostics
alongside these application spans for CPU, memory, thermal behavior, callback
duration, and hardware dropouts; these are not measured by `PerfTrace`.

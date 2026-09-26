# Automated performance smoke run — 2026-09-24

This is a **harness validation sample**, not a performance target or a
before/after claim. Run `scripts/dev.sh benchmark --release` for current data.

- Host: Mac15,10 (Apple M3 Max), macOS 26.7, native arm64.
- Build: Release-optimized app and pinned FluidAudio 0.16.1 / llama.swift
  2.10549.0; Apple Development Team signing; XCTest harness `-Onone`.
- Three request samples unless stated otherwise. At this sample count,
  nearest-rank p95 is just the maximum and should not be used as a gate.
- Source audio: bundled `en-recovery.wav`; no live microphone or target app.
- S1-mini: locally installed `s1-mini-q4_k_m.gguf`; the model load reported
  below benefited from OS caches after an earlier run.

| Workload | Observed sample |
| --- | --- |
| Parakeet EOU offline file ASR | Model prepare ~388 ms; request p50 ~537 ms, p95 ~604 ms for 167,936 samples (~10.5 s). Beginning/end sentinel words survived. |
| Apple Intelligence cleanup | First request ~1.05 s; next two ~0.61 s and ~0.60 s. Schema path accepted all three, no tools fallback. |
| S1-mini cleanup, short | First after unload ~275 ms, then warm requests ~90 ms (9 output tokens). |
| S1-mini cleanup, long | Warm requests ~0.97–0.99 s (204 output tokens, 647 input characters). |
| Recovery capture and reload/read | 30 s synthetic PCM; save p50 ~1.35 ms and read p50 ~0.60 ms. This host's cached storage makes those numbers optimistic. |
| PCM buffer construction | 200 x 4096-frame buffers in ~0.63 ms, XCTest clock measurement. |
| AssemblyAI request encoding | 60 s PCM produces a ~1.92 MB multipart body in ~1.95 ms, XCTest clock measurement; no network request. |
| Long transcript assembly | 300 segments / ~11.9k characters in ~1.45 ms, XCTest clock measurement. |

The same Release command with `DICTATE_ANYWHERE_PERF_TRACE=0` correctly
suppressed all `Performance` trace lines after forwarding the launch variable
to XCTest's host. Its timings were noisy and should not be interpreted as a
measured tracing-overhead percentage without interleaved repetitions and
controlled thermal state.

Skipped on this host: SenseVoice Mandarin CER (model absent), model switching
(requires at least two installed models), external real-voice WER (no supplied
audio/reference). Apple Speech file ASR also requires installed assets and
test-host authorization. Neither GPU/ANE placement, audio callback overruns,
nor insertion into a real target is measured here.

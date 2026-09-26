import AppKit
import XCTest
@testable import Dictate_Anywhere

/// Deterministic benchmarks for pipeline work that does not require a real
/// target application, Accessibility, microphone, or Core Audio routing.
@MainActor
final class PipelinePerformanceBenchmarkTests: XCTestCase {
    private var iterations: Int {
        max(1, Int(ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3)
    }

    private func requireBenchmark() throws {
        #if PIPELINE_BENCHMARK
        #else
        throw XCTSkip("Run scripts/dev.sh benchmark to enable pipeline benchmarks")
        #endif
    }

    func testAudioPollingBenchmark() throws {
        try requireBenchmark()
        let sampleWindow = Array((0..<1_600).map { index in
            sin(Float(index) * 0.03) * 0.08
        })
        let updateCount = iterations * 1_000
        let monitor = AudioMonitor()
        var meaningfulUpdateCount = 0
        var lastDisplayedLevel: Float?
        let startedAt = ContinuousClock.now

        for _ in 0..<updateCount {
            #if PIPELINE_CHILD_BENCHMARK
            monitor.update(samples: sampleWindow[...])
            #else
            monitor.update(samples: sampleWindow)
            #endif
            #if PIPELINE_CHILD_BENCHMARK
            let shouldDisplay = AudioMonitor.hasMeaningfulLevelChange(
                from: lastDisplayedLevel, to: monitor.smoothedLevel
            )
            #else
            let shouldDisplay = lastDisplayedLevel == nil
                || abs(monitor.smoothedLevel - (lastDisplayedLevel ?? 0)) >= 0.01
            #endif
            if shouldDisplay {
                meaningfulUpdateCount += 1
                lastDisplayedLevel = monitor.smoothedLevel
            }
        }

        let elapsed = startedAt.duration(to: .now)
        XCTAssertGreaterThan(meaningfulUpdateCount, 0)
        XCTAssertLessThanOrEqual(meaningfulUpdateCount, updateCount)
        print(
            "PIPELINE_BENCHMARK component=audio_polling iterations=\(updateCount) "
            + "meaningful_updates=\(meaningfulUpdateCount) elapsed=\(elapsed)"
        )
    }

    func testInsertionPreparationBenchmark() throws {
        try requireBenchmark()
        let fixtures = [
            ("  hello world  ", "hello world"),
            ("\n- strawberries\n", "- strawberries"),
            ("你好，世界", "你好，世界"),
            ("meeting notes\n", "meeting notes")
        ]
        let inserter = TextInserter()
        let startedAt = ContinuousClock.now
        var outputCount = 0

        for _ in 0..<iterations * 1_000 {
            for (input, expected) in fixtures {
                let output = inserter.preparedTextForInsertion(
                    input,
                    targetBundleIdentifier: "com.example.benchmark",
                    targetProcessIdentifier: nil,
                    context: nil,
                    style: nil,
                    knownTerms: []
                )
                XCTAssertEqual(output, expected)
                outputCount += output.utf16.count
            }
        }

        let elapsed = startedAt.duration(to: .now)
        XCTAssertGreaterThan(outputCount, 0)
        print(
            "PIPELINE_BENCHMARK component=insertion_prepare cases=\(iterations * 4_000) "
            + "elapsed=\(elapsed)"
        )
    }

    func testPasteScriptCacheBenchmark() async throws {
        try requireBenchmark()
        let source = """
            tell application "System Events"
                keystroke "v" using command down
            end tell
            """
        let compileCount = max(1, iterations * 10)
        // Match the paste path's worker queue; compiling on the main thread
        // triggers a responsiveness diagnostic and skews the baseline.
        let (uncachedElapsed, compileError) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let startedAt = ContinuousClock.now
                var failure: String?
                for _ in 0..<compileCount {
                    var error: NSDictionary?
                    guard let script = NSAppleScript(source: source),
                          script.compileAndReturnError(&error) else {
                        failure = String(describing: error)
                        break
                    }
                }
                continuation.resume(returning: (startedAt.duration(to: .now), failure))
            }
        }
        XCTAssertNil(compileError, "AppleScript compile failed: \(compileError ?? "unknown")")

        #if PIPELINE_CHILD_BENCHMARK
        let inserter = TextInserter()
        let firstCachedStartedAt = ContinuousClock.now
        inserter.prewarmPasteScript()
        let firstCachedElapsed = firstCachedStartedAt.duration(to: .now)

        let cachedStartedAt = ContinuousClock.now
        for _ in 0..<compileCount {
            inserter.prewarmPasteScript()
        }
        let cachedElapsed = cachedStartedAt.duration(to: .now)

        print(
            "PIPELINE_BENCHMARK component=paste_script_compile count=\(compileCount) "
            + "uncached=\(uncachedElapsed) first_cached=\(firstCachedElapsed) cached=\(cachedElapsed)"
        )
        #else
        print(
            "PIPELINE_BENCHMARK component=paste_script_compile count=\(compileCount) "
            + "baseline_uncached=\(uncachedElapsed)"
        )
        #endif
    }

    func testS1MiniPrewarmBenchmark() async throws {
        try requireBenchmark()
        let cases: [(TranscriptPostProcessingMode, SupportedLanguage, Bool)] = [
            (.s1Mini, .english, true),
            (.s1Mini, .german, true),
            (.none, .english, true),
            (.s1Mini, .english, false)
        ]
        #if PIPELINE_CHILD_BENCHMARK
        let enabledCount = cases.reduce(into: 0) { count, value in
            if S1MiniPrewarmPolicy.shouldPrewarm(
                mode: value.0, language: value.1, prewarmEnabled: value.2
            ) {
                count += 1
            }
        }
        #else
        let enabledCount = cases.filter {
            $0.2 && $0.0 == .s1Mini && $0.1 == .english
        }.count
        #endif
        XCTAssertEqual(enabledCount, 1)
        print("PIPELINE_BENCHMARK component=s1_mini_prewarm_policy enabled_cases=\(enabledCount)")

        #if PIPELINE_CHILD_BENCHMARK
        guard let path = ProcessInfo.processInfo.environment["S1_MINI_MODEL_PATH"],
              !path.isEmpty else {
            print("PIPELINE_BENCHMARK component=s1_mini_model_load skipped=no_model_path")
            return
        }
        let modelURL = URL(fileURLWithPath: path)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelURL.path), "S1-mini model path does not exist")

        let startedAt = ContinuousClock.now
        await S1MiniPostProcessingService.prewarm(modelURL: modelURL)
        let elapsed = startedAt.duration(to: .now)
        await S1MiniPostProcessingService.unload()
        print("PIPELINE_BENCHMARK component=s1_mini_model_load elapsed=\(elapsed)")
        #endif
    }
}

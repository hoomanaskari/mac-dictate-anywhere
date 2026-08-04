//
//  Hardware.swift
//  Dictate Anywhere
//
//  Runtime CPU-architecture detection used to gate models that ship only
//  Apple Neural Engine builds.
//

import Foundation

enum Hardware {
    /// True on Apple Silicon, which is the only Mac hardware with an Apple
    /// Neural Engine.
    ///
    /// The app ships a universal binary, so this cannot be a compile-time
    /// `#if arch(arm64)` check: the x86_64 slice runs on Intel *and* under
    /// Rosetta on Apple Silicon, where the ANE is in fact present.
    static let isAppleSilicon: Bool = {
        // Absent on Intel, so a failed lookup reads as "not Apple Silicon".
        if sysctlFlag("hw.optional.arm64") { return true }
        // A translated process is by definition running on Apple Silicon.
        return sysctlFlag("sysctl.proc_translated")
    }()

    /// Models whose only encoder build targets the ANE cannot run correctly
    /// without one — on other hardware they emit NaN or fail to load.
    static var hasAppleNeuralEngine: Bool { isAppleSilicon }

    private static func sysctlFlag(_ name: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }
}

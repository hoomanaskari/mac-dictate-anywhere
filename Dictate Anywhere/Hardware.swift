//
//  Hardware.swift
//  Dictate Anywhere
//
//  Compile-time architecture facts about the *running process slice*, used to
//  gate models whose only build targets the Apple Neural Engine.
//

import Foundation

// `nonisolated` throughout: the module defaults to `MainActor` isolation, but
// these are compile-time constants read from nonisolated contexts such as
// `ParakeetModelChoice`'s availability helpers.
enum Hardware {
    /// True when this process is executing the arm64 slice of our universal
    /// binary; false on the x86_64 slice, including when that slice is running
    /// under Rosetta on Apple Silicon hardware.
    ///
    /// This is a compile-time fact on purpose. It describes what *this
    /// process* can do, not what the machine underneath it is.
    nonisolated static let isArm64Process: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    /// Whether this process can load FluidAudio's ANE-targeted CoreML models.
    ///
    /// Must stay identical to FluidAudio's own gate. `SystemInfo.isAppleSilicon`
    /// there is a compile-time `#if arch(arm64)` check, and both
    /// `StreamingNemotronMultilingualAsrManager` entry points do
    /// `guard SystemInfo.isAppleSilicon else { throw ASRError.unsupportedPlatform }`.
    /// Because the x86_64 slice of a universal binary can be running under
    /// Rosetta on a Mac that physically *has* a Neural Engine, a runtime probe
    /// (`hw.optional.arm64` / `sysctl.proc_translated`) would answer "capable"
    /// exactly where FluidAudio refuses to load — offering a ~650 MB download
    /// that can only fail. So this deliberately mirrors the compile-time rule.
    ///
    /// Named for the capability, not the hardware: a Rosetta process on Apple
    /// Silicon is false here even though the machine physically has an ANE.
    nonisolated static var canUseAppleNeuralEngine: Bool { isArm64Process }
}

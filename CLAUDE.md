# CLAUDE.md - AI Assistant Guide for Dictate Anywhere

## Project Overview

**Dictate Anywhere** is a native macOS application that enables voice dictation anywhere using OpenAI's Whisper speech-to-text model via WhisperKit. Users press and hold the Fn key (or a button) to record audio, get real-time transcription, and automatically insert text into any focused input field.

**Key Features:**

- Global Fn key monitoring for hands-free dictation activation
- Real-time audio transcription using WhisperKit (on-device, no cloud)
- Multiple Whisper model variants with automatic downloads
- Live transcript display with audio waveform visualization
- Automatic text insertion via clipboard + keyboard simulation
- Microphone device selection
- Floating overlay window showing transcription status
- Menu bar integration for background operation

**Platform Requirements:**

- macOS 13+ (SwiftUI features)
- Swift 5.9+ (@Observable macro)
- Microphone and Accessibility permissions required

---

## Directory Structure

```
/Dictate Anywhere/
├── App/
│   └── AppDelegate.swift           # Menu bar setup, window management
├── Models/
│   └── WhisperModel.swift          # Model definitions and metadata
├── Services/                       # Core business logic
│   ├── AudioLevelMonitor.swift     # Real-time audio level calculation (RMS)
│   ├── ClipboardManager.swift      # Clipboard operations
│   ├── KeyboardMonitorService.swift # Global Fn key detection
│   ├── MicrophoneManager.swift     # Device enumeration & selection
│   ├── ModelManager.swift          # Model download/deletion/selection
│   ├── PermissionChecker.swift     # Microphone & Accessibility permissions
│   ├── TextInsertionService.swift  # Text pasting into focused inputs
│   └── TranscriptionService.swift  # WhisperKit integration (actor-based state)
├── ViewModels/
│   └── DictationViewModel.swift    # Main app state & orchestration
├── Views/
│   ├── DictationView.swift         # Main dictation UI
│   ├── GlassBackground.swift       # Visual effect utilities
│   ├── ModelDownloadView.swift     # Download progress screen
│   ├── ModelsView.swift            # Model management screen
│   ├── PermissionsView.swift       # Permission request UI
│   └── OverlayWindow/
│       ├── AudioWaveformView.swift      # Animated waveform (24 bars)
│       ├── OverlayContentView.swift     # Overlay UI states (auto-scrolling)
│       └── OverlayWindowController.swift # Floating window management
├── Assets.xcassets/
├── ContentView.swift               # Root view with state routing
├── Dictate_AnywhereApp.swift       # App entry point (@main)
└── Dictate_Anywhere.entitlements   # App entitlements
```

---

## Core Technologies

| Technology              | Purpose                                 |
| ----------------------- | --------------------------------------- |
| **WhisperKit**          | OpenAI Whisper speech-to-text for macOS |
| **SwiftUI**             | Declarative UI framework                |
| **AppKit**              | Window management, menu bar, clipboard  |
| **CoreAudio**           | Audio device enumeration                |
| **AVFoundation**        | Audio capture permissions               |
| **Accelerate**          | SIMD for audio RMS calculations         |
| **ApplicationServices** | Accessibility API for keyboard events   |
| **CoreGraphics**        | Keyboard event simulation (Cmd+V)       |

---

## Architecture

### State Machine

The app uses a central state machine in `DictationViewModel`:

```swift
enum AppState {
    case loading
    case checkingPermissions
    case permissionsMissing
    case downloadingModel
    case initializingModel
    case ready              // User can start dictation
    case listening          // Recording audio
    case processing         // Final transcription
    case modelManagement
    case error(String)
}
```

**State Flow:**

```
loading → checkingPermissions → permissionsMissing (if needed)
                             → downloadingModel → initializingModel → ready
ready ⟷ listening → processing → ready
```

### Service Architecture

Each service handles a single responsibility:

| Service                   | Responsibility                        | Key Methods                                            |
| ------------------------- | ------------------------------------- | ------------------------------------------------------ |
| `TranscriptionService`    | WhisperKit lifecycle, audio recording | `startRecording()`, `stopRecording()`, `forceCancel()` |
| `KeyboardMonitorService`  | Global Fn key monitoring              | `startMonitoring()`, `stopMonitoring()`                |
| `MicrophoneManager`       | Audio device enumeration              | `refreshDevices()`, `selectMicrophone()`               |
| `PermissionChecker`       | Permission checks/requests            | `checkPermissions()`, `requestMicrophonePermission()`  |
| `AudioLevelMonitor`       | Real-time RMS calculation             | `startMonitoring()`, `stopMonitoring()`                |
| `ModelManager`            | Model download/deletion               | `downloadModel()`, `deleteModel()`                     |
| `TextInsertionService`    | Clipboard + keyboard simulation       | `insertText()`                                         |
| `OverlayWindowController` | Floating overlay window               | `show()`, `hide()`, `updateState()`                    |

### Observable Pattern

All services and the ViewModel use Swift 5.9's `@Observable` macro for reactive state:

```swift
@Observable
class DictationViewModel {
    var state: AppState = .loading
    var liveTranscript: String = ""
    // ...
}
```

---

## Key Workflows

### Dictation Flow

```
1. Fn Key Press / Button Click
   └── DictationViewModel.startDictation()
       ├── State → .listening
       ├── Show overlay (loading)
       └── TranscriptionService.startRecording()
           ├── Start audio capture
           └── Begin transcription loop (500ms intervals)

2. During Recording
   ├── AudioLevelMonitor calculates RMS (30 FPS)
   ├── TranscriptionService updates liveTranscript
   └── Overlay shows waveform + live text

3. Fn Key Release
   └── DictationViewModel.stopDictation()
       ├── Hide overlay immediately (responsive UX)
       ├── If early release (no audio): forceCancel() → .ready
       ├── Else: State → .processing
       │   ├── Final transcription
       │   ├── TextInsertionService.insertText()
       │   │   ├── Copy to clipboard
       │   │   └── Simulate Cmd+V
       │   ├── Show success overlay
       │   └── State → .ready
```

### Model Management Flow

```
1. User opens Models screen
2. ModelsView displays current + available models
3. User selects new model
   └── ModelManager.selectModel()
       ├── Download via WhisperKit
       ├── Delete old model (optional)
       └── Reinitialize TranscriptionService
4. Return to ready state
```

---

## Code Conventions

### Naming

- **Classes:** PascalCase (`KeyboardMonitorService`)
- **Variables/Functions:** camelCase (`startDictation()`)
- **Enums:** PascalCase (`AppState`)

### File Organization

Use MARK comments to organize code:

```swift
// MARK: - State
// MARK: - Initialization
// MARK: - Public Methods
// MARK: - Private Methods
```

### Thread Safety

Use Swift actors for concurrent state access (Swift 6 compatible):

```swift
private actor RecordingStateManager {
    enum State { case idle, starting, recording, stopping }
    private var state: State = .idle

    func tryStart() -> Bool {
        guard state == .idle else { return false }
        state = .starting
        return true
    }
}
```

### Weak Self in Closures

Always use `[weak self]` in closures to prevent retain cycles:

```swift
globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
    self?.handleFlagsChanged(event)
}
```

### Async/Await

Use Swift structured concurrency:

```swift
Task { @MainActor [weak self] in
    await self?.transcriptionLoop()
}
```

---

## Available Whisper Models

| ID                               | Display Name    | Size   | Category      |
| -------------------------------- | --------------- | ------ | ------------- |
| `openai_whisper-tiny`            | Tiny            | 39 MB  | Fast          |
| `openai_whisper-tiny.en`         | Tiny (English)  | 39 MB  | Fast          |
| `openai_whisper-base`            | Base            | 74 MB  | Balanced      |
| `openai_whisper-base.en`         | Base (English)  | 74 MB  | Balanced      |
| `openai_whisper-small`           | Small           | 244 MB | Accurate      |
| `openai_whisper-small.en`        | Small (English) | 217 MB | Accurate      |
| `openai_whisper-medium`          | Medium          | 769 MB | Accurate      |
| `openai_whisper-large-v3`        | Large v3        | 1.5 GB | Best          |
| `distil-whisper_distil-large-v3` | Distil Large    | 594 MB | Fast+Accurate |

---

## Permission Requirements

### Microphone Access

- Checked via `AVCaptureDevice.authorizationStatus(for: .audio)`
- Required for audio capture

### Accessibility Permission

- Checked via `AXIsProcessTrusted()`
- Required for:
  - Global Fn key monitoring when app is not focused
  - Detecting focused UI element type
  - Simulating Cmd+V keypress via CGEvent

---

## Important Implementation Details

### Thread Safety

- Recording state uses Swift `actor` (`RecordingStateManager`) for atomic state transitions
- UI updates dispatched to `@MainActor`
- Swift 6 concurrency compatible

### Resource Management

- Background tasks store `Task` references for cleanup in `deinit`
- Event monitors removed in `deinit`
- WhisperKit audio buffer purged after each session

### Audio Processing

- RMS calculated with exponential smoothing (factor 0.3)
- Audio level updates at 30 FPS (~33ms intervals)
- Transcription updates every 500ms during recording
- Waveform visualization uses 24 animated bars with edge fading
- Minimum audio energy threshold (0.02 RMS) prevents hallucinations on silence

### Window Behavior

- Main window is `.floating` level (stays above other apps)
- Overlay is non-interactive (clicks pass through)
- Overlay visible on all Spaces, stays on top of fullscreen apps

### Text Insertion

- Checks focused element role via Accessibility API
- Only pastes if a text input is focused
- Falls back to clipboard-only if no text input detected

---

## Build Commands

This is an Xcode project. Build using:

- **Xcode:** Open `Dictate Anywhere.xcodeproj` and build (Cmd+B)
- **Command line:** `xcodebuild -project "Dictate Anywhere.xcodeproj" -scheme "Dictate Anywhere" build`

---

## Common Tasks for AI Assistants

### Adding a New Service

1. Create new file in `Services/` directory
2. Use `@Observable` class pattern
3. Add MARK comments for organization
4. Use `[weak self]` in all closures
5. Add cleanup in `deinit` if needed
6. Wire up in `DictationViewModel`

### Adding a New View

1. Create new file in `Views/` directory
2. Use SwiftUI with `@Bindable` for ViewModel access
3. Use `#Preview` for Xcode canvas
4. Add routing case in `ContentView` if needed

### Adding a New App State

1. Add case to `AppState` enum in `DictationViewModel`
2. Handle in `ContentView` switch statement
3. Add transitions in ViewModel methods

### Modifying Transcription Behavior

- Edit `TranscriptionService.swift`
- Key methods: `startRecording()`, `transcriptionLoop()`, `transcribe()`
- WhisperKit configuration in `initialize()`

### Changing Keyboard Shortcuts

- Edit `KeyboardMonitorService.swift`
- Currently monitors Fn key via `NX_DEVICELCTLFNKEY` flag

---

## Debugging Tips

1. **Permission Issues:** Check System Settings → Privacy & Security
2. **Model Not Loading:** Check model paths in `ModelManager.swift`
3. **No Audio:** Verify microphone selection in `MicrophoneManager`
4. **Overlay Not Showing:** Check `OverlayWindowController` window level
5. **Text Not Inserting:** Verify Accessibility permission granted

---

## Privacy & Security Notes

- **On-device processing:** All transcription runs locally via WhisperKit
- **No network calls:** Audio never leaves the device
- **Clipboard access:** Only writes when user triggers dictation
- **Accessibility API:** Only reads focused element type, never content

## When asked to create .dmg:
Use create-dmg installed via Home Brew to create a DMG

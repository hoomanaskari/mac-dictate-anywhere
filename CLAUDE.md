# CLAUDE.md - AI Assistant Guide for Dictate Anywhere

## Project Overview

**Dictate Anywhere** is a native macOS application that enables voice dictation anywhere using FluidAudio's Parakeet speech-to-text model. Users press and hold the Fn key (or custom keyboard shortcut) to record audio, get real-time transcription, and automatically insert text into any focused input field.

**Key Features:**

- Global Fn key monitoring for hands-free dictation activation
- Custom keyboard shortcut support (with modifier key combinations)
- Real-time audio transcription using FluidAudio Parakeet (on-device, no cloud)
- 25 European languages supported with auto-detection
- Hands-free mode (tap to start, tap or pause speaking to stop)
- Auto-stop when user stops speaking (end-of-utterance detection)
- Live transcript display with audio waveform visualization
- Automatic text insertion via clipboard + keyboard simulation
- Filler word removal (um, uh, etc.)
- Sound effects for dictation start/stop
- Microphone device selection with low volume warning
- Floating overlay window showing transcription status
- Menu bar integration for background operation
- Launch at login support

**Platform Requirements:**

- macOS 13+ (SwiftUI features)
- Swift 5.9+ (@Observable macro)
- Microphone and Accessibility permissions required

---

## Directory Structure

```
/Dictate Anywhere/
├── App/
│   └── AppDelegate.swift              # Menu bar setup, window management
├── Models/
│   └── SupportedLanguage.swift        # 25 European languages enum
├── Services/                          # Core business logic
│   ├── AudioLevelMonitor.swift        # Real-time audio level calculation (RMS)
│   ├── ClipboardManager.swift         # Clipboard operations
│   ├── FluidModelManager.swift        # FluidAudio Parakeet model download/lifecycle
│   ├── FluidTranscriptionService.swift # FluidAudio streaming transcription
│   ├── KeyboardMonitorService.swift   # Global Fn key + custom shortcut detection
│   ├── MicrophoneManager.swift        # Device enumeration & selection
│   ├── PermissionChecker.swift        # Microphone & Accessibility permissions
│   ├── SettingsManager.swift          # App settings persistence (singleton)
│   └── TextInsertionService.swift     # Text pasting into focused inputs
├── ViewModels/
│   └── DictationViewModel.swift       # Main app state & orchestration
├── Views/
│   ├── AppTheme.swift                 # Color and styling constants
│   ├── DictationView.swift            # Main dictation UI
│   ├── GlassBackground.swift          # Visual effect utilities
│   ├── GlassButtonStyles.swift        # Custom button styles
│   ├── LanguagePickerView.swift       # Language selection sheet
│   ├── ModelDownloadView.swift        # Download progress screen
│   ├── ModelsView.swift               # Model management screen
│   ├── PermissionsView.swift          # Permission request UI
│   ├── SettingsView.swift             # Settings screen
│   ├── ShortcutRecorderView.swift     # Custom keyboard shortcut recorder
│   └── OverlayWindow/
│       ├── AudioWaveformView.swift       # Animated waveform (24 bars)
│       ├── OverlayContentView.swift      # Overlay UI states (auto-scrolling)
│       └── OverlayWindowController.swift # Floating window management
├── Assets.xcassets/
├── ContentView.swift                  # Root view with state routing
├── Dictate_AnywhereApp.swift          # App entry point (@main)
└── Dictate_Anywhere.entitlements      # App entitlements
```

---

## Core Technologies

| Technology              | Purpose                                   |
| ----------------------- | ----------------------------------------- |
| **FluidAudio**          | Parakeet speech-to-text model for macOS   |
| **SwiftUI**             | Declarative UI framework                  |
| **AppKit**              | Window management, menu bar, clipboard    |
| **CoreAudio**           | Audio device enumeration                  |
| **AVFoundation**        | Audio capture and format conversion       |
| **Accelerate**          | SIMD for audio RMS calculations           |
| **ApplicationServices** | Accessibility API for keyboard events     |
| **CoreGraphics**        | Keyboard event simulation (Cmd+V)         |
| **ServiceManagement**   | Launch at login support (SMAppService)    |

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
    case modelManagement    // Model settings screen
    case settings           // Settings screen
    case error(String)
}
```

**State Flow:**

```
loading → checkingPermissions → permissionsMissing (if needed)
                             → downloadingModel → initializingModel → ready
ready ⟷ listening → processing → ready
ready ⟷ modelManagement
ready ⟷ settings
```

### Service Architecture

Each service handles a single responsibility:

| Service                      | Responsibility                          | Key Methods                                            |
| ---------------------------- | --------------------------------------- | ------------------------------------------------------ |
| `FluidTranscriptionService`  | FluidAudio streaming transcription      | `startRecording()`, `stopRecording()`, `forceCancel()` |
| `FluidModelManager`          | Parakeet model download/lifecycle       | `downloadAndLoadModels()`, `deleteModelFiles()`        |
| `KeyboardMonitorService`     | Global Fn key + custom shortcut monitor | `startMonitoring()`, `stopMonitoring()`                |
| `MicrophoneManager`          | Audio device enumeration                | `refreshDevices()`, `selectMicrophone()`               |
| `PermissionChecker`          | Permission checks/requests              | `checkPermissionsAsync()`, `requestMicrophonePermission()` |
| `AudioLevelMonitor`          | Real-time RMS calculation               | `startMonitoring()`, `stopMonitoring()`                |
| `SettingsManager`            | App settings (singleton)                | Properties with auto-persist to UserDefaults           |
| `TextInsertionService`       | Clipboard + keyboard simulation         | `insertText()`                                         |
| `OverlayWindowController`    | Floating overlay window                 | `show()`, `hide()`, `updateAudioLevel()`               |

### Observable Pattern

All services and the ViewModel use Swift 5.9's `@Observable` macro for reactive state:

```swift
@Observable
final class DictationViewModel {
    var state: AppState = .loading
    var currentTranscript: String = ""
    // ...
}
```

### Settings Manager

Centralized settings management via `SettingsManager.shared`:

```swift
@Observable
final class SettingsManager {
    static let shared = SettingsManager()

    var isFnKeyEnabled: Bool              // Fn key trigger
    var isCustomShortcutEnabled: Bool     // Custom shortcut trigger
    var customShortcutKeyCode: UInt16?    // Key code
    var customShortcutModifiers: NSEvent.ModifierFlags
    var isHandsFreeEnabled: Bool          // Tap-to-toggle mode
    var isAutoStopEnabled: Bool           // End-of-utterance auto-stop
    var selectedLanguage: SupportedLanguage
    var soundEffectsEnabled: Bool
    var soundEffectsVolume: Float
    var isFillerWordRemovalEnabled: Bool
    var fillerWordsToRemove: [String]
    var showTextPreview: Bool
    var launchAtLogin: Bool
    var appAppearanceMode: AppAppearanceMode
}
```

---

## Key Workflows

### Dictation Flow

```
1. Fn Key Press / Shortcut Press / Button Click
   └── DictationViewModel.startDictation()
       ├── Acquire operation lock (DictationOperationManager actor)
       ├── State → .listening
       ├── Show overlay (loading)
       ├── Start watchdog timer (30s timeout)
       ├── Configure EOU callback if auto-stop enabled
       └── FluidTranscriptionService.startRecording()
           ├── Setup AVAudioEngine with format conversion
           ├── Start audio capture at 16kHz
           └── Begin transcription loop (500ms intervals)

2. During Recording
   ├── AudioLevelMonitor calculates RMS (30 FPS)
   ├── FluidTranscriptionService updates currentTranscript
   ├── Overlay shows waveform + live text
   ├── Low volume warning if system mic volume < 25%
   └── EOU detection monitors for speech pauses (0.8s threshold)

3. Fn Key Release / Shortcut Release / Auto-Stop
   └── DictationViewModel.stopDictation()
       ├── State → .processing
       ├── Stop watchdog timer
       ├── Show processing overlay
       ├── Get final transcript
       ├── Apply filler word removal if enabled
       ├── TextInsertionService.insertText()
       │   ├── Copy to clipboard
       │   └── Simulate Cmd+V
       ├── Show success/copiedOnly overlay
       └── State → .ready

4. Hands-Free Mode
   ├── First press starts dictation
   ├── Second press OR EOU detection stops dictation
   └── Escape key cancels without pasting
```

### Model Management Flow

```
1. App startup checks for FluidAudio Parakeet model
2. If not downloaded:
   └── FluidModelManager.downloadAndLoadModels()
       ├── Download Parakeet v3 model (~600MB)
       ├── Simulate progress (FluidAudio doesn't expose progress)
       └── Cache in ~/Library/Application Support/FluidAudio/Models/
3. Initialize FluidTranscriptionService with loaded models
4. One-time cleanup of old WhisperKit models (migration)
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
private actor DictationOperationManager {
    enum OperationState { case idle, starting, active, stopping }
    private var state: OperationState = .idle

    func tryStart() -> UInt64? {
        guard state == .idle else { return nil }
        state = .starting
        operationID += 1
        return operationID
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
    await self?.handleEndOfUtterance()
}
```

### Background Queues

Use dedicated dispatch queues for blocking operations:

```swift
private let fileQueue = DispatchQueue(label: "com.dictate-anywhere.model-files", qos: .userInitiated)
private let soundQueue = DispatchQueue(label: "com.dictate-anywhere.sounds", qos: .userInteractive)
```

---

## Supported Languages

FluidAudio Parakeet v3 supports 25 European languages:

| Category    | Languages                                                    |
| ----------- | ------------------------------------------------------------ |
| Germanic    | English, German, Dutch, Swedish, Danish, Norwegian           |
| Romance     | Spanish, French, Italian, Portuguese, Romanian               |
| Slavic      | Polish, Czech, Slovak, Slovenian, Croatian, Bulgarian, Ukrainian, Russian |
| Baltic      | Latvian, Lithuanian, Estonian                                |
| Other       | Hungarian, Finnish, Greek                                    |

Languages are defined in `SupportedLanguage.swift` with display names, native names, and flag emojis.

---

## Overlay States

The floating overlay (`OverlayWindowController`) supports these states:

| State                | Description                           | Size       |
| -------------------- | ------------------------------------- | ---------- |
| `.loading`           | Spinner while initializing microphone | 180x60     |
| `.listening`         | Waveform + live transcript            | 320x140 or 200x60 |
| `.listeningLowVolume`| Warning when mic volume too low       | 200x60     |
| `.processing`        | Brief processing indicator            | 180x60     |
| `.success`           | Checkmark before hiding               | 180x60     |
| `.copiedOnly`        | Text copied but auto-paste failed     | 220x60     |

---

## Permission Requirements

### Microphone Access

- Checked via `AVCaptureDevice.authorizationStatus(for: .audio)`
- Required for audio capture

### Accessibility Permission

- Checked via `AXIsProcessTrusted()`
- Required for:
  - Global Fn key monitoring when app is not focused
  - Custom keyboard shortcut monitoring
  - Detecting focused UI element type
  - Simulating Cmd+V keypress via CGEvent

---

## Important Implementation Details

### Thread Safety

- Dictation operation state uses Swift `actor` (`DictationOperationManager`) for atomic state transitions
- Recording state uses Swift `actor` (`RecordingStateManager`) in transcription service
- Audio buffer access uses Swift `actor` (`AudioBufferActor`)
- UI updates dispatched to `@MainActor`
- Swift 6 concurrency compatible

### Resource Management

- Background tasks store `Task` references for cleanup in `deinit`
- Event monitors removed in `deinit`
- Audio engine stopped and reset after each session
- Watchdog timer (30s) prevents stuck dictation sessions

### Audio Processing

- Audio captured at device sample rate, converted to 16kHz mono Float32 for FluidAudio
- RMS calculated with exponential smoothing (factor 0.3)
- Audio level updates at 30 FPS (~33ms intervals)
- Transcription updates every 500ms during recording
- Waveform visualization uses 24 animated bars with edge fading
- Minimum audio energy threshold (0.005 RMS) prevents hallucinations on silence
- End-of-utterance detection: 0.8s silence threshold

### Window Behavior

- Main window is `.floating` level (stays above other apps)
- Overlay is non-interactive (clicks pass through)
- Overlay visible on all Spaces, stays on top of fullscreen apps
- App appearance mode: menu bar only (accessory) or dock + menu bar (regular)

### Text Insertion

- Checks focused element role via Accessibility API
- Only pastes if a text input is focused
- Shows "copiedOnly" state if no text input detected
- Falls back to clipboard-only with user hint

### Filler Word Removal

- Uses regex with word boundaries for accurate matching
- Cleans up resulting double spaces and punctuation spacing
- Configurable word list via settings

---

## Build Commands

This is an Xcode project. Build using:

- **Xcode:** Open `Dictate Anywhere.xcodeproj` and build (Cmd+B)
- **Command line:** `xcodebuild -project "Dictate Anywhere.xcodeproj" -scheme "Dictate Anywhere" build`

---

## Common Tasks for AI Assistants

### Adding a New Service

1. Create new file in `Services/` directory
2. Use `@Observable final class` pattern
3. Add MARK comments for organization
4. Use `[weak self]` in all closures
5. Use dedicated dispatch queues for blocking operations
6. Add cleanup in `deinit` if needed
7. Wire up in `DictationViewModel`

### Adding a New View

1. Create new file in `Views/` directory
2. Use SwiftUI with `@Bindable` for ViewModel access
3. Use `#Preview` for Xcode canvas
4. Apply `.appBackground()` and `.containerBackground()` modifiers
5. Add routing case in `ContentView` if needed

### Adding a New App State

1. Add case to `AppState` enum in `DictationViewModel`
2. Handle in `ContentView` switch statement
3. Add transitions in ViewModel methods

### Adding a New Setting

1. Add property to `SettingsManager` with `didSet` persisting to UserDefaults
2. Add corresponding key in `Keys` enum
3. Initialize from UserDefaults in `init()`
4. Add UI in `SettingsView`

### Modifying Transcription Behavior

- Edit `FluidTranscriptionService.swift`
- Key methods: `startRecording()`, `transcriptionLoop()`, `performFinalTranscription()`
- Audio format configured in `setupAndStartAudioEngine()`
- EOU detection in `checkEndOfUtterance()`

### Changing Keyboard Shortcuts

- Edit `KeyboardMonitorService.swift`
- Fn key: monitors `NX_DEVICELCTLFNKEY` flag
- Custom shortcuts: monitors keyCode + modifierFlags from `SettingsManager`

---

## Debugging Tips

1. **Permission Issues:** Check System Settings → Privacy & Security
2. **Model Not Loading:** Check FluidAudio cache at `~/Library/Application Support/FluidAudio/Models/`
3. **No Audio:** Verify microphone selection in `MicrophoneManager`, check system input volume
4. **Overlay Not Showing:** Check `OverlayWindowController` window level and collection behavior
5. **Text Not Inserting:** Verify Accessibility permission, check if text input is focused
6. **Stuck in Listening:** Watchdog should recover after 30s; check console for errors
7. **Custom Shortcut Not Working:** Verify shortcut recorded in `SettingsManager`, check for conflicts

---

## Privacy & Security Notes

- **On-device processing:** All transcription runs locally via FluidAudio Parakeet
- **No network calls:** Audio never leaves the device (except initial model download)
- **Clipboard access:** Only writes when user triggers dictation
- **Accessibility API:** Only reads focused element type, never content
- **Analytics:** Optional, anonymous, infrastructure-only (no audio/text)

---

## When asked to create .dmg

Use create-dmg installed via Homebrew to create a DMG:

```bash
create-dmg \
  --volname "Dictate Anywhere" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "Dictate Anywhere.app" 150 185 \
  --app-drop-link 450 185 \
  "Dictate Anywhere.dmg" \
  "path/to/Dictate Anywhere.app"
```

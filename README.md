# Dictate Anywhere

A native macOS app for voice dictation anywhere. Press and hold Fn (or a custom shortcut) to dictate text directly into any app using on-device speech recognition.

[![macOS](https://img.shields.io/badge/macOS-14.0+-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

<!-- Add a screenshot or demo GIF here -->
<!-- ![Dictate Anywhere Demo](screenshots/demo.gif) -->
<!-- Screenshots -->
<table>
  <tr>
    <img width="300" alt="Screenshot 2026-02-21 at 23 47 42" src="https://github.com/user-attachments/assets/f23182cb-3af3-48da-804f-2a91fbe1f731" />
<img width="300" alt="Screenshot 2026-02-21 at 23 47 51" src="https://github.com/user-attachments/assets/b28898dc-88b3-4b31-ab3c-35e6f49fb74d" />
  </tr>
</table>
<table>
  <tr>
<img width="300" alt="Screenshot 2026-02-21 at 23 47 56" src="https://github.com/user-attachments/assets/c30d9349-cfcf-46a2-8a2a-f1b8b834cc17" />
<img width="300" alt="Screenshot 2026-02-21 at 23 48 01" src="https://github.com/user-attachments/assets/a05fe872-08b1-49d5-ad00-8a75997f45da" />
  </tr>
</table>

## Features

- **Global Hotkey** - Press and hold Fn key (or custom shortcut) to dictate from anywhere
- **On-Device Processing** - All speech recognition runs locally using FluidAudio Parakeet - your audio never leaves your Mac
- **25 Languages** - Support for English, German, French, Spanish, and 21 more European languages
- **Hands-Free Mode** - Tap to start, tap again to stop
- **Live Preview** - See your transcription in real-time with animated waveform
- **Filler Word Removal** - Automatically removes "um", "uh", and other filler words
- **Menu Bar App** - Runs quietly in your menu bar

## Installation

### Download

1. Download the latest `Dictate.Anywhere.dmg` from [Releases](../../releases)
2. Open the DMG and drag **Dictate Anywhere** to your Applications folder
3. Launch the app and grant the required permissions

### Required Permissions

- **Microphone** - For capturing your voice
- **Accessibility** - For detecting the Fn key globally and inserting text

## Supported Languages

| Germanic | Romance | Slavic | Other |
|----------|---------|--------|-------|
| English | Spanish | Polish | Hungarian |
| German | French | Czech | Finnish |
| Dutch | Italian | Slovak | Greek |
| Swedish | Portuguese | Slovenian | Latvian |
| Danish | Romanian | Croatian | Lithuanian |
| Norwegian | | Bulgarian | Estonian |
| | | Ukrainian | |
| | | Russian | |

## Building from Source

### Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later
- [create-dmg](https://github.com/create-dmg/create-dmg) (optional, for creating DMG)

### Build

```bash
# Clone the repository
git clone https://github.com/hoomanaskari/mac-dictate-anywhere.git
cd mac-dictate-anywhere

# Open in Xcode
open "Dictate Anywhere.xcodeproj"

# Or build from command line
xcodebuild -project "Dictate Anywhere.xcodeproj" -scheme "Dictate Anywhere" -configuration Release build
```

### Create DMG (optional)

```bash
create-dmg \
  --volname "Dictate Anywhere" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "Dictate Anywhere.app" 150 185 \
  --app-drop-link 450 185 \
  "dist/Dictate Anywhere.dmg" \
  "dist"
```

## How It Works

1. **Activation** - Press and hold Fn key (or your custom shortcut)
2. **Recording** - Speak naturally while the key is held
3. **Processing** - Release the key to process your speech
4. **Insertion** - Text is automatically inserted at your cursor position

The app uses FluidAudio's Parakeet model for speech recognition, which runs entirely on your Mac. The model is downloaded once (~600MB) and cached locally.

## Privacy

- **100% On-Device** - All speech processing happens locally on your Mac
- **No Cloud Services** - Your audio is never uploaded anywhere
- **No Analytics** - No tracking or telemetry (optional anonymous usage stats only)
- **Clipboard Only** - Text insertion uses the clipboard + Cmd+V simulation

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [FluidAudio](https://github.com/FluidInference/FluidAudio) - For the excellent Parakeet speech-to-text model
- [create-dmg](https://github.com/create-dmg/create-dmg) - For the DMG creation tool

# Dictate Anywhere

A native macOS app for voice dictation anywhere. Press and hold Fn (or a custom shortcut) to dictate text directly into any app using on-device speech recognition, with optional transcript cleanup through Apple Intelligence, Ollama, or OpenRouter.

[![macOS](https://img.shields.io/badge/macOS-14.0+-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

<!-- Add a screenshot or demo GIF here -->
<!-- ![Dictate Anywhere Demo](screenshots/demo.gif) -->
<!-- Screenshots -->
<table>
  <tr>
    <img width="400" alt="Screenshot 2026-02-21 at 23 47 42" src="https://github.com/user-attachments/assets/f23182cb-3af3-48da-804f-2a91fbe1f731" />
<img width="400" alt="Screenshot 2026-02-21 at 23 47 51" src="https://github.com/user-attachments/assets/b28898dc-88b3-4b31-ab3c-35e6f49fb74d" />
  </tr>
</table>
<table>
  <tr>
<img width="400" alt="Screenshot 2026-02-21 at 23 47 56" src="https://github.com/user-attachments/assets/c30d9349-cfcf-46a2-8a2a-f1b8b834cc17" />
<img width="400" alt="Screenshot 2026-02-21 at 23 48 01" src="https://github.com/user-attachments/assets/a05fe872-08b1-49d5-ad00-8a75997f45da" />
  </tr>
</table>

## Features

- **Global Hotkey** - Press and hold Fn key (or custom shortcut) to dictate from anywhere
- **On-Device Processing** - All speech recognition runs locally using FluidAudio Parakeet - your audio never leaves your Mac
- **25 Languages** - Support for English, German, French, Spanish, and 21 more European languages
- **Hands-Free Mode** - Tap to start, tap again to stop
- **Live Preview** - See your transcription in real-time with animated waveform
- **Filler Word Removal** - Automatically removes "um", "uh", and other filler words
- **Custom Vocabulary** - Preserve product names, people names, and domain-specific terms during transcript cleanup
- **Ollama Integration** - Connect to a local or remote Ollama server, refresh installed models, and manage recommended local models from the app
- **OpenRouter Integration** - Use hosted models through OpenRouter with model search, structured-output-aware selection, and secure API key storage
- **Optional Transcript Cleanup** - Post-process the final transcript with Apple Intelligence, Ollama, or OpenRouter for punctuation, grammar, formatting, and wording cleanup
- **Safe Fallbacks** - If AI cleanup fails or returns unusable output, the original local transcript is pasted instead
- **Menu Bar App** - Runs quietly in your menu bar

## Installation

### Download

1. Download the latest notarized `.dmg` from [Releases](../../releases)
2. Open the DMG and drag **Dictate Anywhere** to your Applications folder
3. Launch the app and grant the required permissions

### Required Permissions

- **Microphone** - For capturing your voice
- **Accessibility** - For detecting the Fn key globally and inserting text

## Optional AI Transcript Cleanup

Dictate Anywhere always transcribes audio locally with Parakeet. AI cleanup happens only after transcription, on the final text transcript. That means your raw audio stays on your Mac even when you enable Ollama or OpenRouter.

| Provider | Runs Where | Best For | Benefits |
|----------|------------|----------|----------|
| None | Nowhere | Fastest raw dictation | Uses the Parakeet transcript as-is |
| FluidAudio Vocabulary | On-device | Lightweight terminology correction | Applies vocabulary rescoring without an LLM |
| Apple Intelligence | On-device | Native macOS cleanup | On-device cleanup on supported Macs |
| Ollama | Local or self-hosted server | Privacy-first LLM cleanup | Local model choice, optional reasoning controls, and in-app model management for local Ollama setups |
| OpenRouter | Cloud | Broad hosted model access | Large model catalog, model search, secure key storage, and structured-output-aware selection |

### Ollama

Use Ollama when you want transcript cleanup with a local model or your own hosted Ollama server.

Recommended models:

- `gpt-oss:120b-cloud` for the best cleanup quality when you have access to a large hosted/self-hosted Ollama-backed model
- `mistral-nemo:12b` as the recommended local model when you want a much lighter on-device setup

- Runs cleanup against the configured Ollama server URL, with `http://127.0.0.1:11434` as the default local address
- Lets you enter any installed model manually or select from detected installed models
- Shows recommended models in the app, including size guidance and quality/latency tradeoffs
- Can download recommended models directly from the app when the Ollama CLI is installed and the server is local
- Can delete installed models from the app through the Ollama CLI
- Exposes reasoning controls for models that report Ollama thinking support
- Supports provider-specific cleanup prompts and shared custom vocabulary

Sample cleanup prompt for Ollama or OpenRouter:

```text
Avoid em dashes entirely.

If the speaker corrects themselves or revises what they said, preserve the final intended meaning. Replace only the portion that is clearly superseded, and leave the rest unchanged.

Add paragraph breaks and bullet points when the dictation clearly calls for structure. Otherwise, keep it as regular prose.

Convert spoken numbers to numerals when that improves clarity, while preserving intended units and symbols. Example: "thirteen point five percent" -> "13.5%".

Remove only accidental duplicate words or obvious speech-recognition repetitions. Keep intentional repetition when it appears to be deliberate.

Preserve the speaker's tone, meaning, and intent.

Treat custom vocabulary as a strong hint, not a hard rule. Use it when it clearly fits the surrounding context. If it does not, prefer the wording that best matches the sentence.
```

Benefits of using Ollama:

- Keeps transcript cleanup local when you run Ollama on your Mac
- Gives you more control over model choice, privacy, and latency than a fixed hosted provider
- Works with remote/self-hosted Ollama servers if you already have one running elsewhere
- Improves punctuation, grammar, formatting, and vocabulary normalization with stronger local models
- Custom vocabulary gives noticeably better results for names, product terms, and specialized wording when Ollama is doing post-processing

Getting started with Ollama:

1. Install [Ollama](https://ollama.com/download), or point the app at an existing Ollama server.
2. In Dictate Anywhere, open **Transcript Processing** and choose **Ollama**.
3. Confirm the server URL, then either enter a model name manually or use **Refresh Models**.
4. If you are using local Ollama with the CLI installed, download one of the suggested models directly from the app.
5. Optionally add a cleanup prompt and custom vocabulary for names, product terms, and domain-specific language.

### OpenRouter

Use OpenRouter when you want access to hosted models without managing local model downloads.

Recommended model:

- `google/gemini-3-flash-preview` for the best overall balance of cost, accuracy, and latency in Dictate Anywhere

- Supports direct OpenRouter API usage for transcript cleanup after local transcription is complete
- Lets you paste an API key into the app for secure Keychain storage
- Can also read the API key from an environment variable such as `OPENROUTER_API_KEY`
- Fetches the latest OpenRouter model catalog in-app
- Includes model search and prioritizes models that advertise structured output support
- Falls back to prompt-based JSON parsing automatically when a selected model does not support structured outputs cleanly
- Supports provider-specific cleanup prompts and shared custom vocabulary

Benefits of using OpenRouter:

- `google/gemini-3-flash-preview` currently gives the best overall results in this app when you care about cost, accuracy, and latency together
- Pairing OpenRouter with a custom cleanup prompt usually produces the best transcript quality
- Custom vocabulary gives the strongest results for names, product terms, and specialized wording when OpenRouter is doing post-processing
- Fastest way to try higher-end hosted models without running them locally
- One integration gives you access to a large cross-provider model catalog
- Model search makes it easier to find a suitable cleanup model from inside the app
- Keychain-backed API key storage keeps the common setup path simple

Getting started with OpenRouter:

1. Create an API key from [OpenRouter](https://openrouter.ai/).
2. In Dictate Anywhere, open **Transcript Processing** and choose **OpenRouter**.
3. Paste your API key, or leave the API key field empty if you launch the app with `OPENROUTER_API_KEY` set.
4. Enter a model ID manually, click **Refresh Models**, or use **Browse Models** to explore the catalog.
5. Add a custom cleanup prompt and custom vocabulary for the best results, especially for names, brands, and specialized terminology.

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
4. **Optional Cleanup** - The final transcript can be cleaned up with Apple Intelligence, Ollama, or OpenRouter
5. **Insertion** - Text is automatically inserted at your cursor position

The app uses FluidAudio's Parakeet model for speech recognition, which runs entirely on your Mac. The model is downloaded once (~600MB) and cached locally.

## Privacy

- **100% On-Device Speech Recognition** - All audio transcription happens locally on your Mac
- **Ollama Can Stay Fully Local** - If you use a local Ollama server, transcript cleanup can stay on your machine; if you use a remote Ollama server, only transcript text is sent there
- **Optional Cloud Transcript Cleanup** - Audio never leaves your Mac, but transcript text can be sent to OpenRouter if you enable hosted post-processing
- **Secure OpenRouter Key Storage** - API keys pasted into the app are stored in Keychain
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
- [Ollama](https://ollama.com/) - For enabling optional local LLM-based transcript cleanup
- [create-dmg](https://github.com/create-dmg/create-dmg) - For the DMG creation tool

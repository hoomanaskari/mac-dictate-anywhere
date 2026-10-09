# Dictate Anywhere

A native macOS app for voice dictation anywhere. Press and hold Fn (or a custom shortcut) to dictate text directly into any app using on-device speech recognition, with optional transcript cleanup through S1-mini by Superwhisper, Apple Intelligence, Ollama, or OpenRouter.

<p align="center">
  <a href="https://github.com/hoomanaskari/mac-dictate-anywhere/releases/latest">
    <img src="https://img.shields.io/badge/Download_for_Mac-DMG-black?style=for-the-badge&logo=apple&logoColor=white" alt="Download for Mac" />
  </a>
</p>

[![macOS](https://img.shields.io/badge/macOS-14.0+-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

<table>
  <tr>
    <td><img width="400" alt="Dictate Anywhere speech model settings" src="screenshots/speech-model.png" /></td>
    <td><img width="400" alt="Dictate Anywhere general settings" src="screenshots/general.png" /></td>
  </tr>
  <tr>
    <td><img width="400" alt="Dictate Anywhere text and overlay settings" src="screenshots/text-and-overlay.png" /></td>
    <td><img width="400" alt="Dictate Anywhere transcript cleanup settings" src="screenshots/transcript-cleanup.png" /></td>
  </tr>
</table>

## Features

- **Global Hotkey** - Press and hold Fn key (or custom shortcut) to dictate from anywhere
- **Safer Cancellation** - Rebind or clear the cancel shortcut in Shortcuts. Optional one-second hold-to-cancel is enabled by default; a quick Escape tap keeps dictation running.
- **Continue Cancelled Sessions** - Cancelled dictations are saved locally for 24 hours by default. Continue in History restores your words using the selected speech model and language, then restarts the microphone. Stop to insert one combined dictation into the original app, or copy it if that app is unavailable. Recover text saves words to History without recording or pasting.
- **Local-First Speech Recognition** - FluidAudio and Apple Speech run on-device; AssemblyAI is available as an explicit cloud option
- **Language-aware Model Choices** - Choose by language, download size, accuracy or live preview. Parakeet v3/Ultra cover 25 European languages including Maltese; SenseVoice offers Mandarin with English, and multilingual Nemotron adds Norwegian on Apple Silicon.
- **Hands-Free Mode** - Tap to start, tap again to stop
- **Live Preview** - See your transcription with an animated waveform. Batch Parakeet previews target one-second updates, then two-second updates after eight seconds of audio; initial text can appear earlier. Native streaming models keep their own cadence, and Stop uses the authoritative final decode.
- **Filler Word Removal** - Automatically removes "um", "uh", and other filler words
- **Custom Vocabulary** - Preserve product names, people names, and domain-specific terms during transcript cleanup
- **Context Awareness** - Detect the active app or supported website, read a bounded snapshot around the cursor, and apply separate styles for email, work chat, personal chat, and other apps
- **S1-mini by Superwhisper** - Download or delete a compact English transcript normalizer and run it fully on-device without a separate model server
- **Ollama Integration** - Connect to a local or remote Ollama server and choose an installed cleanup model by its exact ID
- **OpenRouter Integration** - Use hosted models through OpenRouter with model search, structured-output-aware selection, and secure API key storage
- **AssemblyAI Dictation** - Optional cloud speech model with transcription, self-correction cleanup, keyterms, context, and output instructions in one request; installed Apple Speech assets provide an on-device live preview while recording
- **Optional Transcript Cleanup** - Post-process the final transcript with S1-mini by Superwhisper, Apple Intelligence, Ollama, or OpenRouter for punctuation, grammar, formatting, and wording cleanup
- **Safe Fallbacks** - If AI cleanup fails or returns unusable output, the original local transcript is pasted instead
- **Menu Bar App** - Runs quietly in your menu bar

Startup preparation resolves the selected speech language and model before loading. Independent speech and cleanup engines prepare together; vocabulary preparation waits for speech weights. Disabling automatic preparation keeps lazy first-use loading available. Remote preparation shares brief metadata/preload results, and explicit Prepare or Refresh actions check current state.

## Installation

### Download

The release app is universal: it runs natively on Apple silicon (M-series) and Intel Macs with macOS 14 or later. Apple silicon uses `arm64`; Intel uses `x86_64`. Rosetta is not required. Models that need the Apple Neural Engine or Apple Intelligence still require supported Apple silicon hardware.

1. Download the latest notarized `.dmg` from [Releases](../../releases)
2. Open the DMG and drag **Dictate Anywhere** to your Applications folder
3. Launch the app and grant the required permissions

### Required Permissions

- **Microphone** - For capturing your voice
- **Accessibility** - For detecting the Fn key globally and inserting text

The app checks access when it starts, when you return to it, and when you dictate or paste. Its single setup banner lets you browse permission, speech-model, and transcript-cleanup issues one at a time. Detailed errors stay beside the setting or action that caused them. Apple Speech's on-device engine does not ask for a separate Speech Recognition permission.

On the first paste, macOS may also ask **Dictate Anywhere** to control **System Events**. Allow this under **System Settings → Privacy & Security → Automation** for the AppleScript paste path. If you decline, the app uses its keyboard-event paste fallback and offers an optional recovery action in the setup banner. Automation permission is separate from Accessibility.

## Optional AI Transcript Cleanup

FluidAudio and Apple Speech transcribe locally. Their raw audio stays on your Mac even when a remote transcript-cleanup provider is enabled. AssemblyAI is a separate cloud speech-model choice: when selected, audio is sent directly to AssemblyAI for the final transcription. When compatible Apple Speech language assets are already installed, the same microphone samples also produce an on-device live preview; that preview is never pasted in place of AssemblyAI's result. Context Awareness keeps surrounding text local by default; sharing it with AssemblyAI or another remote provider requires a separate opt-in.

| Provider | Runs Where | Best For | Benefits |
|----------|------------|----------|----------|
| Off | On-device filler removal if enabled | Raw dictation | Retains the speech result after optional filler removal |
| Vocabulary correction only | On-device | Domain terms without a cleanup LLM | Parakeet TDT rescoring or native Nemotron/Apple Speech vocabulary hints, where available |
| Apple Intelligence | On-device | Native macOS cleanup | On-device cleanup on supported Macs |
| S1-mini by Superwhisper | On-device | Compact English transcript normalization | One-click 462 MB download, fixed style/structure/context controls, and no separate server |
| Ollama | Local or self-hosted server | Privacy-first LLM cleanup | Local model choice, optional reasoning controls, and in-app model management for local Ollama setups |
| OpenRouter | Cloud | Broad hosted model access | Large model catalog, model search, secure key storage, and structured-output-aware selection |

### S1-mini by Superwhisper

[S1-mini by Superwhisper](https://huggingface.co/superwhisper/s1-mini) is a compact model trained specifically to normalize speech-to-text transcripts.

- Downloads a pinned Q4_K_M model directly from Hugging Face and verifies its exact size and SHA-256 before installation
- Runs through the embedded llama.cpp runtime, with Metal acceleration on Apple Silicon and CPU inference on Intel
- Provides the model's trained styling, structure, and context controls instead of an arbitrary prompt
- Splits longer English transcripts into lossless chunks of approximately 1,000 model tokens; unsupported languages or a failed chunk preserve the entire original transcript
- Can be removed from the Transcript Cleanup page, including its locally stored license file

### Ollama

Use Ollama when you want transcript cleanup with a local model or your own hosted Ollama server.

Choose an installed model by its exact **Model ID**. Ollama is the provider;
cleanup quality depends on the model and prompt you configure. This app does
not bundle an Ollama cleanup model.

- Runs cleanup against the configured Ollama server URL, with `http://127.0.0.1:11434` as the default local address
- Lets you enter any installed model manually or select from detected installed models
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

Coverage depends on the selected model and hardware. Norwegian requires
multilingual Nemotron on Apple Silicon; Maltese is available through Parakeet
v3/Ultra. The model chooser shows each checkpoint’s supported languages and
download size.

| Germanic | Romance | Slavic | Other | Sino-Tibetan |
|----------|---------|--------|-------|--------------|
| English | Spanish | Polish | Hungarian | Mandarin Chinese (Simplified) |
| German | French | Czech | Finnish | |
| Dutch | Italian | Slovak | Greek | |
| Swedish | Portuguese | Slovenian | Latvian | |
| Danish | Romanian | Croatian | Lithuanian | |
| Norwegian | | Bulgarian | Estonian | |
| | | Ukrainian | Maltese | |
| | | Russian | | |

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

If you only want to run the app locally, you do not need the release packaging script.

### Stable Local Development Workflow

For local development, use `scripts/dev.sh` with the shared **Dictate Anywhere** scheme. The workflow defaults to the **Debug** configuration, stable DerivedData, and the isolated `Dictate Anywhere Dev.app` so local permissions do not affect Release builds.

For an end-to-end Instruments or unified-log profile, use the [performance tracing map](docs/performance-tracing.md). For repeatable offline measurements, see the [benchmark guide](docs/performance-benchmarking.md).

Create the ignored local signing override when needed:

```bash
scripts/dev.sh signing [TEAM_ID]
```

Automatic signing requires an Xcode account with the matching Apple Developer team and a matching development certificate. Keep `Config/Signing.local.xcconfig` ignored and do not commit it.

Common commands:

```bash
scripts/dev.sh check
scripts/dev.sh build
scripts/dev.sh build --configuration Release
scripts/dev.sh build --release
scripts/dev.sh launch
scripts/dev.sh test
scripts/dev.sh stop
```

Use `--configuration Debug` or `--configuration Release` with `build`. Tests run only with `Debug` because Release is not testable. The default is `Debug`, and `--release` is an alias for `--configuration Release`. Provisioning updates are disabled by default; pass `--allow-provisioning-updates` when you explicitly want Xcode to update signing assets. Release builds use the production signing identity and team. They do not package, notarize, update the appcast, or change production Release settings.

Set the optional `DERIVED_DATA_PATH` environment variable to use another stable path. The default is `$HOME/Library/Developer/Xcode/DerivedData/DictateAnywhereDev`.

Debug commands explicitly select the Mac's native architecture, including when the calling terminal runs under Rosetta. Debug builds contain only that architecture for faster iteration; Release builds use Xcode's standard architectures with `ONLY_ACTIVE_ARCH = NO`. Use a Release artifact when transferring the app between Apple silicon and Intel Macs.

Check a release bundle and all its embedded frameworks and updater helpers before distribution:

```bash
scripts/verify-universal-app.sh "dist/Dictate Anywhere.app"
```

This fails if any Mach-O binary is missing `arm64` or `x86_64`. See [Apple's universal binary guidance](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary) and the [release workflow](RELEASE.md).

If Accessibility permission is stale, remove `Dictate Anywhere Dev.app` from **System Settings → Privacy & Security → Accessibility**, launch it again, and add that exact app.

Release signing remains separate from this local workflow.

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

### Signed Release Packaging

The maintainer release script is intentionally not tracked. Create your own local copy like this:

```bash
cp scripts/release-macos.template.sh scripts/release-macos.sh
chmod +x scripts/release-macos.sh
```

Then edit `scripts/release-macos.sh` and set your own values for:

- `NOTARY_PROFILE`
- `TEAM_ID`
- `DEVELOPER_ID_APP`
- `DOWNLOAD_URL_PREFIX`
- `REPOSITORY_LINK`

Also create `Config/Signing.local.xcconfig` with your own Apple Developer team ID, and update the Xcode signing settings and bundle identifiers if your local release setup needs different values.

When your local signing setup is ready, package the release with:

```bash
./scripts/release-macos.sh
```

## How It Works

1. **Activation** - Press and hold Fn key, or tap a hands-free shortcut
2. **Recording** - Speak naturally while dictation is active
3. **Processing** - Release the key, tap again, or let Parakeet EOU auto-stop when enabled
4. **Context** - When enabled, a bounded Accessibility snapshot classifies the destination and supplies local recognition hints
5. **Optional Cleanup** - The final transcript can be cleaned up with S1-mini by Superwhisper, Apple Intelligence, Ollama, or OpenRouter
6. **Insertion** - Text is automatically inserted with cursor-aware spacing; the insertion layer never adds terminal punctuation

The app uses FluidAudio speech models that run entirely on your Mac. Parakeet TDT remains the default path, and optional Parakeet EOU or Nemotron streaming models can be downloaded for lower-latency live previews.

Batch models also use an optional speech-detection model for quiet speech and
pause segmentation. Explicit model setup installs it; existing installations can
use **Download Speech Detection** in Speech Model settings. Cached speech models
still prepare offline without it, using volume detection and bounded segments.
Preparation does not download or repair the speech-detection cache.

## Privacy

- **Temporary Recovery Audio** - When Preserve cancelled sessions is enabled, audio is written locally while recording. Completed sessions delete this temporary copy; cancelled sessions expire after 24 hours (or on the next launch if the app is closed). Recovery files are excluded from backups. Continue retains the original until the combined dictation is completed or safely saved, and preserves all restored words if cancelled again. Turning preservation off applies to new dictations; continuing an existing saved session still protects it. Existing copies can be deleted from History.
- **100% On-Device Speech Recognition** - All audio transcription happens locally on your Mac
- **Context Stays Local by Default** - Surrounding text is used by on-device/local processing but is withheld from remote servers unless you explicitly enable remote context sharing
- **S1-mini Stays Fully Local** - After its one-time model download, S1-mini by Superwhisper receives transcript text only in local memory and does not require a model server
- **Ollama Can Stay Fully Local** - If you use a local Ollama server, transcript cleanup and surrounding context can stay on your machine; a remote Ollama server receives the transcript plus category/style, and receives surrounding text only with the separate opt-in
- **Optional Cloud Transcript Cleanup** - Audio never leaves your Mac; transcript text and category/style can be sent to OpenRouter when enabled, while surrounding text remains separately opt-in
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

- [FluidAudio](https://github.com/FluidInference/FluidAudio) - For local Parakeet and Nemotron speech-to-text models
- [S1-mini by Superwhisper](https://huggingface.co/superwhisper/s1-mini) - For compact local English transcript normalization
- [llama.cpp](https://github.com/ggml-org/llama.cpp) and [llama.swift](https://github.com/mattt/llama.swift) - For embedded local S1-mini inference
- [Ollama](https://ollama.com/) - For enabling optional local LLM-based transcript cleanup
- [create-dmg](https://github.com/create-dmg/create-dmg) - For the DMG creation tool

# Dictate Anywhere 2.3.0

- Added FluidAudio true streaming speech models, including Parakeet EOU Streaming and three Nemotron Streaming latency tiers.
- Added end-of-utterance auto-stop for the Parakeet EOU Streaming model in hands-free mode.
- Improved model readiness handling so dictation waits for model downloads and prepares the selected speech model before recording.
- Moved local filler-word removal into Transcript Processing with an editable word list and clearer local, non-AI wording.
- Added clearer Transcript Processing diagnostics when Apple Intelligence, Ollama, OpenRouter, or OpenAI-compatible cleanup falls back to the raw transcript.
- Updated FluidAudio to 0.15.4 for the latest streaming model support.

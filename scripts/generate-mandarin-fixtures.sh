#!/bin/bash
# Generates Mandarin test fixtures with the built-in macOS Chinese TTS voice.
# Deterministic, license-free audio. TTS is "easy mode" for ASR — thresholds in
# MandarinFixtureTests are calibrated for it; complement with a real-voice
# recording when revising the corpus.
set -euo pipefail
cd "$(dirname "$0")/../Dictate AnywhereTests/Fixtures"

VOICE="Tingting"
if ! say -v '?' | grep -q "$VOICE"; then
  echo "Voice $VOICE not installed. Install a Chinese voice in System Settings > Accessibility > Spoken Content." >&2
  exit 1
fi

gen() { # gen <name> <text>
  say -v "$VOICE" -o "$1.aiff" "$2"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$1.aiff" "$1.wav"
  rm "$1.aiff"
}

gen zh-short    "今天天气很好。"
gen zh-question "你明天有时间吗？"
gen zh-numbers  "我们三点半开会，会议大概持续两个小时。"
gen zh-mixed    "我明天要去 Apple Park 开会。"

# zh-long must land in [25s, 30s): MandarinFixtureTests requires >=25s (and
# skips its split/merge test below 22s), but SenseVoice's CoreML preprocessor
# hard-caps a single transcribe(audio:) call at 480,000 samples (30s @ 16kHz)
# — the test's "full" oracle transcription would throw
# "Size (N) of dimension (1) is not in allowed range (3200..480000)" above
# that. Two paragraphs + two lead-in sentences renders to ~28.9s with Tingting.
LONG_PARA="人工智能正在改变我们的生活方式。语音识别技术让我们可以直接对着电脑说话。今天我想谈谈本地语音模型的发展。"
LONG_LEAD="人工智能正在改变我们的生活方式。"
gen zh-long "${LONG_PARA}${LONG_PARA}${LONG_LEAD}${LONG_LEAD}"

echo "Done. Verify each wav is ~16kHz mono and zh-long is in [25s, 30s): afinfo *.wav"

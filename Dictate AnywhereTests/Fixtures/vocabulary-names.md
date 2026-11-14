# Vocabulary correction speech fixture

`vocabulary-names.wav` is a human English recording from
[FLEURS](https://huggingface.co/datasets/google/fleurs), by Google and the FLEURS
contributors, licensed under [CC BY 4.0](LICENSE_CC_BY_4_0.txt).

Source: revision `4683b04`, `en_us` test split, utterance `1669`, archive member
`8173060820032255320.wav` in `data/en_us/audio/test.tar.gz`. The test copy is
16 kHz mono PCM16 (146,240 samples, 9.14 seconds), converted from the source
without trimming or changing its speech content.

Reference from `data/en_us/test.tsv`:

> police superintendent chandra shekhar solanki said the accused appeared in court with covered faces

SHA-256: `509bc6279b6549a1ed01a712950f0593e43380204f77f39a4fdd11bd216c68c0`.

The vocabulary preflight regression uses this recording to prove that an
eligible proper-name correction still runs on both separate and shared CTC
paths, while an unrelated vocabulary leaves the original transcript intact.

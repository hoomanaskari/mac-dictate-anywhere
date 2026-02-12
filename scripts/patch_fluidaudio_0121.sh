#!/bin/zsh
set -euo pipefail

TARGETS=("${(@f)$(find "$HOME/Library/Developer/Xcode/DerivedData" -type f -path "*/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/ASR/Qwen3/Qwen3AsrModels.swift" 2>/dev/null)}")

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No FluidAudio checkout found under DerivedData."
  echo "Run package resolution first, then rerun this patch script."
  exit 1
fi

PATCHED_COUNT=0

for TARGET in "${TARGETS[@]}"; do
  TARGET_FILE="$TARGET" python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["TARGET_FILE"])
source = path.read_text()

if "float32FromFloat16BitPattern" in source and "Float16(bitPattern: bitPattern)" in source:
    print(f"already patched: {path}")
    raise SystemExit(0)

old_block = """        data.withUnsafeBytes { ptr in
            let f16Ptr = ptr.baseAddress!.advanced(by: offset)
                .assumingMemoryBound(to: Float16.self)

            for i in 0..<hiddenSize {
                result[i] = Float(f16Ptr[i])
            }
        }

        return result
    }

    /// Get embeddings for multiple token IDs.
"""

new_block = """        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let baseAddress = ptr.baseAddress else { return }
            let u16Ptr = baseAddress.advanced(by: offset)
                .assumingMemoryBound(to: UInt16.self)

            for i in 0..<hiddenSize {
                let bitPattern = UInt16(littleEndian: u16Ptr[i])
                #if arch(x86_64)
                result[i] = float32FromFloat16BitPattern(bitPattern)
                #else
                result[i] = Float(Float16(bitPattern: bitPattern))
                #endif
            }
        }

        return result
    }

    @inline(__always)
    private func float32FromFloat16BitPattern(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32((bits & 0x7C00) >> 10)
        let fraction = UInt32(bits & 0x03FF)

        let outputBits: UInt32
        if exponent == 0 {
            if fraction == 0 {
                outputBits = sign
            } else {
                var frac = fraction
                var exp = Int32(-14)
                while (frac & 0x0400) == 0 {
                    frac <<= 1
                    exp -= 1
                }
                frac &= 0x03FF
                let exp32 = UInt32(exp + 127)
                outputBits = sign | (exp32 << 23) | (frac << 13)
            }
        } else if exponent == 0x1F {
            outputBits = sign | 0x7F80_0000 | (fraction << 13)
        } else {
            let exp32 = exponent + UInt32(127 - 15)
            outputBits = sign | (exp32 << 23) | (fraction << 13)
        }

        return Float(bitPattern: outputBits)
    }

    /// Get embeddings for multiple token IDs.
"""

if old_block not in source:
    print(f"expected block not found: {path}")
    raise SystemExit(2)

path.chmod(0o644)
path.write_text(source.replace(old_block, new_block, 1))
print(f"patched: {path}")
PY
  PATCHED_COUNT=$((PATCHED_COUNT + 1))
done

echo "Patched FluidAudio 0.12.1 Qwen3 file in ${PATCHED_COUNT} checkout(s)."

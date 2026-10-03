"""P2-M5V9-B.3D.2B/C — shared, dependency-free (stdlib only) helpers for
the FRIDAY voice-v2 dataset tooling: WAV signal analysis, checksums, and
manifest/provenance loading.

Deliberately stdlib-only (`wave`, `struct`, `hashlib`, `json`, `pathlib`)
— no numpy/scipy dependency, since these tools must run outside the
Chatterbox venv against a private, real dataset that has nothing to do
with the ML stack.

This module performs ONLY objective signal statistics (peak/RMS/DC
offset/clipping/silence) — never speaker recognition, voice biometrics,
identity embeddings, or gender/age/emotion inference of any kind. That
is a permanent, explicit boundary for this whole tool family (see
docs/voice-v2/FRIDAY-V2-DATASET-PLAN.md §Dataset QC tool design).
"""
from __future__ import annotations

import hashlib
import json
import math
import struct
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

DELIVERY_MODES = {"neutral", "friendly", "professional", "focused", "serious", "lightPlayful", "explanatory"}

# A sample at or above this normalized magnitude is counted as clipped —
# real full-scale is 1.0 (16-bit) / 1.0 (24-bit, normalized); a small
# margin below exact 1.0 catches quantization-adjacent clipping too.
CLIPPING_THRESHOLD = 0.999
# -50 dBFS ~= 0.00316 normalized amplitude — a conventional silence floor.
SILENCE_AMPLITUDE_THRESHOLD = 10 ** (-50 / 20)


class WAVContainerError(ValueError):
    """The file could not be parsed as a well-formed WAV at all."""


@dataclass
class WAVStats:
    channels: int
    sample_rate: int
    bit_depth: int
    frame_count: int
    duration_ms: float
    peak_dbfs: float  # -inf represented as float('-inf') for pure silence
    rms_dbfs: float
    dc_offset: float
    clipped_sample_count: int
    silence_ratio: float
    leading_silence_ms: float
    trailing_silence_ms: float
    checksum_sha256: str


def _decode_pcm_samples(raw: bytes, sampwidth: int) -> list[float]:
    """Decodes raw PCM bytes to normalized floats in [-1, 1]. Supports
    16-bit and 32-bit signed integer PCM directly via `struct`, and
    24-bit signed integer PCM via manual little-endian byte assembly
    (there is no native `struct` primitive for a 3-byte integer)."""
    if sampwidth == 2:
        count = len(raw) // 2
        ints = struct.unpack(f"<{count}h", raw[: count * 2])
        return [v / 32768.0 for v in ints]
    if sampwidth == 3:
        samples = []
        for i in range(0, len(raw) - 2, 3):
            b0, b1, b2 = raw[i], raw[i + 1], raw[i + 2]
            val = b0 | (b1 << 8) | (b2 << 16)
            if val & 0x800000:
                val -= 0x1000000
            samples.append(val / 8388608.0)
        return samples
    if sampwidth == 4:
        count = len(raw) // 4
        ints = struct.unpack(f"<{count}i", raw[: count * 4])
        return [v / 2147483648.0 for v in ints]
    raise WAVContainerError(f"unsupported PCM sample width: {sampwidth} bytes (only 16/24/32-bit PCM supported)")


def sha256_of_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def analyze_wav(path: Path) -> WAVStats:
    """Parses and analyzes a WAV file. Raises WAVContainerError for any
    file that isn't a well-formed, PCM WAV — a real master recording is
    expected to be exactly that; a file that fails this parse is a
    genuine defect for archival/ingestion purposes, not an edge case to
    be tolerated (unlike the deliberately permissive streaming-WAV
    parser built for third-party provider responses elsewhere in this
    project — a FRIDAY master is never a streaming response)."""
    try:
        with wave.open(str(path), "rb") as w:
            channels = w.getnchannels()
            sample_rate = w.getframerate()
            sampwidth = w.getsampwidth()
            nframes = w.getnframes()
            comptype = w.getcomptype()
            if comptype != "NONE":
                raise WAVContainerError(f"non-PCM compression type: {comptype}")
            raw = w.readframes(nframes)
    except wave.Error as e:
        raise WAVContainerError(str(e)) from e
    except EOFError as e:
        raise WAVContainerError(f"truncated/corrupt WAV: {e}") from e

    bit_depth = sampwidth * 8
    if nframes == 0 or len(raw) == 0:
        return WAVStats(
            channels=channels, sample_rate=sample_rate, bit_depth=bit_depth, frame_count=0,
            duration_ms=0.0, peak_dbfs=float("-inf"), rms_dbfs=float("-inf"), dc_offset=0.0,
            clipped_sample_count=0, silence_ratio=1.0, leading_silence_ms=0.0, trailing_silence_ms=0.0,
            checksum_sha256=sha256_of_file(path),
        )

    samples = _decode_pcm_samples(raw, sampwidth)
    n = len(samples)
    peak = max(abs(s) for s in samples)
    mean = sum(samples) / n
    mean_sq = sum(s * s for s in samples) / n
    rms = math.sqrt(mean_sq)
    clipped = sum(1 for s in samples if abs(s) >= CLIPPING_THRESHOLD)
    silent_count = sum(1 for s in samples if abs(s) < SILENCE_AMPLITUDE_THRESHOLD)
    silence_ratio = silent_count / n

    leading = 0
    for s in samples:
        if abs(s) >= SILENCE_AMPLITUDE_THRESHOLD:
            break
        leading += 1
    trailing = 0
    for s in reversed(samples):
        if abs(s) >= SILENCE_AMPLITUDE_THRESHOLD:
            break
        trailing += 1

    frames_total = n // max(channels, 1)
    duration_ms = (frames_total / sample_rate) * 1000.0 if sample_rate > 0 else 0.0
    leading_ms = (leading / max(channels, 1) / sample_rate) * 1000.0 if sample_rate > 0 else 0.0
    trailing_ms = (trailing / max(channels, 1) / sample_rate) * 1000.0 if sample_rate > 0 else 0.0

    def to_dbfs(x: float) -> float:
        return 20 * math.log10(x) if x > 0 else float("-inf")

    return WAVStats(
        channels=channels, sample_rate=sample_rate, bit_depth=bit_depth, frame_count=frames_total,
        duration_ms=duration_ms, peak_dbfs=to_dbfs(peak), rms_dbfs=to_dbfs(rms), dc_offset=mean,
        clipped_sample_count=clipped, silence_ratio=silence_ratio,
        leading_silence_ms=leading_ms, trailing_silence_ms=trailing_ms,
        checksum_sha256=sha256_of_file(path),
    )


def load_json(path: Path) -> dict:
    return json.loads(Path(path).read_text())


def find_duplicate_asset_ids(manifest: dict) -> list[str]:
    seen = set()
    dupes = []
    for asset in manifest.get("assets", []):
        aid = asset.get("asset_id")
        if aid in seen and aid not in dupes:
            dupes.append(aid)
        seen.add(aid)
    return dupes


def load_provenance_records(provenance_dir: Optional[Path]) -> Optional[dict[str, dict]]:
    """Loads every *.json provenance record found in `provenance_dir`,
    keyed by `rights_record_id`. Returns `None` (not `{}`) if
    `provenance_dir` itself is None or doesn't exist — callers MUST
    distinguish that ("verification was never requested/possible") from
    a real, explicitly-supplied directory that legitimately contains
    zero records (an empty `{}`, meaning "verification WAS attempted and
    every reference failed to resolve"). Conflating the two would let an
    explicitly-requested-but-misconfigured provenance check silently
    downgrade to an unverified WARN instead of a REJECT."""
    if provenance_dir is None:
        return None
    provenance_dir = Path(provenance_dir)
    if not provenance_dir.is_dir():
        return None
    records: dict[str, dict] = {}
    for f in provenance_dir.glob("*.json"):
        try:
            record = load_json(f)
        except (json.JSONDecodeError, OSError):
            continue
        rights_id = record.get("rights_record_id")
        if rights_id:
            records[rights_id] = record
    return records

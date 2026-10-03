"""Synthetic, non-human WAV fixture generators for voice-v2 tool tests.

Every fixture here is a generated sine tone / silence / noise-free
synthetic signal — NEVER a human voice recording, per this milestone's
explicit "never ship a human voice fixture" rule.
"""
from __future__ import annotations

import math
import struct
import wave
from pathlib import Path


def write_sine_wav(path: Path, seconds: float = 2.0, freq: float = 440.0, sample_rate: int = 48000,
                    bit_depth: int = 24, channels: int = 1, amplitude: float = 0.5, dc_offset: float = 0.0) -> None:
    """A clean sine tone — the "valid master" synthetic stand-in."""
    n = int(seconds * sample_rate)
    max_val = (1 << (bit_depth - 1)) - 1
    samples = []
    for i in range(n):
        v = amplitude * math.sin(2 * math.pi * freq * i / sample_rate) + dc_offset
        v = max(-1.0, min(1.0, v))
        int_val = int(v * max_val)
        for _ in range(channels):
            samples.append(int_val)
    _write_pcm(path, samples, sample_rate, bit_depth, channels)


def write_clipped_wav(path: Path, seconds: float = 1.0, sample_rate: int = 48000, bit_depth: int = 24, channels: int = 1) -> None:
    """A square-ish wave that saturates at full scale — deliberately clipped."""
    n = int(seconds * sample_rate)
    max_val = (1 << (bit_depth - 1)) - 1
    samples = []
    for i in range(n):
        int_val = max_val if (i // 50) % 2 == 0 else -max_val
        for _ in range(channels):
            samples.append(int_val)
    _write_pcm(path, samples, sample_rate, bit_depth, channels)


def write_silence_wav(path: Path, seconds: float = 3.0, sample_rate: int = 48000, bit_depth: int = 24, channels: int = 1) -> None:
    n = int(seconds * sample_rate) * channels
    _write_pcm(path, [0] * n, sample_rate, bit_depth, channels)


def write_empty_wav(path: Path, sample_rate: int = 48000, bit_depth: int = 24, channels: int = 1) -> None:
    _write_pcm(path, [], sample_rate, bit_depth, channels)


def write_truncated_wav(path: Path, seconds: float = 1.0, sample_rate: int = 48000, bit_depth: int = 24, channels: int = 1) -> None:
    """Writes a well-formed WAV then chops bytes off the end, so the
    declared header size no longer matches the actual file length."""
    write_sine_wav(path, seconds=seconds, sample_rate=sample_rate, bit_depth=bit_depth, channels=channels)
    data = path.read_bytes()
    path.write_bytes(data[: len(data) // 2])


def write_not_a_wav(path: Path) -> None:
    path.write_bytes(b"this is not a wav file at all, just plain bytes")


def _write_pcm(path: Path, samples: list[int], sample_rate: int, bit_depth: int, channels: int) -> None:
    sampwidth = bit_depth // 8
    with wave.open(str(path), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(sampwidth)
        w.setframerate(sample_rate)
        if sampwidth == 2:
            w.writeframes(struct.pack(f"<{len(samples)}h", *samples))
        elif sampwidth == 3:
            raw = bytearray()
            for v in samples:
                if v < 0:
                    v += 1 << 24
                raw += bytes([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF])
            w.writeframes(bytes(raw))
        elif sampwidth == 4:
            w.writeframes(struct.pack(f"<{len(samples)}i", *samples))
        else:
            raise ValueError(f"unsupported bit depth for fixture writer: {bit_depth}")

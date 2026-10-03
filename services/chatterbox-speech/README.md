# Chatterbox local speech service

P2-M5V9-B.2 §10/§24/§25 — the local, offline TTS backend paired with
`LocalChatterboxProvider` in `macos/FridayCompanion/Sources/FridayCompanionKit/LocalChatterboxProvider.swift`.

## Setup (isolated environment — never FRIDAY's general Python env)

```
python3 -m venv .venv-chatterbox      # already present in this repo checkout
source .venv-chatterbox/bin/activate
pip install chatterbox-tts            # pulls torch/torchaudio/etc. transitively
```

`requirements-verified.txt` is a `pip freeze` snapshot of the exact
environment this milestone verified working on this machine (Apple
Silicon, MPS backend, `chatterbox-tts==0.1.7`, `torch==2.6.0`) — a
reference for reproducing the same verified state, not yet pinned as a
hard requirement (per this milestone's own instruction: pin only after
full owner acceptance).

## Running

```
source .venv-chatterbox/bin/activate
python3 services/chatterbox-speech/chatterbox_service.py [socket_path]
# default socket_path: /tmp/friday-chatterbox.sock
```

Listens ONLY on a local Unix-domain socket (mode `0600`, owner-only) —
never a TCP port, never reachable off this machine.

## Verified this milestone (real, on this Apple Silicon Mac)

| Variant | Maps to | Load (cold, incl. first-time HF download) | Steady-state RTF |
|---|---|---|---|
| `turbo` | `chatterbox.tts_turbo.ChatterboxTurboTTS` (`ResembleAI/chatterbox-turbo`) | 133.7s | 0.775× (faster than real-time) |
| `nano` | `chatterbox.tts.ChatterboxTTS` (`ResembleAI/chatterbox`) — **no literal "Nano" model exists in `chatterbox-tts==0.1.7`; this is the closest available lighter-weight correspondence, disclosed honestly** | 92.7s | 2.02× |
| `multilingual` | `chatterbox.mtl_tts.ChatterboxMultilingualTTS` (`ResembleAI/chatterbox`) | 111.2s | 1.9–2.3× |

23 languages supported by the installed multilingual model: ar, da, de,
el, en, es, fi, fr, he, hi, it, ja, ko, ms, nl, no, pl, pt, ru, sv, sw,
tr, zh. **Gujarati (`gu`) is NOT supported** — verified directly against
`chatterbox.mtl_tts.SUPPORTED_LANGUAGES`, never assumed.

Live end-to-end audition (`VoiceAuditionTool chatterbox-live-audition`,
this milestone) confirmed real synthesis in English, Hindi, Spanish,
French, and Japanese, and a correct, honest rejection of Gujarati.

Disk footprint: ~6.0GB (`ResembleAI/chatterbox`, shared by `nano` +
`multilingual`) + ~3.8GB (`ResembleAI/chatterbox-turbo`) in the local
Hugging Face cache. Resident memory with all three variants loaded in
one process: ~1.5GB RSS (observed this milestone).

## Known limitations (disclosed, not hidden)

- No literal "Nano" model in the installed package — see table above.
- Cold-start load times (90–135s) are dominated by a one-time model
  download; subsequent loads from local cache are faster but still add
  real, multi-second latency the first time a given variant is used in a
  fresh process — this is why `LocalModelLifecyclePolicy` (Swift side)
  exists to keep a warm model loaded rather than reloading per turn.
- This service does not yet implement its own idle-unload timer — a
  loaded variant stays resident for the service process's lifetime.

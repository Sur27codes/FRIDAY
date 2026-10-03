#!/usr/bin/env python3
"""
P2-M5V9-B.2 §10/§25 — the local Chatterbox speech service, paired with
FRIDAY's Swift-side `LocalChatterboxProvider`/`POSIXUnixSocketIPCTransport`
(macos/FridayCompanion/Sources/FridayCompanionKit/LocalChatterboxProvider.swift).

Runs entirely inside the repository's own, isolated
`.venv-chatterbox` environment (§25: "do not install Chatterbox Python
packages into FRIDAY's general Python environment... use a dedicated
local runtime"). Listens ONLY on a local Unix-domain socket (§10: "never
expose the local TTS service publicly") — never binds a TCP port.

Wire protocol (symmetric on request and response, matching the Swift
transport's own framing exactly):
    4 bytes: big-endian uint32 length of the JSON body that follows
    N bytes: UTF-8 JSON

Request:  {"text": str, "language": str, "variant": "turbo"|"base-english"|"multilingual",
           "audio_prompt_path": str | null}
          ("nano" accepted as a backward-compatible alias for "base-english")
          (P2-M5V9-B.3D.2D — "audio_prompt_path" is OPTIONAL and additive;
          omitting it (or a request from before this field existed)
          reproduces the exact prior no-reference-conditioning behavior
          byte-for-byte. When present, it is passed straight to the
          installed package's own `generate(..., audio_prompt_path=...)` —
          this service does NOT resolve/validate the caller's rights to
          use that file; that gate lives entirely in the calling
          developer harness (`friday-v2-local-conditioning`), which must
          refuse to send a reference that hasn't cleared QC/provenance/
          rights checks. The path itself and any transcript text are
          NEVER logged by this service, matching existing practice.)
Response: {"status": "ok", "sampleRate": int, "audioBase64": str, "timing": {...}}
       or {"status": "error", "error": str, "timing": {...}}

Models are loaded LAZILY, one per variant, on first use (§15: "implement
lazy loading... do not load all TTS backends simultaneously"). This
service does not itself implement the idle-unload timer described in
`LocalModelLifecyclePolicy` (Swift-side, event-driven) — that policy
decision belongs to the caller; this V1 service keeps a loaded model warm
for its own process lifetime once first used. A future pass may add an
inactivity-triggered unload here without changing the wire protocol.

P2-M5V9-B.3A — added sanitized per-request timing instrumentation
(requestReceived/modelLookupStart/modelAlreadyLoaded/modelLoadStart/
modelLoadComplete/generationStart/generationComplete/audioEncodeStart/
audioEncodeComplete/responseSendStart, all epoch-ms, comparable directly
against the Swift client's own wall-clock timestamps on the same
machine), plus `residentVariants` and `serverRssKb` (current process RSS,
read via `ps` — no new dependency) so a warm-vs-cold, same-model-vs-
switching benchmark can attribute latency precisely instead of guessing.
NEVER includes request/response TEXT content in this instrumentation —
only timing numbers and variant/language labels, which are not private
speech content.

Run:
    source .venv-chatterbox/bin/activate
    python3 services/chatterbox-speech/chatterbox_service.py [socket_path]
"""
import base64
import json
import os
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
import traceback

DEFAULT_SOCKET_PATH = "/tmp/friday-chatterbox.sock"

_model_lock = threading.Lock()
_models = {}  # variant -> loaded model instance


def _device():
    import torch
    return "mps" if torch.backends.mps.is_available() else "cpu"


def _current_rss_kb() -> int:
    """Current (not merely peak) resident set size for THIS process, in
    KB — via `ps`, so no new Python dependency (psutil is NOT installed
    and this milestone must not install unrelated packages)."""
    try:
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(os.getpid())])
        return int(out.strip())
    except Exception:
        return -1


def _now_ms() -> float:
    return time.time() * 1000.0


def _load_model(variant: str, timing: dict):
    """Lazily loads and caches exactly one model per variant. §11: 'the
    supported-language registry must come from the actual installed
    Chatterbox implementation/config' — never hand-invented here.
    Records load-related timing checkpoints into `timing` (P2-M5V9-B.3A)."""
    with _model_lock:
        timing["modelAlreadyLoaded"] = variant in _models
        if variant in _models:
            return _models[variant]
        timing["modelLoadStartMs"] = _now_ms()
        if variant == "turbo":
            import chatterbox.tts_turbo as tts_turbo
            model = tts_turbo.ChatterboxTurboTTS.from_pretrained(device=_device())
        elif variant == "base-english":
            # P2-M5V9-B.3B §6 — RENAMED from the old, misleading "nano"
            # slot name. §6/§11 of P2-M5V9-B.2/B.3A's own honest
            # disclosure, reaffirmed here: the installed chatterbox-tts
            # package has NO literal "Nano" checkpoint at all — this is
            # simply the BASE English model (repo ResembleAI/chatterbox,
            # chatterbox.tts.ChatterboxTTS). Never call this "Nano"
            # anywhere — "actual Nano" remains UNAVAILABLE/UNVERIFIED.
            import chatterbox.tts as tts
            model = tts.ChatterboxTTS.from_pretrained(device=_device())
        elif variant == "multilingual":
            import chatterbox.mtl_tts as mtl_tts
            model = mtl_tts.ChatterboxMultilingualTTS.from_pretrained(device=_device())
        else:
            raise ValueError(f"unknown variant: {variant}")
        timing["modelLoadCompleteMs"] = _now_ms()
        _models[variant] = model
        return model


def _supported_languages(variant: str):
    if variant != "multilingual":
        return {"en"}
    import chatterbox.mtl_tts as mtl_tts
    return set(mtl_tts.SUPPORTED_LANGUAGES.keys())


# P2-M5V9-B.3A §12 — exact package/model class/checkpoint identifiers,
# recorded once (not per-request — never changes) and reported in every
# response's timing block for direct, unambiguous attribution.
#
# P2-M5V9-B.3B §6 — the old "nano" key is RENAMED to "base-english" (an
# honest label — this is the base model, not a distinct Nano checkpoint).
# "nano" is still accepted on the WIRE as a backward-compatible alias
# (§_VARIANT_ALIASES below), normalized to "base-english" immediately.
_MODEL_IDENTITY = {
    "turbo": {"pythonClass": "chatterbox.tts_turbo.ChatterboxTurboTTS", "checkpointRepo": "ResembleAI/chatterbox-turbo"},
    "base-english": {"pythonClass": "chatterbox.tts.ChatterboxTTS", "checkpointRepo": "ResembleAI/chatterbox", "note": "NOT a distinct Nano checkpoint — the base model. Genuine Nano is UNAVAILABLE/UNVERIFIED in the installed package (§6/§11)."},
    "multilingual": {"pythonClass": "chatterbox.mtl_tts.ChatterboxMultilingualTTS", "checkpointRepo": "ResembleAI/chatterbox"},
}
_VARIANT_ALIASES = {"nano": "base-english"}  # backward-compat only — never the canonical name


def _synthesize(text: str, language: str, variant: str, audio_prompt_path: str = None) -> dict:
    variant = _VARIANT_ALIASES.get(variant, variant)
    timing = {"requestReceivedMs": _now_ms(), "rssBeforeKb": _current_rss_kb()}
    if variant not in ("turbo", "base-english", "multilingual"):
        return {"status": "error", "error": f"unsupported variant: {variant}", "timing": timing}
    supported = _supported_languages(variant)
    if language not in supported:
        # §11: "do not invent support for unsupported languages" —
        # rejected honestly, never silently defaulted to English.
        return {"status": "error", "error": f"language '{language}' not supported by variant '{variant}' (supported: {sorted(supported)})", "timing": timing}
    # P2-M5V9-B.3D.2D — fail closed on a missing reference file rather
    # than silently falling back to unconditioned generation. The path
    # itself is never included in the error (or anywhere else) — only
    # its presence/absence is reported.
    if audio_prompt_path is not None and not os.path.isfile(audio_prompt_path):
        return {"status": "error", "error": "audio_prompt_path not found", "timing": timing}
    try:
        timing["modelLookupStartMs"] = _now_ms()
        model = _load_model(variant, timing)
        timing["generationStartMs"] = _now_ms()
        timing["audioPromptUsed"] = audio_prompt_path is not None
        # The installed package's own `generate(...)` enforces whatever
        # reference-duration/format requirements it has (e.g. Turbo's own
        # `assert len(wav)/sr > 5.0`) — any such failure is caught by the
        # existing `except Exception` below and returned as a normal wire
        # error, exactly like any other generation failure.
        if variant == "multilingual":
            if audio_prompt_path:
                wav = model.generate(text, language_id=language, audio_prompt_path=audio_prompt_path)
            else:
                wav = model.generate(text, language_id=language)
        else:
            if audio_prompt_path:
                wav = model.generate(text, audio_prompt_path=audio_prompt_path)
            else:
                wav = model.generate(text)
        timing["generationCompleteMs"] = _now_ms()
        timing["audioEncodeStartMs"] = _now_ms()
        # torch float32 tensor, shape [1, N] or [N] -> raw little-endian
        # float32 PCM bytes, matching `LocalChatterboxProvider`'s declared
        # "pcm_f32le" capability.
        samples = wav.squeeze().detach().cpu().numpy()
        audio_bytes = samples.astype("<f4").tobytes()
        audio_seconds = len(samples) / float(model.sr)
        b64 = base64.b64encode(audio_bytes).decode("ascii")
        timing["audioEncodeCompleteMs"] = _now_ms()
        timing["audioDurationSec"] = audio_seconds
        timing["modelClass"] = _MODEL_IDENTITY[variant]["pythonClass"]
        timing["checkpointRepo"] = _MODEL_IDENTITY[variant]["checkpointRepo"]
        timing["residentVariants"] = sorted(_models.keys())
        timing["rssAfterKb"] = _current_rss_kb()
        timing["responseSendStartMs"] = _now_ms()
        # Note (P2-M5V9-B.3A): there is no "responseSendCompleteMs" here
        # by construction — a server cannot report the completion of its
        # own send INSIDE the payload it is still transmitting. The
        # Swift client's own `fullResponseReceived` timestamp is the
        # honest, correct end-to-end substitute for that checkpoint.
        return {"status": "ok", "sampleRate": int(model.sr), "audioBase64": b64, "timing": timing}
    except Exception as e:  # noqa: BLE001 — a synthesis failure must return a WIRE error, never crash the service
        traceback.print_exc()
        timing["rssAfterKb"] = _current_rss_kb()
        return {"status": "error", "error": f"{type(e).__name__}: {e}", "timing": timing}


def _recv_exact(conn: socket.socket, count: int) -> bytes:
    chunks = []
    remaining = count
    while remaining > 0:
        chunk = conn.recv(remaining)
        if not chunk:
            raise ConnectionError("peer closed before sending the expected number of bytes")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            (length,) = struct.unpack(">I", _recv_exact(self.request, 4))
            body = _recv_exact(self.request, length)
            req = json.loads(body.decode("utf-8"))
            # NEVER logged/printed — request text is read only to pass to
            # the model, never written to stdout/stderr/disk by this
            # service (P2-M5V9-B.3A §5: "never log private speech content").
            response = _synthesize(req.get("text", ""), req.get("language", "en"), req.get("variant", "base-english"), req.get("audio_prompt_path"))
        except Exception as e:  # noqa: BLE001 — malformed request must still get a wire-shaped error reply
            response = {"status": "error", "error": f"malformed request: {e}"}
        payload = json.dumps(response).encode("utf-8")
        self.request.sendall(struct.pack(">I", len(payload)) + payload)


class ThreadedUnixStreamServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    socket_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SOCKET_PATH
    if os.path.exists(socket_path):
        os.remove(socket_path)
    server = ThreadedUnixStreamServer(socket_path, Handler)
    os.chmod(socket_path, 0o600)  # §10: local, single-owner access only
    print(f"chatterbox-speech: listening on {socket_path} (device={_device()}) baselineRssKb={_current_rss_kb()}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        if os.path.exists(socket_path):
            os.remove(socket_path)


if __name__ == "__main__":
    main()

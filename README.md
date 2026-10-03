# FRIDAY

A multi-process AI runtime for macOS with local authority over an LLM, process supervision, and a real-time voice pipeline.

**Status:** in active development, not yet released.

## How it's put together

A native Swift companion app supervises three Go helper processes over typed IPC. The companion never gives the language model direct control of the machine — the model proposes, and a local runtime decides what's actually true and what's actually allowed.

```mermaid
graph TD
    User((User))
    Companion["FridayCompanion<br/>(Swift, menu-bar app)"]
    Supervisor["Supervisor<br/>(process lifecycle, health, recovery)"]
    Policy["policyengined<br/>(Go)"]
    Bus["capabilitybusd<br/>(Go)"]
    Daemon["friday-daemon<br/>(Go, runtime + intent)"]

    User --> Companion
    Companion --> Supervisor
    Supervisor -->|typed IPC| Policy
    Supervisor -->|typed IPC| Bus
    Supervisor -->|typed IPC| Daemon
    Bus <--> Daemon
    Policy <--> Bus
```

## Voice and conversation path

```mermaid
graph LR
    Wake["Local wake word<br/>(sherpa-onnx)"]
    STT["Speech-to-text"]
    Local["Local classification +<br/>authoritative facts"]
    Model["One external<br/>model call"]
    Recompute["Local recomputation"]
    Validate["ResponseValidation"]
    TTS1["Cartesia"]
    TTS2["Local Chatterbox"]
    TTS3["macOS voice"]
    Out((Spoken response))

    Wake --> STT --> Local --> Model --> Recompute --> Validate
    Validate --> TTS1 -->|on failure, before playback| TTS2
    TTS2 -->|on failure, before playback| TTS3
    TTS1 --> Out
    TTS2 --> Out
    TTS3 --> Out
    Out -.->|barge-in: wake word stops playback| Wake
```

## Tech stack

- Swift (companion app, macOS 13+)
- Go (`policyengined`, `capabilitybusd`, `friday-daemon`)
- Python (local Chatterbox TTS service, voice-dataset tooling)
- sherpa-onnx (local wake-word detection)
- Cartesia, local Chatterbox, and the macOS system voice as a three-tier TTS fallback

## Getting started

```bash
# Go helpers
cd services/policy-engine && go build ./...
cd services/capability-bus && go build ./...
cd services/runtime && go build ./...

# Vendored wake-word engine + model weights (not committed — fetched on demand)
./scripts/fetch_models.sh

# macOS companion app
cd macos/FridayCompanion
swift build --product FridayCompanion
```

Provider credentials are read from macOS Keychain only — there is no `.env` file. On first launch, grant microphone and speech-recognition permissions when macOS prompts for them.

## Security & privacy

- Provider credentials live in Keychain only, never in source, config, or logs
- Unknown or unidentified processes are never terminated — process ownership fails closed
- The app does not treat its own synthesized speech as a user command
- Active listening windows are time-bounded, not always-on
- The language model has no direct, unrestricted control over the machine

See [SECURITY.md](SECURITY.md) to report a vulnerability.

## License

No license file is included yet, so all rights are reserved by default — this will be revisited.

## Author

**Sur Vaghasiya**
[LinkedIn](https://www.linkedin.com/in/sur-vaghasiya-031ab9283) · [Portfolio](https://sur-portfolio.vercel.app/) · [GitHub](https://github.com/Sur27codes)

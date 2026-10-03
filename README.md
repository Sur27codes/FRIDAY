<div align="center">

![wave header](https://capsule-render.vercel.app/api?type=waving&color=0:0ea5e9,100:6366f1&height=160&section=header&text=FRIDAY&fontSize=60&fontColor=ffffff&animation=fadeIn&fontAlignY=38)

[![Typing animation](https://readme-typing-svg.demolab.com/?font=Fira+Code&weight=500&size=22&duration=3000&pause=1200&color=0EA5E9&center=true&vCenter=true&width=600&lines=Hey+Friday...;a+macOS+AI+runtime%2C+not+a+chatbot;local+authority+over+an+LLM;Swift+%2B+Go%2C+talking+over+typed+IPC)](https://github.com/Sur27codes/FRIDAY)

![Swift](https://img.shields.io/badge/Swift-macOS%2013+-F05138?logo=swift&logoColor=white)
![Go](https://img.shields.io/badge/Go-1.26-00ADD8?logo=go&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.11-3776AB?logo=python&logoColor=white)
![Status](https://img.shields.io/badge/status-in%20active%20development-orange)
![License](https://img.shields.io/badge/license-all%20rights%20reserved%20(for%20now)-lightgrey)

</div>

---

FRIDAY is a voice-driven AI runtime that lives on my Mac as a menu-bar companion. Say "Hey Friday," ask it something, and it answers out loud — but the part I actually care about is everything standing between your voice and that answer.

The language model never touches the machine directly. It proposes an answer; a local runtime decides whether that answer is actually true and whether any action it implies is actually allowed. If the model can't know something — your battery level, whether an email really sent — it doesn't get to guess. A Swift companion app supervises the Go processes that do that deciding, and if any of them die, it knows the difference between "safe to restart" and "something I shouldn't touch."

That's the whole project, really: an LLM that's allowed to talk, and a system underneath it that doesn't blindly believe what it says.

## How it's put together

<div align="center">

```mermaid
graph TD
    User((🎙️ You))
    Companion["FridayCompanion<br/>Swift · menu-bar app"]
    Supervisor["Supervisor<br/>lifecycle · health · recovery"]
    Policy["policyengined"]
    Bus["capabilitybusd"]
    Daemon["friday-daemon<br/>runtime + intent"]

    User --> Companion
    Companion --> Supervisor
    Supervisor -.->|typed IPC| Policy
    Supervisor -.->|typed IPC| Bus
    Supervisor -.->|typed IPC| Daemon
    Bus <--> Daemon
    Policy <--> Bus

    classDef swift fill:#F05138,stroke:#b53a26,color:#fff
    classDef go fill:#00ADD8,stroke:#007d9c,color:#fff
    classDef user fill:#6366f1,stroke:#4338ca,color:#fff
    class Companion,Supervisor swift
    class Policy,Bus,Daemon go
    class User user
```

</div>

Three independent Go daemons, one Swift process watching all of them. `policyengined` decides what's allowed, `capabilitybusd` routes capability calls, `friday-daemon` holds the actual runtime and intent logic. None of them talk to each other except through typed IPC the Supervisor can observe.

## The voice path

<div align="center">

```mermaid
graph LR
    Wake["🔈 Wake word<br/>sherpa-onnx, on-device"]
    STT["Speech → text"]
    Local["Local classification<br/>+ authoritative facts"]
    Model["🧠 One model call"]
    Recompute["Local recomputation"]
    Validate["ResponseValidation"]
    TTS1["Cartesia"]
    TTS2["Chatterbox<br/>local"]
    TTS3["macOS voice"]
    Out((🔊 Spoken answer))

    Wake --> STT --> Local --> Model --> Recompute --> Validate
    Validate --> TTS1
    TTS1 -.->|fails before playback| TTS2
    TTS2 -.->|fails before playback| TTS3
    TTS1 --> Out
    TTS2 --> Out
    TTS3 --> Out
    Out -.->|say the wake word again to barge in| Wake

    classDef stage fill:#1e293b,stroke:#0ea5e9,color:#fff
    classDef voice fill:#6366f1,stroke:#4338ca,color:#fff
    classDef io fill:#0ea5e9,stroke:#0369a1,color:#fff
    class Wake,STT,Local,Model,Recompute,Validate stage
    class TTS1,TTS2,TTS3 voice
    class Out io
```

</div>

Only one call ever goes out to the model per turn. Everything before it is local; everything after it is a local system double-checking the model's answer before anything gets spoken out loud. If the primary voice fails mid-sentence, the fallback picks up the *next* sentence — it never replays what you already heard.

## Built with

<div align="center">

<img src="https://skillicons.dev/icons?i=swift,go,python&theme=dark" />

</div>

- **Swift** — the companion app, menu bar UI, process supervisor
- **Go** — `policyengined`, `capabilitybusd`, `friday-daemon`
- **Python** — the local Chatterbox TTS service
- **sherpa-onnx** — fully on-device wake-word detection
- **Cartesia → Chatterbox → macOS voice** — a three-tier fallback so a network hiccup never means silence

## Getting started

```bash
# the Go helpers
cd services/policy-engine   && go build ./...
cd services/capability-bus  && go build ./...
cd services/runtime         && go build ./...

# wake-word engine + model weights (not committed — fetched on demand)
./scripts/fetch_models.sh

# the macOS companion
cd macos/FridayCompanion
swift build --product FridayCompanion
```

Provider credentials live in macOS Keychain — there's no `.env` file to fill in. On first launch, macOS will ask for microphone and speech-recognition permission; it needs both.

## Security & privacy

- Credentials: Keychain only, never in source, config, or logs
- An unidentified process never gets killed — ownership checks fail closed, not open
- FRIDAY doesn't transcribe its own voice as a new command
- Listening windows are time-bounded — the mic isn't open by default
- The model proposes; it never gets direct, unrestricted control of the machine

Found a real issue? See [SECURITY.md](SECURITY.md).

## License

No license file yet, so all rights are reserved for now — revisiting this later.

---

<div align="center">

**Sur Vaghasiya**

[![LinkedIn](https://img.shields.io/badge/LinkedIn-0A66C2?logo=linkedin&logoColor=white)](https://www.linkedin.com/in/sur-vaghasiya-031ab9283)
[![Portfolio](https://img.shields.io/badge/Portfolio-000000?logo=vercel&logoColor=white)](https://sur-portfolio.vercel.app/)
[![GitHub](https://img.shields.io/badge/GitHub-181717?logo=github&logoColor=white)](https://github.com/Sur27codes)

![wave footer](https://capsule-render.vercel.app/api?type=waving&color=0:6366f1,100:0ea5e9&height=100&section=footer)

</div>

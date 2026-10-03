# Third-party dependency hygiene — sherpa-onnx (P2-M3C / ADR-007)

Per the P2-M3C authorization §28: "Code license and model license are NOT
interchangeable." This file records both separately, plus the ONNX Runtime
dependency sherpa-onnx itself pulls in.

## 1. sherpa-onnx (code + inference engine)

| Field | Value |
|---|---|
| Name | sherpa-onnx |
| Version | v1.13.6 (git tag) |
| Source | https://github.com/k2-fsa/sherpa-onnx |
| What is vendored | Prebuilt macOS arm64 shared-library release artifact `sherpa-onnx-v1.13.6-osx-arm64-shared-lib.tar.bz2`, downloaded directly from the project's GitHub Releases page (no build from source — this environment has no `cmake`) |
| Files vendored here | `lib/libsherpa-onnx-c-api.dylib`, `lib/libonnxruntime.dylib` (the bundled `libsherpa-onnx-cxx-api.dylib` was NOT vendored — only the C API is used) |
| C API header | `sherpa-onnx/c-api/c-api.h` fetched from the same `v1.13.6` git tag's raw source, so the header exactly matches the ABI of the vendored dylib — copied into `Sources/CSherpaOnnx/include/sherpa-onnx/c-api/c-api.h` |
| CODE license | Apache License 2.0 (confirmed via the project's GitHub repository license badge and `LICENSE` file at the time of this evaluation) |
| Runtime credential required | **No.** No account, API key, or AccessKey of any kind is needed anywhere in the sherpa-onnx toolkit — this was a first-class selection criterion (P2-M3C §4) and a key differentiator from Porcupine (see `docs/W-adr-backlog.md` ADR-007 for the full comparison). |
| Redistribution implications (code) | Apache-2.0 permits redistribution, including in a commercial product, subject to the standard Apache-2.0 notice/attribution requirements (retain copyright/license notices; state changes if modified). No field-of-use or commercial restriction in the code license itself. |

## 2. ONNX Runtime (transitive dependency, vendored dylib)

| Field | Value |
|---|---|
| Name | ONNX Runtime |
| Source | Bundled inside the same `sherpa-onnx-v1.13.6-osx-arm64-shared-lib.tar.bz2` release artifact as `libonnxruntime.dylib` — not downloaded separately |
| CODE license | MIT License — confirmed directly from `https://github.com/microsoft/onnxruntime/blob/main/LICENSE` ("MIT License", copyright Microsoft Corporation) during this P2-M3C pass, not assumed from memory. |
| Runtime credential required | No |
| Redistribution implications | MIT is broadly redistribution-permissive, including for commercial use, subject to retaining the copyright/license notice. |

## 3. sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01 (KWS model weights)

**This is the dependency where code license and model license genuinely
diverge — read this section before assuming Apache-2.0 covers everything.**

| Field | Value |
|---|---|
| Name | sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01 |
| Version / date | 2024-01-01 (per the model's own directory/release name) |
| Source | `https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2` |
| Files vendored (int8-quantized, used at runtime) | `encoder.int8.onnx` (4.6MB), `decoder.int8.onnx` (272KB), `joiner.int8.onnx` (160KB), `tokens.txt` (8KB) — total ~5.0MB, under `Sources/FridayCompanionKit/Resources/sherpa-onnx-kws-model/` |
| Files kept for provenance only (not shipped/loaded at runtime) | `model-provenance/gigaspeech-3.3M-model-card.md` (the model's own upstream README, containing its license declaration verbatim), `model-provenance/bpe.model` (the SentencePiece tokenizer used offline to compute the keyword token string — not needed at runtime since the token string is precomputed), `model-provenance/example-keywords-raw.txt` (the model's own bundled example keyword list, kept as evidence of the plain-English-to-BPE-token mapping convention) |
| MODEL license, as declared by the model card itself | **Apache License 2.0** — this is the publisher's own explicit YAML frontmatter declaration (`license: Apache License 2.0`) in `model-provenance/gigaspeech-3.3M-model-card.md`, published by `pkufool` (a k2-fsa/icefall core maintainer) on ModelScope alongside the model weights. This is first-party, authoritative documentation shipped with the exact model artifact used here — not assumed from memory, not inferred. |
| Training data provenance (disclosed, not hidden) | The model card states training data is "gigaspeech XL (10000 小时 / 10,000 hours)". The GigaSpeech dataset's own published license restricts use to "non-commercial research and educational purposes," explicitly binding on for-profit/commercial users of the *dataset*. SpeechColab (GigaSpeech's publisher) has separately stated that "the license of the model is independent to that of the dataset" and that models trained on GigaSpeech "may be eligible for commercial license, provided they abide to the 'Fair Use' terms of the underlying data" — but also states "it is the user's responsibility to verify the appropriate model license for their specific use case," and SpeechColab does not claim to own copyright in the underlying audio. |
| Net assessment | The model publisher's own first-party Apache-2.0 declaration is real, credible, current evidence — not a fabricated or assumed license — and is materially stronger evidence than openWakeWord's pretrained models, which carry no such publisher declaration and instead default to their training data's explicit CC BY-NC-SA restriction (see `docs/W-adr-backlog.md` ADR-007 for that comparison). It is not, however, a substitute for independent legal confirmation given the underlying training data's own non-commercial dataset license — a genuine, disclosed residual question for wide commercial redistribution, not a clean, zero-risk grant. |
| Runtime credential required | No |
| Redistribution implications | **Local development / owner use: acceptable now**, on the strength of the publisher's own Apache-2.0 declaration. **Wide commercial redistribution: proceed with the publisher's Apache-2.0 declaration as the primary basis, but get a direct legal read on the GigaSpeech-XL training-data provenance question before shipping to third parties at scale** — this is the disclosed condition behind ADR-007's "RESOLVED FOR LOCAL DEVELOPMENT ONLY" status. |

## 4. Summary table

| Dependency | Code license | Model license | Credential | Redistribution |
|---|---|---|---|---|
| sherpa-onnx | Apache-2.0 | n/a (engine, not a model) | None | OK |
| ONNX Runtime | MIT (confirmed) | n/a | None | OK |
| gigaspeech-3.3M KWS model | n/a (weights, not code) | Apache-2.0 per publisher's own model card | None | OK for local dev; training-data provenance flagged before wide commercial redistribution |

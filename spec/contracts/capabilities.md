# Contract: Platform-capability adapters

The Apple-only capabilities the client depends on, expressed as interfaces so each platform supplies
its own implementation. The **deterministic path is the contract floor** - every AI capability must
degrade to it, and that floor is the part pinned by the logic-layer fixtures. Reference: `Logic/*`
(the 5 Foundation Models call sites), `Networking/PushKeychain.swift`, `Logic/AppLock.swift`.

| Capability | Interface (input -> output) | iOS today | Android | Web |
| --- | --- | --- | --- | --- |
| Receipt OCR | image -> text | Vision `VNRecognizeTextRequest` | ML Kit Text Recognition | WASM OCR (Tesseract-class) |
| Receipt extraction | OCR text -> `{merchant, date, total, items[]}` | Foundation Models `@Generable`; **floor:** `ReceiptHeuristics` (captured) | ML Kit GenAI (Gemini Nano), device-gated -> heuristics | none dependable -> heuristics or manual |
| Category refine/suggest | description (+note) -> **constrained** canonical category | Foundation Models, anchored `changeIsClear`; **floor:** deterministic precedence (captured) | Gemini Nano -> deterministic | deterministic only |
| Brand guess | cleaned merchant (+category hint) -> `{name, domain}` | Foundation Models + `brandRelatesToMerchant` guard; **floor:** offline catalog / embedded domain (captured) | on-device LLM -> catalog | catalog only |
| Transaction match re-rank | top-N candidates -> reordered | Foundation Models; **floor:** `TransactionMatcher` (captured) | -> deterministic | deterministic only |
| Secure key storage | store/load per-server token + E2E keypair | Keychain / App-Group Keychain (Secure Enclave) | Keystore (StrongBox/TEE) | non-extractable `CryptoKey` in IndexedDB (weaker) |
| Biometric app-lock | gate app -> authenticated | `LocalAuthentication` (Face ID -> passcode) | BiometricPrompt | WebAuthn (partial) |

## Rules the adapters must honor

- **AI output is never trusted blind.** Every model result is either constrained to a fixed allow-list
  (categories) or guarded (brand relatedness, anchored change) before use. A port must apply the same
  gate, or fall back to the deterministic path.
- **Availability is always checked**; on any unavailability or error, the deterministic path runs.
  "Nothing leaves the device" holds on every platform - where on-device AI is absent, the client uses
  OCR + deterministic parsing or manual entry, **not** a server round-trip (see
  `../docs/PORTING_ARCHITECTURE_SPEC.md` on why server-side extraction is a principle-level decision).
- **The trust property is tiered, not uniform**: full on iOS, capability-gated on Android, OCR-or-manual
  on web. Clients should surface this honestly rather than imply parity.

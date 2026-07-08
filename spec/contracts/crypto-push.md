# Contract: Crypto / push

The end-to-end-encrypted push envelope and its transport. Reference:
`ios/CleaveAPI/Sources/CleaveAPI/Networking/PushCrypto.swift`, `PushKeychain.swift`, backend
`services/crypto_push.py`, and the standalone relay (`relay/`).

## ECIES envelope (the portable part)

Notification content is sealed to the device's static P-256 key-agreement public key:

1. **P-256 ECDH**: the sender generates an ephemeral P-256 keypair; shared secret =
   ECDH(ephemeral private, device public). The ephemeral public key is sent as `epk` (base64 X9.63
   uncompressed, 65 bytes).
2. **HKDF-SHA256**: derive a 32-byte key with **salt = info = the literal bytes `"Cleave-push-v1"`**
   (both must byte-match `crypto_push.py`), output 32 bytes.
3. **AES-256-GCM**: `box` (base64) = `nonce ‖ ciphertext ‖ tag`; open with the derived key. Plaintext
   is JSON `{title, body[, target]}` where `target` is an optional deep-link `{type, id}`
   (see `deep-links.md`). Any malformed input or auth failure **fails closed** (no plaintext shown).

Device registration: `POST /devices` with the APNs/FCM token + the device's base64 X9.63 **public**
key. The private key never leaves the device.

## Pinned interop vector (the oracle)

`ios/CleaveTests/PushCryptoTests.swift` pins the scheme with a committed vector sealed by the backend
to a fixed device keypair - it is already a cross-language (Swift <-> Python) oracle and is the
reference any new client must satisfy:

- `priv` (raw 32-byte scalar, b64): `SioHLd3/p2ry7Mgc0Fg/BHhkwLqdbagPIaxWmlEGios=`
- `epk` (b64): `BDireDMW/sdqRbMJjidMHwurnMBAcZO7PttE2vqMpzbjHynaMSDJo7i+ZwVkkaNhhA5vIbDQ3dEgWBZjSgpYpPE=`
- `box` (b64): `znKU/G6pqs5ZB9cc2qvgnkVFxd2TtufbjwQqz0M7mFWa61Lsgd8Hgx9xYNJhJOUeuscAHocdkS9ftcq1P321jIa8R5A9rHo5jdI11SvMFbTEtJ4=`
- expected plaintext: `title = "Cleave"`, `body = "Alice added 'Dinner' $40"`.

A conforming client must decrypt this exact vector to that plaintext, and fail closed on a wrong key /
malformed box. (This vector is intentionally **not** re-implemented in the Node replayer - the
existing Swift<->Python test is its oracle; a Node ECIES verifier is a candidate follow-up.)

## Transport is NOT portable

The ECIES envelope is platform-neutral; the delivery rail under it is not:

- **iOS**: APNs, via the blind relay (`POST /push` with `{token, epk, box}` + a generic fallback
  alert; the relay and Apple see only ciphertext). A Notification Service Extension decrypts on-device
  (see `extensions.md`).
- **Android**: **FCM** - a new relay/backend path (not the APNs relay).
- **Web**: **Web Push + VAPID (RFC 8291)** - a different encryption/transport scheme entirely; the app
  envelope maps on top but the rail is standard Web Push, and delivery is best-effort (esp. iOS Safari
  PWAs).

Each new client platform therefore adds a **server-side delivery capability**, not just client code
(flagged in `../docs/PORTING_ARCHITECTURE_SPEC.md`, Track interactions).

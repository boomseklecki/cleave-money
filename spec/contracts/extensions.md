# Contract: Extensions / cross-process behavior

Out-of-app behaviors the client integrates with the OS. The per-platform *implementation* differs;
the *behavior* is the contract. Reference: `ios/CleaveNotificationService/`, `ios/CleaveShareExtension/`,
`Networking/SharedImportConfig.swift`, `PushKeychain.swift`.

## Notification Service Extension (decrypt push while locked)

- On a push carrying `userInfo["e2e"] = {epk, box}`, an out-of-process extension loads the device's
  E2E **private key from shared storage** (readable while the phone is locked) and decrypts the ECIES
  envelope (see `crypto-push.md`), replacing the generic fallback alert ("New activity") with the real
  title/body and copying the decrypted `target` into `userInfo` for tap routing.
- On **any** failure (no key, malformed, auth failure, timeout) it leaves the generic alert in place -
  so the relay and Apple never see plaintext.
- Contract for a port: push decryption must run **out of the main app process** and be able to read the
  device private key while locked (iOS App-Group Keychain `AfterFirstUnlock`; Android equivalent). The
  key material is shared between app and extension, never duplicated.

## Share extension (OFX import without opening the app)

- Activates for exactly one attachment of the app's OFX UTI (`money.cleave.ofx`), reads the file, and
  `POST`s it to `{base}/statements/import` with `Content-Type: application/x-ofx` and the bearer token
  - base URL + token read from **shared storage** (App-Group defaults + keychain). Shows an inline
  result ("Imported N transactions into <account>") or a mapped error; never opens the app.
- Contract for a port: a statement can be imported from the OS share sheet using the **same shared
  credentials** the app stores, hitting the same endpoint. FITID-based dedup on the server makes
  re-imports safe.

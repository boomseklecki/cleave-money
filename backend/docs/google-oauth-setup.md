# Sign in with Google (iOS + token-verifying backend)

A reusable walkthrough for wiring **Sign in with Google** into a native iOS app whose backend
verifies the Google **ID token** server-side. The pattern: the app obtains a Google ID token, the
backend checks its signature and `aud` against the same client id, then issues its own session
token. No client secret is needed for a native iOS client.

**Time:** ~10 minutes. **You'll produce:** one **iOS OAuth client id** (public - it ships in the
app) and its **reversed client id** (a URL scheme). That's it - an iOS client has no secret.

---

## 1. Create a Google Cloud project (skip if you have one)

1. Go to the [Google Cloud Console](https://console.cloud.google.com/).
2. Top bar → project picker → **New Project**. Name it, **Create**, then select it.

## 2. Configure the OAuth consent screen

Google requires a consent screen before it will mint client ids.

1. **APIs & Services → OAuth consent screen** (or **Google Auth Platform → Branding**).
2. **User type: External**, **Create**.
3. Fill the required fields: **App name**, **User support email**, **Developer contact email**.
   You do **not** need to add scopes - basic sign-in returns the user's OpenID profile (`sub`,
   `email`, `name`, `picture`) by default.
4. Save. While the app is in **Testing** status, add each tester's Google address under
   **Audience → Test users** (otherwise their sign-in is rejected). Publish to **Production** when
   you're ready for anyone to sign in - basic profile/email scopes need no Google verification review.

## 3. Create the iOS OAuth client id

1. **APIs & Services → Credentials → Create Credentials → OAuth client ID**.
2. **Application type: iOS**.
3. **Bundle ID:** your app's bundle identifier (e.g. `money.yourcompany.app`). It must match the
   app exactly.
4. (Optional) **App Store ID** / **Team ID** - fine to leave blank for development.
5. **Create.** Copy the two values from the client's detail page:
   - **Client ID** - looks like `1234567890-abc123def456.apps.googleusercontent.com`.
   - **iOS URL scheme** (aka *reversed client id*) - the client id with its two dot-separated
     halves swapped: `com.googleusercontent.apps.1234567890-abc123def456`.

> There is **no client secret** for an iOS client. The client id is public and ships inside the
> app binary; security comes from the backend verifying the ID token's signature and audience.

## 4. Wire it into the app + backend

Three places use these two values:

| Value | Where it goes | Purpose |
| --- | --- | --- |
| **Client ID** | App: `Info.plist` key `GIDClientID` | Tells the Google Sign-In SDK which client to use |
| **Reversed client id** | App: `Info.plist` → `CFBundleURLTypes` → a URL scheme | Lets Google redirect back into the app after sign-in |
| **Client ID** | Backend: the `GOOGLE_CLIENT_ID` env var | The **audience** the backend checks every ID token against |

The app's client id and the backend's `GOOGLE_CLIENT_ID` **must be identical** - that equality is
the security check: the backend rejects any token not minted for this exact client.

### How the backend verifies (what to implement, if it isn't already)

On `POST /auth/google` with the app's ID token, the backend must:

1. Fetch Google's public keys from `https://www.googleapis.com/oauth2/v3/certs` (JWKS, cacheable).
2. Verify the token's **RS256 signature**, `iss` ∈ {`accounts.google.com`,
   `https://accounts.google.com`}, `aud == GOOGLE_CLIENT_ID`, and `exp` not passed.
3. Treat the `email` as unverified only when `email_verified` is explicitly `false` (an absent claim counts as verified); in that case drop the `email` rather than reject the token.
4. Resolve-or-create the user from the stable `sub` claim, then issue your own session token.

## 5. Test

- Run the app, tap **Sign in with Google**, pick a **test user** account (step 2).
- A `redirect_uri_mismatch` or `invalid_client` almost always means the bundle id in the client
  doesn't match the app, or the reversed-client-id URL scheme is missing/typo'd in `Info.plist`.
- `401` from the backend usually means `GOOGLE_CLIENT_ID` ≠ the app's client id, or the token
  expired (they're short-lived - re-run sign-in).
- A **valid** token can also be `401`ed by an enrollment gate: many backends (Cleave included)
  require a new user to redeem an invite (or be the first user / already enrolled) before a
  session is issued. That is a separate check from token validity.

---

## Reuse checklist (for the next project)

- [ ] New Google Cloud project (or reuse one).
- [ ] Consent screen configured; testers added while in Testing.
- [ ] **iOS** OAuth client id created with the new app's bundle id.
- [ ] `GIDClientID` + reversed-client-id URL scheme in the app's `Info.plist`.
- [ ] `GOOGLE_CLIENT_ID` (== the app client id) in the backend env.
- [ ] Backend verifies signature + `aud`; drops the `email` only when `email_verified` is explicitly false.

## For Cleave specifically

- **Bundle id:** `money.cleave.app` (see `ios/project.yml`).
- **Apple Sign-In** is wired the same way (`POST /auth/apple`, audience = the bundle id); the same
  unverified-email handling and enrollment gate apply.
- App side is already wired: `GIDClientID` and the reversed-client-id URL scheme are in
  `ios/project.yml` (baked into `Info.plist` on `xcodegen generate`).
- Backend side: set `GOOGLE_CLIENT_ID` in `.env` (and `.env.dev` / `.env.demo` if you want Google
  sign-in on those stacks). Verification is implemented in `app/integrations/auth/google.py`.
- **Which client id?** If your users install the **published Cleave app** (the easiest path), you
  don't create a client id at all - set `GOOGLE_CLIENT_ID` to the published app's public client id
  (`466528965386-hjlem1kitvnnbgg28ola7iempqr85gg1.apps.googleusercontent.com`), since the token
  audience is whatever the installed binary was built with. Only if you **build and ship your own
  app** (the white-label path) do you create your own iOS client id per the steps above and use it in
  both places. Splitwise/demo/bearer sign-in don't have this constraint (they aren't baked into the app).

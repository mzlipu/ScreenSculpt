# Security Policy

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** — the "Report a vulnerability"
button under the Security tab. Please do not open a public issue for a security
problem.

Expect an acknowledgement within 72 hours and an assessment within a week.
Coordinated disclosure at 90 days, or sooner once a fix has shipped.

## Supported versions

The latest release only. There are no backported security branches.

## Threat model

ScreenSculpt is a privileged application and should be treated as one.

**What it holds**

- **Screen Recording** (`kTCCServiceScreenCapture`) — it can read every pixel on
  screen, including other applications' windows, password fields as rendered,
  and anything visible during a capture.
- **Accessibility** (`kTCCServiceAccessibility`), *only* if you use auto
  scrolling capture — it can synthesize input events.
- **Keychain** — S3 credentials, if you configure upload.

Consequently, arbitrary code execution in ScreenSculpt is a **high severity**
finding, not a medium one.

**What it does not do**

- No network requests unless you configure S3 upload, and then only to the
  endpoint you specified.
- No telemetry, analytics, crash reporting or phone-home of any kind.
- Screenshots never leave the machine unless you explicitly upload them.
- No account, no server, no hosted service exists.

## Distribution: read this before you install

ScreenSculpt is **not signed with an Apple Developer ID and is not notarized.**
This is a deliberate, documented trade-off and it has real security consequences
you should weigh:

1. **You cannot verify the publisher from the binary.** There is no certificate
   chain to check. `codesign -dv` will report `Signature=adhoc` and
   `TeamIdentifier=not set`.
2. **The published SHA-256 is your only integrity signal.** Verify it:
   ```bash
   shasum -a 256 ScreenSculpt-1.0.0.dmg
   ```
   Compare against the checksum on the release page *and* the one in the GitHub
   release — they are published to two independent hosts precisely so that
   compromising one is not enough.
3. **Building from source is the strongest guarantee available.** It is three
   commands, and a locally built app is not quarantined:
   ```bash
   brew bundle && make bootstrap && make build
   ```

If a verifiable publisher identity matters for your threat model, build from
source rather than downloading a binary.

## Update channel

Updates are delivered by Sparkle and verified with an **EdDSA (ed25519)
signature** over the update archive. Since there is no Apple code signature, that
key is the *only* trust root protecting the update path.

What this means in practice: an attacker who compromises the download bucket can
replace the DMG that new users download, but **cannot push a malicious update to
existing installs**, because they cannot forge the EdDSA signature. The private
key is held offline and is never present in CI logs or the repository.

If you believe the update channel has been compromised, disable automatic
updates in Settings and report it privately.

## Scope

In scope: the application, the update mechanism, the release pipeline, and the
build scripts in this repository.

Out of scope: the Gatekeeper warnings described above (known and documented), and
the TCC permission reset on update (a consequence of unsigned distribution, also
documented).

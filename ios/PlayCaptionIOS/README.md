# PlayCaption iOS — experimental port

Native iPhone companion to the *existing* PlayCaption TV receiver (AdamRuzick4/PlayCaption-app). It is designed to connect to a user's **own Xbox** using xHome / WebRTC, read English game subtitles with Apple Vision, translate to Czech and send `PCT1` subtitles over LAN to PlayCaption TV.

**Status: development build — NOT verified to establish Xbox Remote Play on an iPhone yet.** Do not distribute or advertise as working until tested. The working parts are source code / integration; CI must still compile the iOS target, and Xbox services may change.

## TV side

Leave the original PlayCaption installed on your Google TV. Choose **S telefonem / Titulky z telefonu**. Enter the TV's local IP in iPhone app (auto-discovery via UDP 41988 is best-effort because iOS LAN permissions / broadcast policies may restrict discovery). Use **Odeslat zkušební titulek**. The TV listens on UDP 41989 and uses the `PCT1<TAB>sequence<TAB>durationMs<TAB>escapedText<TAB>hint` protocol. UDP send success alone is not proof the TV displayed it.

## Xbox side

1. Sign in with Microsoft device-code flow (local browser, no password collected).
2. Load consoles from xHome.
3. Choose console and press **Spustit překlad**.
4. Keep iPhone awake and PlayCaption foregrounded; iOS does not guarantee continuous custom WebRTC + OCR when locked or backgrounded.
5. Turn on English game subtitles. Phone receives video for OCR only; play on the Xbox via HDMI/controller as normal.

The OAuth client ID is currently inherited from the Android reference implementation **for development only**. Replace with a Microsoft app registration that is authorized for the required scope before publishing for others. Xbox home streaming endpoints are unofficial and may change.

## IPA build (LiveContainer)

GitHub Actions workflow `.github/workflows/build-playcaption-ios.yml` runs on macOS with XcodeGen + prebuilt WebRTC SwiftPM binary. On successful build, download workflow artifact `PlayCaptionIOS-unsigned` and extract `PlayCaptionIOS-unsigned.ipa`. LiveContainer can import unsigned IPAs, subject to its own compatibility/signing limitations. **This repo is not proof that an IPA was successfully built until the workflow shows success.**

No server, password sharing, account credentials in diagnostics or screenshot uploads.

### Attribution / license

Independent iOS implementation guided by the open source Android reference: https://github.com/AdamRuzick4/PlayCaption-app

Uses https://github.com/stasel/WebRTC and Apple frameworks. Review upstream licenses and the Microsoft/Xbox service terms before redistribution. Not affiliated with Xbox, Microsoft, TCL, Google or the original PlayCaption developer.

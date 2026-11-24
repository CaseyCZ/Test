# TV Movie Translation

Standalone Android TV application, no phone or gaming connection. Separate application ID and debug build; no release or changes to other branches.

## OCR
Use user-consented MediaProjection, crop the configurable subtitle region, reuse OCR and translation pipeline where available, deduplicate text, and display translated subtitles via a non-focusable overlay. Stop capture on permission revocation. Do not bypass protected surfaces.

## Audio
Android 10+ AudioPlaybackCaptureConfiguration with MediaProjection and RECORD_AUDIO permission, matching USAGE_MEDIA. Feed PCM into a speech recognition engine that supports supplied audio (not implicit microphone capture), then translate and display timed subtitles. Report unavailable capture or recognition, silence alone does not prove DRM. No microphone fallback without explicit consent.

## Acceptance
TV remote controls, configurable subtitle position/font/color, start/stop, clear privacy disclosure and language selection. Test unprotected video first, then Netflix/other apps with normal system permissions. No claim of Netflix compatibility until device testing.

## Status
Branch created. Existing repository contains patch/build tooling rather than full Android source. Implementation, independent build, and device tests pending.

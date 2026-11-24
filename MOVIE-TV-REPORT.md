# Movie TV report

- OCR prototype committed; first CI run failed before compilation because sdkmanager was not on PATH. Fixed runner and SDK lookup.
- Audio prototype uses consented AudioPlaybackCapture, Vosk English model downloaded from Alpha Cephei on first audio start, and ML Kit English-to-Czech translation. No microphone capture or audio storage. Silence may be content silence or blocked capture.
- Audio currently English only; build and actual TV testing pending. No Netflix compatibility claim, no release.

- Enabled AndroidX following CI metadata failure. Added persistent shared subtitle size, color, opacity and top/bottom/automatic position; percentage OCR crop with remote-friendly settings and diagram. OCR overlay marked secure to avoid capturing its own text (device behavior unverified). Changes apply on restart. Build/device verification pending.

- Performance: OCR capture capped at 1920 pixels wide, bounded 128-entry per-session translation cache, audio duplicate suppression, dark-region warning after eight seconds (not proof of DRM). Added four JVM cache tests. CI and device verification pending.

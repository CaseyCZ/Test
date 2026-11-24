# Movie TV 0.3 test checklist
Build artifact only; not a release. Android TV 10 or newer.
1. Install APK alongside GameLingo (different app ID).
2. Grant overlay permission, select English OCR and confirm full-screen capture.
3. Open an unprotected local video with English subtitles. Verify translation, crop, font and placement; change settings after stopping and restart.
4. Stop via app or notification; verify overlay vanishes and projection stops.
5. Start AUDIO, allow audio capture and download models. Use unprotected English dialogue; confirm Czech output, pause/resume and silence warning.
6. Switch modes, deny permissions, revoke screen sharing, restart app. Verify no duplicate overlays.
7. Try Netflix separately. Record OCR and AUDIO results independently; a black frame or silence does not establish DRM by itself. No bypass.
8. Measure delay and responsiveness on TCL C835; device tests not yet performed.

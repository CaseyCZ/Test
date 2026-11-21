#!/usr/bin/env python3
"""Diagnostic PlayCaption 0.22 patch for TCL C835. Does not modify upstream."""
from __future__ import annotations
import pathlib
import struct
import sys
import zlib


def replace_once(path: pathlib.Path, before: str, after: str) -> None:
    current = path.read_text(encoding="utf-8")
    n = current.count(before)
    if n != 1:
        raise RuntimeError(f"Unexpected source {path}: expected one match, got {n}: {before[:80]!r}")
    path.write_text(current.replace(before, after, 1), encoding="utf-8")
    print(f"Patched {path}")


def png_chunk(kind: bytes, data: bytes) -> bytes:
    import binascii
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF)


def make_branding(path: pathlib.Path, width: int, height: int) -> None:
    """Create an independent RGB icon and banner using only standard Python."""
    rows = bytearray()
    cx, cy = width // 2, height // 2
    s = min(width, height)
    for y in range(height):
        rows.append(0)
        for x in range(width):
            color = (10, 16, 29)
            dx, dy = abs(x-cx), abs(y-cy)
            if dx < 0.37*s and dy < 0.32*s:
                color = (25, 43, 62)
            if ((0.30*s < dx < 0.34*s and dy < 0.29*s) or (0.28*s < dy < 0.32*s and dx < 0.34*s)):
                color = (58, 218, 198)
            if 0.065*s < (y-cy) < 0.095*s and dx < 0.22*s:
                color = (238, 245, 255)
            if 0.16*s < (y-cy) < 0.19*s and dx < 0.15*s:
                color = (178, 201, 225)
            rows.extend(color)
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR",header) +
                     png_chunk(b"IDAT",zlib.compress(bytes(rows),9)) + png_chunk(b"IEND",b""))


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python tools/patch_tcl835.py upstream")
    root = pathlib.Path(sys.argv[1]).resolve()
    gradle = root/"app/build.gradle.kts"
    if not gradle.exists() or 'versionName = "0.22"' not in gradle.read_text(encoding="utf-8"):
        raise SystemExit("Only original PlayCaption 0.22 sources may be patched.")

    replace_once(gradle,
        '    buildTypes {\n        release { isMinifyEnabled = false }\n    }',
        '    buildTypes {\n        getByName("debug") {\n'
        '            applicationIdSuffix = ".tcl835gpudiag"\n'
        '            versionNameSuffix = "-tcl835-gpu-diagnostic"\n'
        '        }\n        release { isMinifyEnabled = false }\n    }')
    replace_once(root/"app/src/main/res/values/strings.xml",
        '<string name="app_name">PlayCaption</string>',
        '<string name="app_name">TCL Caption GPU TEST</string>')

    draw = root/"app/src/main/res/drawable-nodpi"
    draw.mkdir(parents=True, exist_ok=True)
    make_branding(draw/"tcl_test_icon.png",256,256)
    make_branding(draw/"tcl_test_banner.png",320,180)

    manifest = root/"app/src/main/AndroidManifest.xml"
    original = manifest.read_text(encoding="utf-8")
    if original.count("@drawable/gamelingo_ikona") != 3 or original.count("@drawable/gamelingo_banner") != 1:
        raise RuntimeError("Unexpected Android manifest")
    manifest.write_text(original.replace("@drawable/gamelingo_ikona", "@drawable/tcl_test_icon")
                                .replace("@drawable/gamelingo_banner", "@drawable/tcl_test_banner"),
                        encoding="utf-8")

    foreground = root/"app/src/main/java/cz/titulky/tv/Popredi.kt"
    replace_once(foreground,
        '            posledni = nalez\n',
        '            if (nalez != posledni) {\n'
        '                android.util.Log.i("TCLCaptionTest", "foreground=" + (nalez ?: "unknown"))\n'
        '                runCatching {\n'
        '                    java.io.File(context.filesDir, "titulky.log").appendText(\n'
        '                        "[TCL C835 TEST] foreground=" + (nalez ?: "unknown") + "\\n")\n'
        '                }\n'
        '            }\n'
        '            posledni = nalez\n')
    replace_once(foreground,
        '    fun jeVstupTv(): Boolean {\n        val p = balicek() ?: return true\n',
        '    fun jeVstupTv(): Boolean {\n'
        '        // Diagnostic: temporarily avoid hiding captions when TV reports\n'
        '        // an unexpected foreground app while HDMI is active.\n'
        '        // Captions might show over the launcher; revert after test.\n'
        '        if (!Rezim.jeTelefon(context)) { balicek(); return true }\n'
        '        val p = balicek() ?: return true\n')

    remote = root/"app/src/main/java/cz/titulky/tv/RemotePlayService.kt"
    replace_once(remote,
        '            if (lg) {\n                if (cpuZamek == null)',
        '            // Diagnostic: hold CPU wake lock for active TV Remote Play.\n'
        '            val tvDiagnostic = ano && aktivni && !Rezim.jeTelefon(this)\n'
        '            if (lg || tvDiagnostic) {\n                if (cpuZamek == null)')
    replace_once(remote,
        '    override fun onBind(intent: Intent?): IBinder? = null\n\n    override fun onDestroy() {',
        '    override fun onBind(intent: Intent?): IBinder? = null\n\n'
        '    override fun onTaskRemoved(rootIntent: Intent?) {\n'
        '        zapis("[TCL C835 TEST] onTaskRemoved")\n'
        '        super.onTaskRemoved(rootIntent)\n'
        '    }\n\n    override fun onDestroy() {')
    replace_once(remote,
        '    override fun onDestroy() {\n        zanikla = true\n',
        '    override fun onDestroy() {\n'
        '        zapis("[TCL C835 TEST] RemotePlayService onDestroy")\n'
        '        zanikla = true\n')
    # v2 experiment: Android phone path uses a decoder without EGL GPU textures.
    # The TCL's first Xbox frame was TextureBufferImpl; see if the texture
    # path stalls when Google TV switches the foreground to the HDMI input.
    replace_once(remote,
        '}, priSnimku = { f -> snimekXbox(f) }, bezGpu = telefon)',
        '}, priSnimku = { f -> snimekXbox(f) }, bezGpu = true)')

    xbox = root/"app/src/main/java/cz/titulky/tv/XboxSpojeni.kt"
    replace_once(xbox,
        '            // 3) WebRTC\n            priStavu("Navazuji spojení s Xboxem…")',
        '            // 3) WebRTC\n'
        '            log("[TCL C835 GPU TEST] dekoder bez EGL textur=" + bezGpu)\n'
        '            priStavu("Navazuji spojení s Xboxem…")')
    replace_once(xbox,
        '        @Volatile private var posledniSnimek = 0L\n',
        '        @Volatile private var posledniSnimek = 0L\n'
        '        @Volatile private var posledniStatistikaSnimku = 0L\n')
    replace_once(xbox,
        '            posledniSnimek = System.currentTimeMillis()\n            sirka = f.rotatedWidth; vyska = f.rotatedHeight',
        '            posledniSnimek = System.currentTimeMillis()\n'
        '            if (posledniSnimek - posledniStatistikaSnimku > 10000L) {\n'
        '                posledniStatistikaSnimku = posledniSnimek\n'
        '                log("[TCL C835 GPU TEST] snimku celkem=" + snimku + ", typ=" + f.buffer.javaClass.simpleName)\n'
        '            }\n'
        '            sirka = f.rotatedWidth; vyska = f.rotatedHeight')
    # Dedicated, privacy-safe diagnostics shown by the built-in diagnostic screen.
    diagnostic_source = pathlib.Path(__file__).with_name("TclDiagnostika.kt")
    if not diagnostic_source.is_file():
        raise RuntimeError("TclDiagnostika.kt must ship with the patch script")
    (root/"app/src/main/java/cz/titulky/tv/TclDiagnostika.kt").write_text(
        diagnostic_source.read_text(encoding="utf-8"), encoding="utf-8")

    replace_once(foreground,
        "    fun jeVstupTv(): Boolean {\n",
        "    private var tclPosledniVstup: String? = null\n    fun jeVstupTv(): Boolean {\n")

    replace_once(foreground,
        "        if (!Rezim.jeTelefon(context)) { balicek(); return true }\n",
        "        if (!Rezim.jeTelefon(context)) {\n            // The GPU test already forces true. Record what normal detection would say.\n            val p = balicek()\n            val info = p?.let { runCatching { pm.getApplicationInfo(it, 0) }.getOrNull() }\n            val realneVstup = when {\n                p == null -> true\n                p == context.packageName -> true\n                p == domov -> false\n                p in ZNAME_VSTUPY -> true\n                info == null -> true\n                else -> {\n                    val systemova = info.flags and ApplicationInfo.FLAG_SYSTEM != 0\n                    val aktualizovana = info.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP != 0\n                    val spustitelna = pm.getLeanbackLaunchIntentForPackage(p) != null ||\n                        pm.getLaunchIntentForPackage(p) != null\n                    !(spustitelna && (!systemova || aktualizovana))\n                }\n            }\n            val klic = (p ?: \"unknown\") + \"|\" + realneVstup\n            if (klic != tclPosledniVstup) {\n                tclPosledniVstup = klic\n                TclDiagnostika.zapis(context, \"[INPUT] package=\" + (p ?: \"unknown\") +\n                    \" normalWouldShow=\" + realneVstup + \" gpuTestForcesShow=true\" +\n                    \" usagePermission=\" + Popredi.maOpravneni(context))\n            }\n            return true\n        }\n")

    replace_once(remote,
        "    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {\n",
        "    private val tclHlidac = object : Runnable {\n        override fun run() {\n            if (aktivni && !Rezim.jeTelefon(this@RemotePlayService)) {\n                val ted = System.currentTimeMillis()\n                val age = if (snimkuCelkem > 0) ted - posledniSnimekKdy else -1L\n                val balicek = runCatching { popredi.balicek() }.getOrNull() ?: \"unknown\"\n                TclDiagnostika.zapis(this@RemotePlayService,\n                    \"[RP HEARTBEAT] active=\" + aktivni +\n                    \" xbox=\" + naXboxu + \" connected=\" + pripojeno() +\n                    \" receivedFrames=\" + (xbox?.snimku ?: -1L) +\n                    \" processedFrames=\" + snimkuCelkem +\n                    \" lastProcessedAgeMs=\" + age +\n                    \" foreground=\" + balicek +\n                    \" overlayReady=\" + OverlayService.pripravena + \" \" +\n                    TclDiagnostika.system(this@RemotePlayService))\n            }\n            ui.postDelayed(this, 5000L)\n        }\n    }\n\n    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {\n        TclDiagnostika.zapis(this, \"[RP START] action=\" + (intent?.action ?: \"default\") +\n            \" startId=\" + startId + \" flags=\" + flags + \" \" + TclDiagnostika.system(this))\n")

    replace_once(remote,
        "    override fun onCreate() {\n        super.onCreate()\n",
        "    override fun onCreate() {\n        super.onCreate()\n        TclDiagnostika.zapis(this, \"[RP CREATE] device=\" +\n            android.os.Build.MANUFACTURER + \"/\" + android.os.Build.MODEL +\n            \" sdk=\" + android.os.Build.VERSION.SDK_INT + \" \" + TclDiagnostika.system(this))\n        ui.postDelayed(tclHlidac, 1000L)\n")

    replace_once(remote,
        "    override fun onBind(intent: Intent?): IBinder? = null\n",
        "    override fun onTrimMemory(level: Int) {\n        TclDiagnostika.zapis(this, \"[RP TRIM MEMORY] level=\" + level +\n            \" active=\" + aktivni + \" frames=\" + snimkuCelkem)\n        super.onTrimMemory(level)\n    }\n\n    override fun onLowMemory() {\n        TclDiagnostika.zapis(this, \"[RP LOW MEMORY] active=\" + aktivni)\n        super.onLowMemory()\n    }\n\n    override fun onBind(intent: Intent?): IBinder? = null\n")

    replace_once(remote,
        "        zapis(\"[TCL C835 TEST] onTaskRemoved\")\n",
        "        TclDiagnostika.zapis(this, \"[RP TASK REMOVED] \" + TclDiagnostika.system(this))\n        zapis(\"[TCL C835 TEST] onTaskRemoved\")\n")

    replace_once(remote,
        "        zapis(\"[TCL C835 TEST] RemotePlayService onDestroy\")\n",
        "        TclDiagnostika.zapis(this, \"[RP DESTROY] active=\" + aktivni + \" receivedFrames=\" + (xbox?.snimku ?: -1L) + \" processedFrames=\" + snimkuCelkem)\n        ui.removeCallbacks(tclHlidac)\n        zapis(\"[TCL C835 TEST] RemotePlayService onDestroy\")\n")

    replace_once(root/"app/src/main/java/cz/titulky/tv/XboxLog.kt",
        "        android.util.Log.i(\"PlayCaptionXbox\", r)\n",
        "        android.util.Log.i(\"PlayCaptionXbox\", r)\n        // Only sanitized transport and frame state; never server messages or tokens.\n        if (radek.startsWith(\"[Xbox] ICE:\") ||\n            radek.startsWith(\"[Xbox] obraz stojí\") ||\n            radek.startsWith(\"[Xbox] handshake OK\") ||\n            radek.startsWith(\"[Xbox] PRVNÍ SNÍMEK\") ||\n            radek.startsWith(\"[Xbox] konzole ukončila spojení\") ||\n            radek.startsWith(\"[Xbox] ukončeno\") ||\n            radek.startsWith(\"[TCL C835 GPU TEST]\")) {\n            TclDiagnostika.zapis(ctx, \"[RTC] \" + radek)\n        }\n")

    replace_once(root/"app/src/main/java/cz/titulky/tv/OverlayService.kt",
        "        zkusOkna(0)\n",
        "        zkusOkna(0)\n        TclDiagnostika.zapis(this, \"[OVERLAY CREATE] ready=\" + pripravena + \" \" + TclDiagnostika.system(this))\n")

    replace_once(root/"app/src/main/java/cz/titulky/tv/OverlayService.kt",
        "    override fun onDestroy() {\n        zrusPribeh()\n",
        "    override fun onDestroy() {\n        TclDiagnostika.zapis(this, \"[OVERLAY DESTROY] ready=\" + pripravena)\n        zrusPribeh()\n")

    replace_once(root/"app/src/main/java/cz/titulky/tv/PrijemService.kt",
        "        if (prijimac == null) {\n",
        "        if (prijimac == null) {\n            TclDiagnostika.zapis(this, \"[TV RECEIVE START] \" + TclDiagnostika.system(this))\n")

    replace_once(root/"app/src/main/java/cz/titulky/tv/PrijemService.kt",
        "    override fun onDestroy() {\n",
        "    override fun onDestroy() {\n        TclDiagnostika.zapis(this, \"[TV RECEIVE DESTROY] lastMessageMs=\" + (prijimac?.posledniZprava ?: 0L))\n")

    replace_once(root/"app/src/main/java/cz/titulky/tv/Zaznam.kt",
        "            \"\\n\\n=== titulky.log ===\\n\" + konec(\"titulky.log\", 120) +\n",
        "            \"\\n\\n=== TCL C835 HDMI TRACE ===\\n\" + konec(\"tcl835-diagnostic.log\", 120) +\n            \"\\n\\n=== titulky.log ===\\n\" + konec(\"titulky.log\", 120) +\n")

    config_source = pathlib.Path(__file__).with_name("TclOnlineNastaveni.kt")
    if not config_source.is_file():
        raise RuntimeError("TclOnlineNastaveni.kt must ship with the patch script")
    (root/"app/src/main/java/cz/titulky/tv/TclOnlineNastaveni.kt").write_text(
        config_source.read_text(encoding="utf-8"), encoding="utf-8")

    replace_once(foreground,
        "\" normalWouldShow=\" + realneVstup + \" gpuTestForcesShow=true\" +\n",
        "\" normalWouldShow=\" + realneVstup + \" onlineForceOverlay=\" + TclOnlineNastaveni.vynutitPrekryv +\n")

    replace_once(foreground,
        "            return true\n        }\n        val p = balicek() ?: return true\n",
        "            return TclOnlineNastaveni.vynutitPrekryv || realneVstup\n        }\n        val p = balicek() ?: return true\n")

    replace_once(remote,
        "            val tvDiagnostic = ano && aktivni && !Rezim.jeTelefon(this)\n",
        "            val tvDiagnostic = ano && aktivni && !Rezim.jeTelefon(this) && TclOnlineNastaveni.zamykatCpu\n")

    replace_once(remote,
        "}, priSnimku = { f -> snimekXbox(f) }, bezGpu = true)",
        "}, priSnimku = { f -> snimekXbox(f) }, bezGpu = telefon || TclOnlineNastaveni.dekoderBezGpu)")

    replace_once(remote,
        "        ui.postDelayed(tclHlidac, 1000L)\n",
        "        TclOnlineNastaveni.obnov(this)\n        ui.postDelayed(tclHlidac, 1000L)\n")

    replace_once(remote,
        "    private val tclHlidac = object : Runnable {\n",
        "    private var tclOnlineRevize = 0\n    private var tclPosledniZapisMs = 0L\n    private val tclHlidac = object : Runnable {\n")

    replace_once(remote,
        "        override fun run() {\n            if (aktivni && !Rezim.jeTelefon(this@RemotePlayService)) {\n",
        "        override fun run() {\n            TclOnlineNastaveni.obnov(this@RemotePlayService)\n            if (tclOnlineRevize != TclOnlineNastaveni.revize) {\n                tclOnlineRevize = TclOnlineNastaveni.revize\n                if (aktivni) drzWifi(napajeniZapnuto)\n            }\n            val tedLog = android.os.SystemClock.elapsedRealtime()\n            if (aktivni && !Rezim.jeTelefon(this@RemotePlayService) &&\n                tedLog - tclPosledniZapisMs >= TclOnlineNastaveni.intervalLoguSekund * 1000L) {\n                tclPosledniZapisMs = tedLog\n")

    replace_once(root/"app/src/main/java/cz/titulky/tv/PrijemService.kt",
        "            val ted = System.currentTimeMillis()\n",
        "            val ted = System.currentTimeMillis()\n            TclOnlineNastaveni.obnov(this@PrijemService)\n")

    upload_source = pathlib.Path(__file__).with_name("TclOdesilacLogu.kt")
    if not upload_source.is_file():
        raise RuntimeError("TclOdesilacLogu.kt must ship with the patch script")
    (root/"app/src/main/java/cz/titulky/tv/TclOdesilacLogu.kt").write_text(
        upload_source.read_text(encoding="utf-8"), encoding="utf-8")

    replace_once(remote,
        "            TclOnlineNastaveni.obnov(this@RemotePlayService)\n            if (tclOnlineRevize != TclOnlineNastaveni.revize) {",
        "            TclOnlineNastaveni.obnov(this@RemotePlayService)\n            TclOdesilacLogu.zkusOdeslat(this@RemotePlayService)\n            if (tclOnlineRevize != TclOnlineNastaveni.revize) {")

    replace_once(root/"app/src/main/java/cz/titulky/tv/PrijemService.kt",
        "            TclOnlineNastaveni.obnov(this@PrijemService)\n",
        "            TclOnlineNastaveni.obnov(this@PrijemService)\n            TclOdesilacLogu.zkusOdeslat(this@PrijemService)\n")

    replace_once(root/"app/src/main/java/cz/titulky/tv/XboxLog.kt",
        "            TclDiagnostika.zapis(ctx, \"[RTC] \" + radek)\n",
        "            TclDiagnostika.zapis(ctx, \"[RTC] \" + radek)\n            if (radek.startsWith(\"[Xbox] ICE: DISCONNECTED\") ||\n                radek.startsWith(\"[Xbox] ICE: FAILED\") ||\n                radek.startsWith(\"[Xbox] ICE: CLOSED\") ||\n                radek.startsWith(\"[Xbox] konzole ukončila spojení\")) {\n                TclOdesilacLogu.zkusOdeslat(ctx, urgent = true)\n            }\n")

    print("TCL Caption GPU TEST ready; independent package: cz.titulky.tv.tcl835gpudiag")


if __name__ == "__main__":
    main()

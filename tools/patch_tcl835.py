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
        '            applicationIdSuffix = ".tcl835test"\n'
        '            versionNameSuffix = "-tcl835-test"\n'
        '        }\n        release { isMinifyEnabled = false }\n    }')
    replace_once(root/"app/src/main/res/values/strings.xml",
        '<string name="app_name">PlayCaption</string>',
        '<string name="app_name">TCL Caption TEST</string>')

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
    print("TCL Caption TEST ready; independent package: cz.titulky.tv.tcl835test")


if __name__ == "__main__":
    main()

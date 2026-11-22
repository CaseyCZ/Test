#!/usr/bin/env python3
"""Build-only TCL C835 iPhone receiver test patch on pinned PlayCaption v0.22.

Never modifies the original upstream repository. Does not touch Xbox/RemotePlay.
The test APK installs with a separate application ID and listens on UDP 41989,
so the original app must NOT have its "S telefonem" receiver running at the same time.
"""
from __future__ import annotations
import pathlib
import sys


def once(path: pathlib.Path, before: str, after: str) -> None:
    text = path.read_text(encoding="utf-8")
    if text.count(before) != 1:
        raise RuntimeError(f"{path}: expected exactly one anchor, got {text.count(before)}: {before[:100]!r}")
    path.write_text(text.replace(before, after, 1), encoding="utf-8")
    print(f"Patched {path}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python patch_tv_iphone.py <pinned-upstream-root>")
    root = pathlib.Path(sys.argv[1]).resolve()
    gradle = root / "app/build.gradle.kts"
    assert 'versionName = "0.22"' in gradle.read_text(encoding="utf-8"), "Unexpected upstream version"

    # Fully independent TV test installation; signed locally with debug key by CI.
    once(gradle,
         '    buildTypes {\n        release { isMinifyEnabled = false }\n    }',
         '    buildTypes {\n'
         '        getByName("debug") {\n'
         '            applicationIdSuffix = ".iphonebridge"\n'
         '            versionNameSuffix = "-iphone-tv-test"\n'
         '        }\n'
         '        release { isMinifyEnabled = false }\n'
         '    }')
    once(root / "app/src/main/res/values/strings.xml",
         '<string name="app_name">PlayCaption</string>',
         '<string name="app_name">PlayCaption iPhone TV TEST</string>')

    networking = root / "app/src/main/java/cz/titulky/tv/Propojeni.kt"
    once(networking,
         '        @Volatile var posledniZprava = 0L\n            private set',
         '        @Volatile var posledniZprava = 0L\n            private set\n'
         '        /** Diagnostic counters; never persist or log game text. */\n'
         '        @Volatile var pocetTitulku = 0L\n            private set\n'
         '        @Volatile var posledniIP = ""\n            private set\n'
         '        @Volatile var posledniCisloTitulku = -1L\n            private set')
    # Prevent two installed applications from silently sharing the same UDP port.
    # If original PlayCaption is still receiving, this receiver fails visibly.
    once(networking, '                        reuseAddress = true\n                        soTimeout = 1000',
         '                        reuseAddress = false\n                        soTimeout = 1000')
    once(networking, '                        posledniCislo = cislo\n                        val doba =',
         '                        posledniCislo = cislo\n'
         '                        pocetTitulku += 1\n'
         '                        posledniIP = p.address.hostAddress ?: ""\n'
         '                        posledniCisloTitulku = cislo\n'
         '                        val doba =')
    # Acknowledges the UDP receiver only. No false "displayed" claim.
    once(networking,
         '                        priTitulku(odEscapuj(casti[3]), doba, odEscapuj(casti[4]), rozvrh, barvy)\n',
         '                        priTitulku(odEscapuj(casti[3]), doba, odEscapuj(casti[4]), rozvrh, barvy)\n'
         '                        // Optional iOS confirmation: PCT1 parsed and queued, not proof of overlay.\n'
         '                        odpovez(s, p, "PCA1\\t$cislo\\tRECEIVED")\n')
    once(networking,
         '                }.onFailure { if (bezi) chyba = it.javaClass.simpleName }\n',
         '                }.onFailure {\n'
         '                    if (bezi) {\n'
         '                        chyba = it.javaClass.simpleName + ": " + (it.message ?: "network error")\n'
         '                        android.util.Log.e("PlayCaptionIPhone", "UDP receiver failed", it)\n'
         '                    }\n'
         '                }\n')

    service = root / "app/src/main/java/cz/titulky/tv/PrijemService.kt"
    before = '        /** Běží režim "titulky z telefonu"? */\n'
    after = '''        /** TV-only diagnostics: first packet, source and live port errors. */
        fun statistikaPrijmu(): String {
            val instance = instance ?: return "Příjem TV: služba ještě neběží."
            val p = instance.prijimac ?: return "Příjem TV: čekám na spuštění UDP 41989."
            val error = p.chyba
            if (error != null) return "Chyba UDP 41989: $error.\\nZastav původní PlayCaption."
            val age = if (p.posledniZprava > 0L)
                ((System.currentTimeMillis() - p.posledniZprava).coerceAtLeast(0L) / 1000L).toString() + " s"
                else "dosud žádná"
            val overlays = if (OverlayService.pripravena) "připraven" else "nepřipraven"
            val hidden = if (instance.skrytyMimoVstup) " / mimo TV vstup" else ""
            return "UDP 41989 · zpráva před $age\\n" +
                "Přijaté titulky: \${p.pocetTitulku} · z \${p.posledniIP.ifEmpty { "—" }}\\n" +
                "Překryv: $overlays$hidden"
        }

''' + before
    once(service, before, after)

    activity = root / "app/src/main/java/cz/titulky/tv/MainActivity.kt"
    text = activity.read_text(encoding="utf-8")
    begin = text.index('        // tři kroky s obrázky\n', text.index('    private fun ukazPrijem() {'))
    end = text.index('        val stav = text("", 24f', begin)
    # Clear instructions: no pairing code is needed for Xbox captions on iPhone.
    slim = '''        sloupec.addView(text("iPhone + Xbox · diagnostický přijímač", 22f, Color.WHITE, tucne = true)
            .apply { gravity = Gravity.CENTER }, odsazeni(top = 14))
        sloupec.addView(text(
            "Na iPhonu otevři PlayCaption iOS a vyber IP této televize.\\n" +
            "Pro titulky z Xboxu není potřeba čtyřmístný párovací kód.", 19f, Color.WHITE
        ).apply { gravity = Gravity.CENTER }, odsazeni(top = 12))

'''
    text = text[:begin] + slim + text[end:]
    activity.write_text(text, encoding="utf-8")

    once(activity,
         '        val zpet = tlacitko(t("prijemZpetKratce"), 20f)',
         '''        val prijemDiag = text("UDP 41989: čekám na první zprávu", 18f, Color.WHITE)
            .apply { gravity = Gravity.CENTER }
        sloupec.addView(prijemDiag, odsazeni(top = 14, bottom = 10))

        // Self-test bypasses UDP; proves local OverlayService can show captions.
        val testPrekryvu = tlacitko("▶ Test překryvu TV", 21f) {
            OverlayService.posli(this, Intent(this, OverlayService::class.java)
                .setAction(OverlayService.ACTION_SET_TEXT)
                .putExtra(OverlayService.EXTRA_TEXT, "TCL C835 · TEST PŘEKRYVU TV")
                .putExtra(OverlayService.EXTRA_DOBA, 8000L)
                .putExtra(OverlayService.EXTRA_VLASTNI,
                    floatArrayOf(0.5f, 0.84f, 0.78f, 1.10f, 1f)))
        }
        sloupec.addView(testPrekryvu, odsazeni(top = 8, bottom = 8))

        val zpet = tlacitko(t("prijemZpetKratce"), 20f)''')
    once(activity, '        zpet.requestFocus()\n\n        var bylPripojen = ',
         '        testPrekryvu.requestFocus()\n\n        var bylPripojen = ')
    once(activity,
         '                stav.text = Texty.spojeni(nast.jazykNeboCs, prijem)\n',
         '                stav.text = Texty.spojeni(nast.jazykNeboCs, prijem)\n'
         '                prijemDiag.text = PrijemService.statistikaPrijmu()\n')
    once(activity,
         '                if (prijem.uroven == UrovenSpojeni.OK && !bylPripojen) moveTaskToBack(true)\n',
         '                // Keep this diagnostic waiting screen visible even after first packet.\n')
    print("PlayCaption iPhone TV receiver patch ready: separate APK; original PlayCaption untouched.")


if __name__ == "__main__":
    main()

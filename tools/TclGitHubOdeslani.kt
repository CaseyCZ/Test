package cz.titulky.tv

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Manual GitHub issue compose. No server, no embedded credentials, no background
 * uploads. The user checks the public issue and explicitly submits it on GitHub.
 */
internal object TclGitHubOdeslani {
    private const val PREFIX = "[TCLDBG pid="
    private val ALLOWED = listOf(
        "[INPUT]", "[RP ", "[RTC]", "[OVERLAY", "[TV RECEIVE", "[ONLINE CONFIG]", "[UI ", "[EXIT HISTORY]", "[SEND]"
    )

    private fun vyberLog(a: Activity): String {
        val f = File(a.filesDir, "tcl835-diagnostic.log")
        if (!f.isFile) return ""
        val ud = runCatching {
            f.readLines().filter { line ->
                line.contains(PREFIX) &&
                    ALLOWED.any { marker -> line.contains(marker) } &&
                    line.length < 600
            }.takeLast(120)
        }.getOrDefault(emptyList())
        if (ud.isEmpty()) return ""

        // A simple tail can drop the actual HDMI switch / crash and leave
        // only healthy frame counters. Reserve space for exceptional events.
        val vybrane = linkedSetOf<Int>()
        var vyuzito = 0
        fun vloz(i: Int, limit: Int) {
            if (vybrane.contains(i)) return
            val len = ud[i].take(300).length + 1
            if (vyuzito + len <= limit) {
                vybrane.add(i)
                vyuzito += len
            }
        }
        fun jeDulezity(s: String) =
            s.contains("[UI ") || s.contains("[EXIT HISTORY]") ||
            s.contains("[RTC] [Xbox] ICE:") ||
            s.contains("[RTC] [Xbox] konzole ukončila") ||
            s.contains("[RP DESTROY]") || s.contains("[RP CREATE]") ||
            s.contains("[RP TASK REMOVED]") || s.contains("[OVERLAY DESTROY]") ||
            s.contains("[INPUT]")

        // Reserve 2.5 KB for pause, resumption, exit reasons and ICE status.
        for (i in ud.indices.reversed()) if (jeDulezity(ud[i])) vloz(i, 2500)
        // Remaining 1.4 KB: last frame progress and connection state.
        for (i in ud.indices.reversed()) vloz(i, 3900)

        return vybrane.sorted().joinToString("\n") { ud[it].take(300) }
    }

    fun otevri(a: Activity) {
        TclDiagnostika.zapis(a, "[SEND] GitHub issue opened; activeRemotePlay=" +
            RemotePlayService.aktivni + " " + TclDiagnostika.system(a))
        val log = vyberLog(a)
        if (log.isBlank()) {
            Toast.makeText(a, "Nejprve proveď test HDMI, zatím není co odeslat.",
                Toast.LENGTH_LONG).show()
            return
        }
        val time = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).format(Date())
        val title = "TCL C835 – HDMI 2 / Xbox Remote Play – diagnostika $time"
        val preamble = """## TCL Caption GPU TEST – HDMI 2

Tento veřejný GitHub issue obsahuje pouze vybrané technické záznamy.
Neobsahuje snímky obrazovky, text titulků ani údaje Xbox účtu.

**Příznak:** přepnutí Google TV na HDMI 2, výpadek Remote Play nebo titulků.
**Odesláno z:** TCL C835 (testovací APK)

**Technický záznam:**
"""
        val body = preamble + "\n" +
            log.lines().joinToString("\n") { "    " + it } + "\n"
        val uri = Uri.parse("https://github.com/CaseyCZ/Test/issues/new")
            .buildUpon()
            .appendQueryParameter("title", title)
            .appendQueryParameter("body", body)
            .build()
        val intent = Intent(Intent.ACTION_VIEW, uri)
            .addCategory(Intent.CATEGORY_BROWSABLE)
        try {
            a.startActivity(intent)
            Toast.makeText(a, "Na GitHubu potvrď vytvoření veřejného issue.",
                Toast.LENGTH_LONG).show()
        } catch (e: ActivityNotFoundException) {
            Toast.makeText(a, "V TV není prohlížeč. Pro odeslání je potřeba prohlížeč GitHub.",
                Toast.LENGTH_LONG).show()
        } catch (e: Exception) {
            Toast.makeText(a, "GitHub se nepodařilo otevřít.",
                Toast.LENGTH_LONG).show()
        }
    }
}

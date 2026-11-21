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
        "[INPUT]", "[RP ", "[RTC]", "[OVERLAY", "[TV RECEIVE", "[SELF TEST]", "[ONLINE CONFIG]"
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

        // Short issue URLs work more reliably on Android TV web browsers.
        // Keep newest diagnostic events, in chronological order.
        val kept = ArrayList<String>()
        var size = 0
        for (line in ud.asReversed()) {
            val clean = line.take(300)
            if (size + clean.length + 1 > 3900) break
            kept.add(clean)
            size += clean.length + 1
        }
        kept.reverse()
        return kept.joinToString("\n")
    }

    fun otevri(a: Activity) {
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

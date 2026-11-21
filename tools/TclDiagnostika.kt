package cz.titulky.tv

import android.content.Context
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Isolated diagnostics for the TCL C835 test build.
 * No tokens, account data, IP addresses or subtitle texts are recorded here.
 * Each process has a new session ID so silent process termination can be spotted.
 */
internal object TclDiagnostika {
    private val relace = java.lang.Long.toHexString(SystemClock.elapsedRealtimeNanos())
    private const val LIMIT_BYTES = 900_000L

    @Synchronized
    fun zapis(ctx: Context, udalost: String) {
        val cas = SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date())
        val radek = cas + " [TCLDBG pid=" + Process.myPid() +
            " sid=" + relace + " uptimeMs=" + SystemClock.elapsedRealtime() + "] " + udalost
        Log.i("TCLCaptionDiag", radek)
        runCatching {
            val soubor = File(ctx.filesDir, "tcl835-diagnostic.log")
            if (soubor.length() > LIMIT_BYTES) {
                soubor.writeText("[TCLDBG] Log rotated after reaching size limit\n")
            }
            soubor.appendText(radek + "\n")
        }
    }

    /**
     * On next Activity launch, ask Android whether it killed the previous process.
     * API 30+ returns reasons even if onDestroy was never called.
     * No private trace or device identifiers are exported.
     */
    fun historieUkonceni(ctx: Context) {
        if (android.os.Build.VERSION.SDK_INT < 30) {
            zapis(ctx, "[EXIT HISTORY] unavailable (Android < 11)")
            return
        }
        runCatching {
            val pref = ctx.getSharedPreferences("tcl_hdmi_exit", Context.MODE_PRIVATE)
            val previous = pref.getLong("last_exit_recorded", 0L)
            val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            val exits = am.getHistoricalProcessExitReasons(ctx.packageName, 0, 10)
                .filter { it.timestamp > previous && it.timestamp <= System.currentTimeMillis() }
                .sortedBy { it.timestamp }
            if (exits.isEmpty()) {
                zapis(ctx, "[EXIT HISTORY] no new Android process termination recorded")
            } else {
                for (item in exits.takeLast(5)) {
                    zapis(ctx, "[EXIT HISTORY] timeMs=" + item.timestamp +
                        " reasonCode=" + item.reason + " status=" + item.status +
                        " importance=" + item.importance)
                }
                pref.edit().putLong("last_exit_recorded", exits.last().timestamp).apply()
            }
        }.onFailure { e ->
            zapis(ctx, "[EXIT HISTORY] unavailable " + e.javaClass.simpleName)
        }
    }

    fun system(ctx: Context): String = runCatching {
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        "interactive=" + pm.isInteractive +
            " powerSave=" + pm.isPowerSaveMode +
            " overlayPermission=" + android.provider.Settings.canDrawOverlays(ctx)
    }.getOrDefault("systemState=unavailable")
}

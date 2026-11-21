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

    fun system(ctx: Context): String = runCatching {
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        "interactive=" + pm.isInteractive +
            " powerSave=" + pm.isPowerSaveMode +
            " overlayPermission=" + android.provider.Settings.canDrawOverlays(ctx)
    }.getOrDefault("systemState=unavailable")
}

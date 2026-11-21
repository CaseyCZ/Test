package cz.titulky.tv

import android.content.Context
import android.os.SystemClock
import org.json.JSONObject
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

/**
 * Remote settings only for an explicitly installed TCL diagnostic APK.
 * Downloads a small JSON document from the owner's public GitHub repository.
 * Never executes downloaded code and never sends diagnostic data automatically.
 * Settings remain in memory if a refresh fails.
 */
internal object TclOnlineNastaveni {
    private const val ADRESA = "https://raw.githubusercontent.com/CaseyCZ/Test/Master/config/tcl835.json"
    private const val OBNOVA_MS = 60_000L
    private val nacitam = AtomicBoolean(false)
    @Volatile private var kontrolaKdy = -OBNOVA_MS

    @Volatile var intervalLoguSekund = 5
        private set
    @Volatile var vynutitPrekryv = true
        private set
    @Volatile var zamykatCpu = true
        private set
    @Volatile var dekoderBezGpu = true
        private set
    @Volatile var revize = 0
        private set

    fun obnov(ctx: Context) {
        val ted = SystemClock.elapsedRealtime()
        if (ted - kontrolaKdy < OBNOVA_MS || !nacitam.compareAndSet(false, true)) return
        kontrolaKdy = ted
        val app = ctx.applicationContext
        Thread({
            try {
                val url = URL(ADRESA + "?_=" + (System.currentTimeMillis() / OBNOVA_MS))
                val c = url.openConnection() as HttpsURLConnection
                c.connectTimeout = 5000
                c.readTimeout = 5000
                c.instanceFollowRedirects = false
                c.setRequestProperty("Cache-Control", "no-cache")
                try {
                    if (c.responseCode != 200) error("HTTP " + c.responseCode)
                    val raw = c.inputStream.bufferedReader().use { it.readText() }
                    if (raw.length > 4096) error("Config too large")
                    val json = JSONObject(raw)
                    if (json.optInt("schema", -1) != 1) error("Unknown schema")
                    val interval = json.optInt("traceIntervalSeconds", 5).coerceIn(5, 60)
                    val prekryv = json.optBoolean("forceHdmiOverlay", true)
                    val cpu = json.optBoolean("keepCpuAwake", true)
                    val decoder = when (json.optString("decoderMode", "no_gpu")) {
                        "default" -> false
                        "no_gpu" -> true
                        else -> error("Unknown decoderMode")
                    }
                    val zmena = intervalLoguSekund != interval ||
                        vynutitPrekryv != prekryv || zamykatCpu != cpu ||
                        dekoderBezGpu != decoder
                    intervalLoguSekund = interval
                    vynutitPrekryv = prekryv
                    zamykatCpu = cpu
                    dekoderBezGpu = decoder
                    if (zmena) revize++
                    TclDiagnostika.zapis(app, "[ONLINE CONFIG] loaded changed=" + zmena +
                        " intervalSec=" + interval + " overlayOverride=" + prekryv +
                        " cpuLock=" + cpu + " decoderNoGpu=" + decoder +
                        " (decoder takes effect on next connection)")
                } finally {
                    c.disconnect()
                }
            } catch (e: Exception) {
                TclDiagnostika.zapis(app,
                    "[ONLINE CONFIG] refresh failed: " + e.javaClass.simpleName +
                    "; keeping previous settings")
            } finally {
                nacitam.set(false)
            }
        }, "tcl-online-config").apply { isDaemon = true }.start()
    }
}

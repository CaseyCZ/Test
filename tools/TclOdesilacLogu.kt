package cz.titulky.tv

import android.content.Context
import android.os.SystemClock
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URL
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Signature
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

/**
 * Optional opt-in diagnostic sender. Sends ONLY the dedicated TCL diagnostic
 * log, never Xbox authentication, subtitles, raw screen, or old application logs.
 *
 * Each install holds a non-exportable signing key in Android Keystore.
 * The private key NEVER leaves the device. The collector must explicitly allow
 * pairing before the first request from the TV will be accepted.
 */
internal object TclOdesilacLogu {
    private const val KLIC = "tcl835-diagnostic-upload-key"
    private const val MIN_INTERVAL_MS = 60_000L
    private val odesilam = AtomicBoolean(false)
    @Volatile private var posledniPokus = -MIN_INTERVAL_MS
    @Volatile private var posledniOtisk = ""
    @Volatile private var posledniUrgentniPokus = -60_000L

    fun zkusOdeslat(ctx: Context, urgent: Boolean = false) {
        if (!TclOnlineNastaveni.logUploadEnabled) return
        val endpoint = TclOnlineNastaveni.logUploadEndpoint
        if (!endpoint.startsWith("https://")) return

        val ted = SystemClock.elapsedRealtime()
        // Force one useful end-of-session report, but never flood the collector.
        if (urgent) {
            if (ted - posledniUrgentniPokus < MIN_INTERVAL_MS) return
            posledniUrgentniPokus = ted
        } else if (ted - posledniPokus < MIN_INTERVAL_MS) return
        if (!odesilam.compareAndSet(false, true)) return
        posledniPokus = ted
        val app = ctx.applicationContext
        Thread({
            try {
                val f = File(app.filesDir, "tcl835-diagnostic.log")
                if (!f.isFile) return@Thread
                val vsechny = f.readLines()
                // No raw external application logs or secrets are ever uploaded.
                val lines = vsechny.filter { radek ->
                    radek.contains("[TCLDBG") && listOf(
                        "[INPUT]", "[RP ", "[RTC]", "[OVERLAY", "[TV RECEIVE", "[ONLINE CONFIG]"
                    ).any { radek.contains(it) }
                }.takeLast(140).map { it.take(450) }
                if (lines.isEmpty()) return@Thread
                val otisk = hash(lines.joinToString("\n").toByteArray(Charsets.UTF_8))
                if (otisk == posledniOtisk) return@Thread
                val pair = klic()
                val publicKey = pair.public.encoded
                val deviceId = hash(publicKey).take(24)
                val payload = JSONObject()
                    .put("schema", 1)
                    .put("sentAtMs", System.currentTimeMillis())
                    .put("lines", JSONArray(lines)).toString().toByteArray(Charsets.UTF_8)
                val signer = Signature.getInstance("SHA256withECDSA")
                signer.initSign(pair.private)
                signer.update(payload)
                val packet = JSONObject()
                    .put("deviceId", deviceId)
                    .put("publicKey", Base64.encodeToString(publicKey, Base64.NO_WRAP))
                    .put("bodyBase64", Base64.encodeToString(payload, Base64.NO_WRAP))
                    .put("signature", Base64.encodeToString(signer.sign(), Base64.NO_WRAP))
                    .toString().toByteArray(Charsets.UTF_8)
                if (packet.size > 80_000) error("Diagnostic packet too large")
                val target = URL(endpoint)
                if (target.protocol != "https" || target.userInfo != null ||
                    target.ref != null || target.query != null ||
                    target.path != "/v1/logs") {
                    error("Invalid configured diagnostic endpoint")
                }
                val connection = target.openConnection() as HttpsURLConnection
                connection.connectTimeout = 5000
                connection.readTimeout = 5000
                connection.instanceFollowRedirects = false
                connection.requestMethod = "POST"
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.setRequestProperty("Cache-Control", "no-store")
                connection.setFixedLengthStreamingMode(packet.size)
                try {
                    connection.outputStream.use { it.write(packet) }
                    if (connection.responseCode in 200..299) {
                        posledniOtisk = otisk
                        TclDiagnostika.zapis(app, "[UPLOAD] confirmed HTTPS upload (deviceId=" +
                            deviceId + ", count=" + lines.size + ")")
                    } else {
                        TclDiagnostika.zapis(app, "[UPLOAD] HTTP " + connection.responseCode +
                            "; retained local log")
                    }
                } finally {
                    connection.disconnect()
                }
            } catch (e: Exception) {
                TclDiagnostika.zapis(app, "[UPLOAD] " + e.javaClass.simpleName +
                    "; retained local log")
            } finally {
                odesilam.set(false)
            }
        }, "tcl-log-upload").apply { isDaemon = true }.start()
    }

    private fun klic(): KeyPair {
        val store = KeyStore.getInstance("AndroidKeyStore")
        store.load(null)
        if (!store.containsAlias(KLIC)) {
            val generator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            generator.initialize(KeyGenParameterSpec.Builder(
                KLIC, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setAlgorithmParameterSpec(java.security.spec.ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .build())
            generator.generateKeyPair()
        }
        val privateKey = store.getKey(KLIC, null) as java.security.PrivateKey
        val publicKey = store.getCertificate(KLIC).publicKey
        return KeyPair(publicKey, privateKey)
    }

    private fun hash(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
}

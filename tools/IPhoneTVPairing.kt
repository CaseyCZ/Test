package cz.titulky.tv

import android.content.Context
import android.os.SystemClock
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Local-only iPhone -> TV pairing. NEVER transfers Xbox or Microsoft credentials.
 * Six-digit PIN authorizes a unique per-phone secret; signed heartbeats and
 * subtitles prove that the saved phone still knows that secret.
 * Transport is local UDP, not encrypted. Only use on a trusted home network.
 */
object IPhoneTVPairing {
    private val random = SecureRandom()
    private val lock = Any()
    @Volatile private var code: String? = null
    @Volatile private var expiresAtMs = 0L
    @Volatile private var attempts = 0
    @Volatile var lastAuthenticatedMs = 0L
        private set

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences("playcaption_iphone_receiver", Context.MODE_PRIVATE)

    fun startCode(): String = synchronized(lock) {
        val pin = (random.nextInt(900_000) + 100_000).toString()
        code = pin
        expiresAtMs = SystemClock.elapsedRealtime() + 180_000L
        attempts = 0
        pin
    }

    fun remainingSeconds(): Int = synchronized(lock) {
        if (code == null) 0
        else ((expiresAtMs - SystemClock.elapsedRealtime()).coerceAtLeast(0L) / 1000L).toInt()
    }

    /** Returns a 32-byte secret (hex) only after PIN succeeds. */
    fun confirm(ctx: Context, input: String, phoneId: String): String? = synchronized(lock) {
        val valid = input.length == 6 && input.all { it.isDigit() } &&
            phoneId.length in 8..90 &&
            code != null && SystemClock.elapsedRealtime() < expiresAtMs &&
            attempts < 5
        if (!valid) return@synchronized null
        attempts += 1
        if (input != code) {
            if (attempts >= 5) code = null
            return@synchronized null
        }
        val bytes = ByteArray(32).also(random::nextBytes)
        val token = bytes.joinToString("") { "%02x".format(it) }
        prefs(ctx).edit().putString("phone_id", phoneId)
            .putString("token", token).apply()
        code = null
        expiresAtMs = 0
        attempts = 0
        lastAuthenticatedMs = SystemClock.elapsedRealtime()
        token
    }

    fun paired(ctx: Context): Boolean = !prefs(ctx).getString("token", null).isNullOrBlank()

    fun clear(ctx: Context) = synchronized(lock) {
        prefs(ctx).edit().clear().apply()
        lastAuthenticatedMs = 0L
        code = null
        expiresAtMs = 0L
    }

    fun verify(ctx: Context, phoneId: String, content: String, signatureHex: String): Boolean {
        val p = prefs(ctx)
        if (p.getString("phone_id", "") != phoneId ||
            phoneId.isBlank() || signatureHex.length != 64) return false
        val keyHex = p.getString("token", null) ?: return false
        val key = hexBytes(keyHex) ?: return false
        val expected = Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(key, "HmacSHA256"))
            doFinal(content.toByteArray(Charsets.UTF_8))
        }
        val received = hexBytes(signatureHex) ?: return false
        val ok = MessageDigest.isEqual(expected, received)
        if (ok) lastAuthenticatedMs = SystemClock.elapsedRealtime()
        return ok
    }

    fun connectedRecently(): Boolean =
        lastAuthenticatedMs > 0 &&
            SystemClock.elapsedRealtime() - lastAuthenticatedMs < 10_000L

    private fun hexBytes(hex: String): ByteArray? = try {
        if (hex.length % 2 != 0) null
        else ByteArray(hex.length / 2) { i ->
            hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
    } catch (_: Exception) { null }
}

package com.alertaciudadana.alerta_ciudadana

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Almacén nativo y cifrado del token JWT del ciudadano.
 *
 * Motivo: Dart guarda el token en flutter_secure_storage, que el servicio
 * nativo de emergencias (EmergencyForegroundService) no puede leer cuando la
 * interfaz de Flutter está cerrada. Dart le pasa el token por el
 * MethodChannel al iniciar sesión / al arrancar, y aquí se guarda cifrado con
 * una clave AES-256-GCM del Android Keystore (no exportable).
 *
 * Si el descifrado falla (p. ej. datos restaurados de una copia de seguridad
 * en otro teléfono, donde la clave del Keystore no existe), se devuelve null y
 * se borra el valor: el usuario deberá iniciar sesión de nuevo.
 */
object SecureSessionStore {
    private const val KEY_ALIAS = "alerta_session_token_key"
    private const val PREFS = "alerta_secure_session"
    private const val PREF_TOKEN = "jwt"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128

    private fun getOrCreateKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    fun saveToken(context: Context, token: String): Boolean {
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
            val ciphertext = cipher.doFinal(token.toByteArray(Charsets.UTF_8))
            val blob = cipher.iv + ciphertext
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(PREF_TOKEN, Base64.encodeToString(blob, Base64.NO_WRAP))
                .apply()
            true
        } catch (_: Exception) {
            false
        }
    }

    fun getToken(context: Context): String? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = prefs.getString(PREF_TOKEN, null) ?: return null
        return try {
            val blob = Base64.decode(stored, Base64.NO_WRAP)
            if (blob.size <= IV_BYTES) return null
            val iv = blob.copyOfRange(0, IV_BYTES)
            val ciphertext = blob.copyOfRange(IV_BYTES, blob.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(TAG_BITS, iv))
            String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        } catch (_: Exception) {
            prefs.edit().remove(PREF_TOKEN).apply()
            null
        }
    }

    fun hasToken(context: Context): Boolean = !getToken(context).isNullOrEmpty()

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(PREF_TOKEN).apply()
    }
}

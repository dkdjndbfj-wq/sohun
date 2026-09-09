package top.sohun.consumable_tracker

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.AtomicFile
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-only authenticated encrypted storage. No dump/key/exception logging. */
class AmsTemplateVault(context: Context) : MethodChannel.MethodCallHandler {
    private val directory = File(context.applicationContext.noBackupFilesDir, "sohun_rfid_template_vault_v1")
    // Read-only compatibility with the first local development implementation.
    // Successful migration removes its ciphertext only after the atomic file is durable.
    private val legacyPreferences = context.applicationContext.getSharedPreferences(
        "sohun_rfid_template_vault_v1", Context.MODE_PRIVATE
    )

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in setOf("listTemplates", "readTemplate", "saveTemplate", "deleteTemplate")) {
            result.notImplemented()
            return
        }
        try {
            val arguments = call.arguments as? Map<*, *> ?: throw InvalidTemplate()
            val owner = (arguments["ownerAccount"] as? String ?: throw InvalidTemplate())
                .trim().lowercase(Locale.ROOT)
            if (owner.length > 320 || owner.any { it.code < 32 || it.code == 127 }) throw InvalidTemplate()
            val prefix = "v1.${hex(sha256(owner.toByteArray(Charsets.UTF_8)))}."
            // All channels/activities share one lock: quota checks and writes are atomic.
            val response = synchronized(lock) {
                if (call.method != "deleteTemplate") migrateLegacy()
                when (call.method) {
                    "listTemplates" -> {
                        val entries = allEntries().filterKeys { it.startsWith(prefix) }
                        if (entries.size > MAX_PER_OWNER) throw InvalidTemplate()
                        entries.toSortedMap().map { (storageKey, value) ->
                            decode(storageKey, value)
                        }
                    }
                    "readTemplate" -> {
                        val id = validateId(arguments["id"])
                        val storageKey = prefix + id
                        readEncrypted(storageKey)?.let { decode(storageKey, it) }
                    }
                    "saveTemplate" -> {
                        val template = canonicalize(arguments["template"] as? Map<*, *> ?: throw InvalidTemplate())
                        val storageKey = prefix + template.getValue("id")
                        val all = allEntries()
                        if (!all.containsKey(storageKey) && all.keys.count { it.startsWith(prefix) } >= MAX_PER_OWNER) {
                            throw VaultFull()
                        }
                        val clear = JSONObject(template).toString().toByteArray(Charsets.UTF_8)
                        if (clear.size > MAX_CLEAR_BYTES) throw InvalidTemplate()
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
                        cipher.updateAAD(storageKey.toByteArray(Charsets.UTF_8))
                        val encrypted = try {
                            Base64.encodeToString(cipher.iv + cipher.doFinal(clear), Base64.NO_WRAP)
                        } finally {
                            clear.fill(0)
                        }
                        val total = all.entries.filter { it.key != storageKey }.sumOf {
                            it.key.length.toLong() + it.value.length
                        } + storageKey.length + encrypted.length
                        if (total > MAX_TOTAL_BYTES) throw VaultFull()
                        writeEncrypted(storageKey, encrypted)
                        null
                    }
                    else -> {
                        val id = validateId(arguments["id"])
                        val storageKey = prefix + id
                        atomicFile(storageKey).delete()
                        if (File(directory, storageKey).exists() || File(directory, "$storageKey.bak").exists()) throw VaultUnavailable()
                        if (!legacyPreferences.edit().remove(storageKey).commit()) throw VaultUnavailable()
                        null
                    }
                }
            }
            result.success(response)
        } catch (_: VaultFull) {
            result.error("TEMPLATE_VAULT_FULL", "本机模板库已满，请删除不再使用的模板。", null)
        } catch (_: InvalidTemplate) {
            result.error("TEMPLATE_INVALID", "模板内容无效或本机数据损坏，请重新导入原始文件。", null)
        } catch (_: Exception) {
            // An Android backup restored without its non-exportable key must fail
            // closed. Never silently replace a key or fall back to plaintext.
            result.error("TEMPLATE_VAULT_UNAVAILABLE", "无法打开手机加密模板库，请重新导入原始模板。", null)
        }
    }

    private fun atomicFile(storageKey: String): AtomicFile {
        if (!STORAGE_KEY.matches(storageKey)) throw InvalidTemplate()
        return AtomicFile(File(directory, storageKey))
    }

    private fun allEntries(): Map<String, String> {
        if (!directory.exists()) return emptyMap()
        val files = directory.listFiles() ?: throw VaultUnavailable()
        if (files.size > 1024) throw VaultFull()
        // AtomicFile can retain a .bak after a killed process; readFully restores
        // it. Incomplete .new files are never imported as a successful record.
        val names = files.map { it.name.removeSuffix(".bak") }.filter { STORAGE_KEY.matches(it) }.toSet()
        return names.associateWith { readEncrypted(it) ?: throw VaultUnavailable() }
    }

    private fun readEncrypted(storageKey: String): String? {
        val base = File(directory, storageKey)
        val backup = File(directory, "$storageKey.bak")
        if (!base.exists() && !backup.exists()) return null
        if (base.length() > MAX_CIPHER_CHARS || backup.length() > MAX_CIPHER_CHARS) throw InvalidTemplate()
        val content = atomicFile(storageKey).readFully()
        if (content.size > MAX_CIPHER_CHARS) throw InvalidTemplate()
        return String(content, Charsets.US_ASCII)
    }

    private fun writeEncrypted(storageKey: String, encrypted: String) {
        if (encrypted.length > MAX_CIPHER_CHARS) throw InvalidTemplate()
        if (!directory.exists() && !directory.mkdirs()) throw VaultUnavailable()
        if (!directory.isDirectory) throw VaultUnavailable()
        val file = atomicFile(storageKey)
        val stream = file.startWrite()
        try {
            stream.write(encrypted.toByteArray(Charsets.US_ASCII))
            file.finishWrite(stream)
        } catch (error: Exception) {
            file.failWrite(stream)
            throw error
        }
        if (readEncrypted(storageKey) != encrypted) throw VaultUnavailable()
    }

    private fun migrateLegacy() {
        for ((storageKey, value) in legacyPreferences.all) {
            if (!STORAGE_KEY.matches(storageKey)) throw InvalidTemplate()
            val encrypted = value as? String ?: throw InvalidTemplate()
            decode(storageKey, encrypted)
            val existing = readEncrypted(storageKey)
            if (existing == null) {
                val entries = allEntries()
                val ownerPrefix = storageKey.substringBeforeLast('.') + "."
                if (entries.keys.count { it.startsWith(ownerPrefix) } >= MAX_PER_OWNER ||
                    entries.entries.sumOf { it.key.length.toLong() + it.value.length } +
                    storageKey.length + encrypted.length > MAX_TOTAL_BYTES) throw VaultFull()
                writeEncrypted(storageKey, encrypted)
            } else {
                // A previously migrated or renamed file wins; do not overwrite it.
                decode(storageKey, existing)
            }
            if (!legacyPreferences.edit().remove(storageKey).commit()) throw VaultUnavailable()
        }
    }

    private fun decode(storageKey: String, encrypted: String): Map<String, Any> {
        if (encrypted.length > MAX_CIPHER_CHARS) throw InvalidTemplate()
        val payload = Base64.decode(encrypted, Base64.NO_WRAP)
        if (payload.size < 28 || payload.size > MAX_CLEAR_BYTES + 28) throw InvalidTemplate()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(create = false), GCMParameterSpec(128, payload.copyOfRange(0, 12)))
        cipher.updateAAD(storageKey.toByteArray(Charsets.UTF_8))
        val clear = cipher.doFinal(payload, 12, payload.size - 12)
        val json = try { JSONObject(String(clear, Charsets.UTF_8)) } finally { clear.fill(0) }
        val blocks = json.optJSONArray("blocks") ?: throw InvalidTemplate()
        val map = canonicalize(mapOf(
            "format" to json.optString("format"), "version" to json.optInt("version"),
            "id" to json.optString("id"), "uid" to json.optString("uid"),
            "name" to json.optString("name"),
            "blocks" to (0 until blocks.length()).map { blocks.optString(it) }
        ))
        if (!storageKey.endsWith(".${map.getValue("id")}")) throw InvalidTemplate()
        return map
    }

    private fun canonicalize(input: Map<*, *>): Map<String, Any> {
        if (input["format"] != "sohun.ams-template" || input["version"] != 1) throw InvalidTemplate()
        val id = validateId(input["id"])
        val uid = (input["uid"] as? String)?.uppercase(Locale.ROOT) ?: throw InvalidTemplate()
        val name = (input["name"] as? String)?.trim() ?: throw InvalidTemplate()
        if (!uid.matches(Regex("[0-9A-F]{8}")) || name.isEmpty() || name.length > 80 ||
            name.any { it.code < 32 || it.code == 127 }) throw InvalidTemplate()
        val values = input["blocks"] as? List<*> ?: throw InvalidTemplate()
        if (values.size != 64) throw InvalidTemplate()
        val bytes = ByteArray(1024)
        val blocks = values.mapIndexed { index, value ->
            val block = (value as? String)?.uppercase(Locale.ROOT) ?: throw InvalidTemplate()
            if (!block.matches(Regex("[0-9A-F]{32}"))) throw InvalidTemplate()
            for (offset in 0 until 16) bytes[index * 16 + offset] = block.substring(offset * 2, offset * 2 + 2).toInt(16).toByte()
            block
        }
        try {
            if (hex(sha256(bytes)) != id || blocks[0].substring(0, 8) != uid || uid == "00000000" || uid == "FFFFFFFF") throw InvalidTemplate()
            if ((bytes[0].toInt() xor bytes[1].toInt() xor bytes[2].toInt() xor bytes[3].toInt()).toByte() != bytes[4]) throw InvalidTemplate()
            for (sector in 0 until 16) {
                val offset = (sector * 4 + 3) * 16
                val b6 = bytes[offset + 6].toInt() and 255
                val b7 = bytes[offset + 7].toInt() and 255
                val b8 = bytes[offset + 8].toInt() and 255
                if (((b6 and 15) xor (b7 shr 4)) != 15 || ((b6 shr 4) xor (b8 and 15)) != 15 ||
                    ((b7 and 15) xor (b8 shr 4)) != 15) throw InvalidTemplate()
            }
            val signature = (40 until 64).filter { it % 4 != 3 }.flatMap { block ->
                bytes.slice(block * 16 until block * 16 + 16)
            }
            if (signature.all { it == 0.toByte() } || signature.all { it == 255.toByte() } ||
                bytes.slice(144 until 160).all { it == 0.toByte() }) throw InvalidTemplate()
            return mapOf("format" to "sohun.ams-template", "version" to 1, "id" to id,
                "uid" to uid, "name" to name, "blocks" to blocks)
        } finally {
            bytes.fill(0)
        }
    }

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey(KEY_ALIAS, null)
        if (existing is SecretKey) return existing
        if (!create) throw VaultUnavailable()
        // Never create a replacement key while encrypted records remain.
        if (allEntries().isNotEmpty() || legacyPreferences.all.isNotEmpty()) throw VaultUnavailable()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build())
            generateKey()
        }
    }

    private fun validateId(value: Any?): String = (value as? String)?.takeIf {
        it.matches(Regex("[0-9a-f]{64}"))
    } ?: throw InvalidTemplate()

    private fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 255) }
    private class InvalidTemplate : Exception()
    private class VaultFull : Exception()
    private class VaultUnavailable : Exception()

    companion object {
        const val CHANNEL = "top.sohun/rfid_template_vault"
        private const val KEY_ALIAS = "sohun.rfid_template_vault.aes.v1"
        private const val MAX_PER_OWNER = 128
        private const val MAX_CLEAR_BYTES = 16384
        private const val MAX_CIPHER_CHARS = 22000
        private const val MAX_TOTAL_BYTES = 2L * 1024 * 1024
        private val STORAGE_KEY = Regex("v1\\.[0-9a-f]{64}\\.[0-9a-f]{64}")
        private val lock = Any()
    }
}

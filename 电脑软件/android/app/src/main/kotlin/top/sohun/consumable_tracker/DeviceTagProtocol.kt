package top.sohun.consumable_tracker

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

internal class DeviceTagFailure(val code: String, override val message: String) : Exception(message)

/** Only an opaque device locator may cross the device-tag boundary. */
internal object DeviceTagProtocol {
    const val PACKAGE_NAME = "top.sohun.consumable_tracker"
    private val tokenPattern = Regex("[0-9a-f]{32}")
    private val uriPattern = Regex("(?:https://sohun\\.top/device/|sohun://device/)([0-9a-f]{32})")
    private val version213 = byteArrayOf(0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03)

    fun tokenFromUri(value: String): String? = uriPattern.matchEntire(value)?.groupValues?.get(1)

    fun uriFor(token: String): String {
        if (!tokenPattern.matches(token)) {
            throw DeviceTagFailure("INVALID_PAYLOAD", "设备标签标识格式无效")
        }
        return "https://sohun.top/device/$token"
    }

    fun validateTag(probe: DeviceTagProbe) {
        if (!version213.contentEquals(probe.version) ||
            !Regex("[0-9A-F]{14}").matches(probe.tagId)) {
            throw DeviceTagFailure("UNSUPPORTED_TAG", "设备快捷标签仅支持 NTAG213；耗材卡请使用 CUID/FUID 工具")
        }
    }

    fun validateWritable(probe: DeviceTagProbe) {
        validateTag(probe)
        val head = probe.header
        val tail = probe.configuration
        if (head.size != 16 || tail.size != 16) {
            throw DeviceTagFailure("READ_FAILED", "未能完整读取标签写入状态")
        }
        // NTAG213: static locks at page 2; dynamic locks at page 40;
        // AUTH0 at page 41 byte 3. Never modify locks, passwords or UID pages.
        if (head[10] != 0.toByte() || head[11] != 0.toByte() ||
            tail.take(3).any { it != 0.toByte() } ||
            (tail[7].toInt() and 0xFF) != 0xFF ||
            (head[15].toInt() and 0x0F) != 0) {
            throw DeviceTagFailure("TAG_LOCKED", "标签已锁定或受密码保护，请换用可写的 NTAG213")
        }
        if ((head[12].toInt() and 0xFF) != 0xE1 ||
            (head[13].toInt() and 0xF0) != 0x10 ||
            (head[14].toInt() and 0xFF) != 0x12 ||
            head[15] != 0.toByte()) {
            throw DeviceTagFailure("UNSUPPORTED_FORMAT", "标签不是标准 NTAG213 NDEF 格式，请换用标准空白标签")
        }
    }

    /** Standard URI record followed by the Android Application Record when it fits. */
    fun encode(token: String, capacity: Int): ByteArray {
        val uri = uriFor(token)
        val uriPayload = byteArrayOf(0x04) + uri.removePrefix("https://").toByteArray(StandardCharsets.UTF_8)
        val applicationType = "android.com:pkg".toByteArray(StandardCharsets.US_ASCII)
        val application = PACKAGE_NAME.toByteArray(StandardCharsets.US_ASCII)
        val withApp = record(0x91, byteArrayOf(0x55), uriPayload) +
            record(0x54, applicationType, application)
        if (withApp.size <= capacity) return withApp
        val onlyUri = record(0xD1, byteArrayOf(0x55), uriPayload)
        if (onlyUri.size > capacity) {
            throw DeviceTagFailure("TAG_CAPACITY", "标签可写容量不足，未写入设备入口")
        }
        return onlyUri
    }

    private fun record(header: Int, type: ByteArray, payload: ByteArray): ByteArray =
        byteArrayOf(header.toByte(), type.size.toByte(), payload.size.toByte()) + type + payload

    /** Reject unrelated records, extra payloads, malformed messages and URI tricks. */
    fun uriFromMessage(bytes: ByteArray): String? {
        if (bytes.isEmpty() || bytes.size > 144) return null
        var offset = 0
        var first = true
        var ended = false
        var token: String? = null
        var applicationSeen = false
        try {
            while (offset < bytes.size) {
                if (ended || offset + 3 > bytes.size) return null
                val flags = bytes[offset++].toInt() and 0xFF
                if ((flags and 0x80 != 0) != first || flags and 0x28 != 0) return null
                val typeLength = bytes[offset++].toInt() and 0xFF
                val payloadLength = if (flags and 0x10 != 0) {
                    bytes[offset++].toInt() and 0xFF
                } else {
                    if (offset + 4 > bytes.size) return null
                    val length = ByteBuffer.wrap(bytes, offset, 4).int
                    offset += 4
                    length
                }
                if (payloadLength < 0 || payloadLength > 144 ||
                    offset + typeLength + payloadLength > bytes.size) return null
                val type = bytes.copyOfRange(offset, offset + typeLength)
                offset += typeLength
                val payload = bytes.copyOfRange(offset, offset + payloadLength)
                offset += payloadLength
                if (first) {
                    if (flags and 0x07 != 1 || !type.contentEquals(byteArrayOf(0x55)) || payload.isEmpty()) return null
                    val prefix = when (payload[0].toInt() and 0xFF) {
                        0 -> ""
                        4 -> "https://"
                        else -> return null
                    }
                    val decoder = StandardCharsets.UTF_8.newDecoder()
                        .onMalformedInput(CodingErrorAction.REPORT)
                        .onUnmappableCharacter(CodingErrorAction.REPORT)
                    val suffix = decoder.decode(ByteBuffer.wrap(payload, 1, payload.size - 1)).toString()
                    token = tokenFromUri(prefix + suffix) ?: return null
                } else {
                    if (applicationSeen || flags and 0x07 != 4 ||
                        !type.contentEquals("android.com:pkg".toByteArray(StandardCharsets.US_ASCII)) ||
                        !payload.contentEquals(PACKAGE_NAME.toByteArray(StandardCharsets.US_ASCII))) return null
                    applicationSeen = true
                }
                first = false
                ended = flags and 0x40 != 0
            }
        } catch (_: Exception) {
            return null
        }
        return if (ended && token != null) uriFor(token) else null
    }
}

internal data class DeviceTagProbe(
    val tagId: String,
    val version: ByteArray,
    val header: ByteArray = byteArrayOf(),
    val configuration: ByteArray = byteArrayOf(),
)

internal interface DeviceTagIo {
    fun probe(writing: Boolean): DeviceTagProbe
    fun writableCapacity(): Int
    fun readMessage(): ByteArray
    fun writeMessage(message: ByteArray)
}

internal data class DeviceTagVerified(
    val tagId: String,
    val deviceToken: String,
    val uri: String,
    val bytesWritten: Int = 0,
)

/** Testable operation ordering: cancel/lock/capacity gates precede every write. */
internal object DeviceTagOperation {
    fun execute(
        io: DeviceTagIo,
        token: String?,
        active: () -> Boolean,
        progress: (String) -> Unit = {},
    ): DeviceTagVerified {
        fun checkActive() {
            if (!active()) throw DeviceTagFailure("OPERATION_CANCELLED", "NFC 操作已取消；写入中断时请重新校验标签")
        }
        if (token != null) DeviceTagProtocol.uriFor(token)
        checkActive()
        val probe = io.probe(token != null)
        checkActive()
        DeviceTagProtocol.validateTag(probe)
        if (token == null) {
            val uri = DeviceTagProtocol.uriFromMessage(io.readMessage())
                ?: throw DeviceTagFailure("INVALID_DEVICE_TAG", "此标签没有有效的 Sohun 设备入口")
            checkActive()
            return DeviceTagVerified(probe.tagId, DeviceTagProtocol.tokenFromUri(uri)!!, uri)
        }
        DeviceTagProtocol.validateWritable(probe)
        val encoded = DeviceTagProtocol.encode(token, io.writableCapacity())
        checkActive()
        progress("writing")
        checkActive()
        io.writeMessage(encoded)
        checkActive()
        progress("verifying")
        val readback = io.readMessage()
        checkActive()
        if (!encoded.contentEquals(readback) ||
            DeviceTagProtocol.uriFromMessage(readback) != DeviceTagProtocol.uriFor(token)) {
            throw DeviceTagFailure("VERIFY_FAILED", "设备入口回读校验未通过，请贴紧标签重新制作")
        }
        return DeviceTagVerified(probe.tagId, token, DeviceTagProtocol.uriFor(token), encoded.size)
    }
}

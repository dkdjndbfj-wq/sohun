package top.sohun.consumable_tracker

import org.junit.Test

/** JVM regressions for actual protocol and write gates; no physical NFC claims. */
class DeviceTagChecks {
    private companion object {
        const val TOKEN = "0123456789abcdef0123456789abcdef"
        const val URI = "https://sohun.top/device/$TOKEN"
    }

    @Test
    fun deviceTagProtocolAndWriteGateChecks() {
        var passed = 0
        fun verify(name: String, test: () -> Unit) {
            test()
            passed++
            println("PASS $name")
        }
        fun fails(code: String, action: () -> Unit) {
            try {
                action()
                error("Expected $code")
            } catch (failure: DeviceTagFailure) {
                check(failure.code == code) { "Expected $code, got ${failure.code}" }
            }
        }

        verify("URI and app scheme resolve the same opaque token") {
            check(DeviceTagProtocol.tokenFromUri(URI) == TOKEN)
            check(DeviceTagProtocol.tokenFromUri("sohun://device/$TOKEN") == TOKEN)
            check(DeviceTagProtocol.uriFor(TOKEN) == URI)
        }
        verify("credentials, alternative hosts, path tricks and URL extras are refused") {
            for (uri in listOf("$URI?code=secret", "$URI#secret", "$URI/", "$URI\n",
                "https://sohun.top:443/device/$TOKEN", "https://user@sohun.top/device/$TOKEN",
                "https://sohun.top.attacker.invalid/device/$TOKEN", "https://sohun.top/device/%30${TOKEN.drop(1)}",
                "http://sohun.top/device/$TOKEN", "sohun://device/$TOKEN/extra",
                "sohun://device:80/$TOKEN", "sohun://device/$TOKEN?accessCode=secret")) {
                check(DeviceTagProtocol.tokenFromUri(uri) == null) { uri }
            }
        }
        verify("writes require server token, never UID, URL, UUID or inventory metadata") {
            for (token in listOf("04AABBCCDDEE11", URI, "eSUN PLA blue", "{}", "a".repeat(31),
                "01234567-89ab-cdef-0123-456789abcdef", TOKEN.uppercase(), "$TOKEN\n")) {
                val io = FakeIo()
                fails("INVALID_PAYLOAD") { DeviceTagOperation.execute(io, token, { true }) }
                check(io.probes == 0 && io.writes == 0)
            }
        }
        verify("URI plus Android Application Record fits standard NTAG213") {
            val bytes = DeviceTagProtocol.encode(TOKEN, 137)
            check(bytes.size <= 137)
            check(DeviceTagProtocol.uriFromMessage(bytes) == URI)
            check(String(bytes).contains("android.com:pkg"))
            check(String(bytes).contains(DeviceTagProtocol.PACKAGE_NAME))
        }
        verify("reduced capacity preserves complete URI while omitting optional AAR") {
            val bytes = DeviceTagProtocol.encode(TOKEN, 60)
            check(bytes.size <= 60)
            check(DeviceTagProtocol.uriFromMessage(bytes) == URI)
            check(!String(bytes).contains("android.com:pkg"))
        }
        verify("insufficient capacity performs no write") {
            val io = FakeIo().apply { capacity = 32 }
            fails("TAG_CAPACITY") { DeviceTagOperation.execute(io, TOKEN, { true }) }
            check(io.writes == 0)
        }
        verify("successful write returns only after byte-for-byte readback") {
            val io = FakeIo()
            val states = mutableListOf<String>()
            val result = DeviceTagOperation.execute(io, TOKEN, { true }, states::add)
            check(result.uri == URI && result.deviceToken == TOKEN)
            check(result.tagId == "04AABBCCDDEE11" && result.bytesWritten > 0)
            check(io.writes == 1 && io.reads == 1)
            check(states == listOf("writing", "verifying"))
        }
        verify("old content or altered readback is never a write success") {
            val io = FakeIo().apply { ignoreWrite = true }
            fails("VERIFY_FAILED") { DeviceTagOperation.execute(io, TOKEN, { true }) }
            check(io.writes == 1 && io.reads == 1)
        }
        verify("NTAG215 and unknown version are refused before writing") {
            for (version in listOf(byteArrayOf(0, 4, 4, 2, 1, 0, 0x11, 3), byteArrayOf(0))) {
                val io = FakeIo().apply { probe = probe.copy(version = version) }
                fails("UNSUPPORTED_TAG") { DeviceTagOperation.execute(io, TOKEN, { true }) }
                check(io.writes == 0)
            }
        }
        verify("Classic-shaped UID cannot enter the device tag writer") {
            val io = FakeIo().apply { probe = probe.copy(tagId = "AABBCCDD") }
            fails("UNSUPPORTED_TAG") { DeviceTagOperation.execute(io, TOKEN, { true }) }
            check(io.writes == 0)
        }
        verify("static locks refuse writing") {
            for (byte in 10..11) {
                val io = FakeIo().apply { probe.header[byte] = 1 }
                fails("TAG_LOCKED") { DeviceTagOperation.execute(io, TOKEN, { true }) }
                check(io.writes == 0)
            }
        }
        verify("dynamic locks refuse writing") {
            for (byte in 0..2) {
                val io = FakeIo().apply { probe.configuration[byte] = 1 }
                fails("TAG_LOCKED") { DeviceTagOperation.execute(io, TOKEN, { true }) }
                check(io.writes == 0)
            }
        }
        verify("password-protected tags refuse writing without attempting unlock") {
            val io = FakeIo().apply { probe.configuration[7] = 4 }
            fails("TAG_LOCKED") { DeviceTagOperation.execute(io, TOKEN, { true }) }
            check(io.writes == 0)
        }
        verify("read-only NDEF capability refuses writing") {
            val io = FakeIo().apply { probe.header[15] = 0x0F }
            fails("TAG_LOCKED") { DeviceTagOperation.execute(io, TOKEN, { true }) }
            check(io.writes == 0)
        }
        verify("unknown capability and incomplete lock reads refuse writing") {
            val unknown = FakeIo().apply { probe.header[14] = 0x3E }
            fails("UNSUPPORTED_FORMAT") { DeviceTagOperation.execute(unknown, TOKEN, { true }) }
            val incomplete = FakeIo().apply { probe = probe.copy(configuration = byteArrayOf()) }
            fails("READ_FAILED") { DeviceTagOperation.execute(incomplete, TOKEN, { true }) }
            check(unknown.writes == 0 && incomplete.writes == 0)
        }
        verify("cancel before tag probing performs no IO") {
            val io = FakeIo()
            fails("OPERATION_CANCELLED") { DeviceTagOperation.execute(io, TOKEN, { false }) }
            check(io.probes == 0 && io.writes == 0)
        }
        verify("cancel after probing prevents writes") {
            var active = true
            val io = FakeIo().apply { afterProbe = { active = false } }
            fails("OPERATION_CANCELLED") { DeviceTagOperation.execute(io, TOKEN, { active }) }
            check(io.writes == 0)
        }
        verify("cancel in writing progress prevents writes") {
            var active = true
            val io = FakeIo()
            fails("OPERATION_CANCELLED") {
                DeviceTagOperation.execute(io, TOKEN, { active }) { active = false }
            }
            check(io.writes == 0)
        }
        verify("cancel during write does not manufacture a verified success") {
            var active = true
            val io = FakeIo().apply { afterWrite = { active = false } }
            fails("OPERATION_CANCELLED") { DeviceTagOperation.execute(io, TOKEN, { active }) }
            check(io.writes == 1 && io.reads == 0)
        }
        verify("cancel during readback does not manufacture a verified success") {
            var active = true
            val io = FakeIo().apply { afterRead = { active = false } }
            fails("OPERATION_CANCELLED") { DeviceTagOperation.execute(io, TOKEN, { active }) }
            check(io.writes == 1 && io.reads == 1)
        }
        verify("read-only operation accepts a valid locked device tag without mutation") {
            val io = FakeIo().apply {
                message = DeviceTagProtocol.encode(TOKEN, 137)
                probe.header[10] = 1
            }
            val result = DeviceTagOperation.execute(io, null, { true })
            check(result.deviceToken == TOKEN && result.bytesWritten == 0)
            check(io.reads == 1 && io.writes == 0)
        }
        verify("legacy consumable payload is not interpreted as a device tag") {
            val io = FakeIo().apply { message = "SOH1eSUN/PLA/BLUE".toByteArray() }
            fails("INVALID_DEVICE_TAG") { DeviceTagOperation.execute(io, null, { true }) }
            check(io.writes == 0)
        }
        verify("truncated, appended and malformed NDEF data is rejected") {
            val good = DeviceTagProtocol.encode(TOKEN, 137)
            for (length in 0 until good.size) {
                check(DeviceTagProtocol.uriFromMessage(good.copyOf(length)) == null)
            }
            check(DeviceTagProtocol.uriFromMessage(good + byteArrayOf(0)) == null)
            check(DeviceTagProtocol.uriFromMessage(good.copyOf().apply { this[0] = 0xB1.toByte() }) == null)
            check(DeviceTagProtocol.uriFromMessage(good.copyOf().apply { this[lastIndex] = 0 }) == null)
        }
        println("$passed device tag protocol checks passed")
    }

    private class FakeIo : DeviceTagIo {
        var probe = DeviceTagProbe("04AABBCCDDEE11",
            byteArrayOf(0, 4, 4, 2, 1, 0, 0x0F, 3),
            ByteArray(16).apply {
                this[12] = 0xE1.toByte(); this[13] = 0x10; this[14] = 0x12
            },
            ByteArray(16).apply { this[7] = 0xFF.toByte() })
        var capacity = 137
        var message = byteArrayOf()
        var ignoreWrite = false
        var probes = 0
        var reads = 0
        var writes = 0
        var afterProbe: () -> Unit = {}
        var afterWrite: () -> Unit = {}
        var afterRead: () -> Unit = {}
        override fun probe(writing: Boolean): DeviceTagProbe { probes++; afterProbe(); return probe }
        override fun writableCapacity(): Int = capacity
        override fun readMessage(): ByteArray { reads++; afterRead(); return message }
        override fun writeMessage(message: ByteArray) {
            writes++
            if (!ignoreWrite) this.message = message.copyOf()
            afterWrite()
        }
    }
}

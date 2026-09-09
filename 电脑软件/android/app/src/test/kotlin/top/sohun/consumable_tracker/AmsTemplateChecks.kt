package top.sohun.consumable_tracker

import org.junit.Test

/** JVM regressions for the AMS template protocol; no physical NFC claims. */
class AmsTemplateChecks {
    @Test
    fun protocolAndWriteSafetyChecks() {
        var passed = 0
        fun scenario(name: String, test: () -> Unit) {
            test()
            passed++
            println("PASS $name")
        }
        val source = fixture("01020304")
        scenario("canonical round-trip and defensive copies") {
            val parsed = AmsTemplate.parse(source.toMap())
            check(parsed.toMap() == source.toMap())
            val b = parsed.block(0); b[0] = 0
            check(parsed.uid == "01020304" && parsed.block(0)[0] == 1.toByte())
            check(!parsed.toString().contains("01020304"))
        }
        scenario("UID/BCC inconsistency rejected") {
            val blocks = (0..63).map(source::block); blocks[0][4] = 42
            expectFailure("INVALID_TEMPLATE") { AmsTemplate.fromBlocks(source.uid, blocks) }
        }
        scenario("incomplete and malformed templates rejected") {
            expectFailure("INVALID_TEMPLATE") { AmsTemplate.parse(source.toMap() + ("blocks" to listOf("00"))) }
            expectFailure("INVALID_TEMPLATE") { AmsTemplate.parse(source.toMap() + ("version" to 2)) }
        }
        scenario("corrupted access complements rejected") {
            val blocks = (0..63).map(source::block); blocks[3][6] = 0
            expectFailure("INVALID_ACCESS_BITS") { AmsTemplate.fromBlocks(source.uid, blocks) }
        }
        scenario("empty signature never manufactured") {
            val blocks = (0..63).map(source::block)
            for (i in 40..62) if (i % 4 != 3) blocks[i].fill(0)
            expectFailure("INVALID_TEMPLATE") { AmsTemplate.fromBlocks(source.uid, blocks) }
        }
        scenario("empty tray identity cannot enter inventory mappings") {
            val blocks = (0..63).map(source::block); blocks[9].fill(0)
            expectFailure("INVALID_TEMPLATE") { AmsTemplate.fromBlocks(source.uid, blocks) }
        }
        scenario("HKDF determinism and 16 distinct sector keys") {
            val keys = amsKeyA(amsUnhex("01020304"))
            check(keys.size == 16 && keys.all { it.size == 6 })
            check(keys.map(::amsHex).toSet().size == 16)
            check(keys.map(::amsHex) == amsKeyA(amsUnhex("01020304")).map(::amsHex))
            // Independently checked with Python stdlib hmac/hashlib.
            check(amsHex(keys.first()) == "6B0D673986DE")
        }
        scenario("source reads reconstruct masked keys by verified authentication") {
            val tag = FakeCard((0..63).map(source::block).toMutableList())
            val read = AmsTemplateEngine().readTemplate(tag)
            check(read.toMap() == source.toMap())
            check(tag.writes.isEmpty())
        }
        scenario("unknown hidden KeyB prevents incomplete source export") {
            val blocks = (0..63).map(source::block).toMutableList()
            blocks[3][10] = 77
            expectFailure("TEMPLATE_KEY_B_UNAVAILABLE") { AmsTemplateEngine().readTemplate(FakeCard(blocks)) }
        }
        scenario("user-supplied matching keys can authenticate a complete source") {
            val blocks = (0..63).map(source::block).toMutableList(); blocks[3][10] = 77
            val known = AmsTemplate.fromBlocks(source.uid, blocks)
            check(AmsTemplateEngine().readTemplate(FakeCard(blocks), known).toMap() == known.toMap())
        }
        scenario("explicit carrier and UID risk confirmation required before any write") {
            val tag = blank()
            expectFailure("UID_CHANGE_CONFIRMATION_REQUIRED") { AmsTemplateEngine().restore(tag, source, false, "fuid") }
            expectFailure("UID_CHANGE_CONFIRMATION_REQUIRED") { AmsTemplateEngine().restore(tag, source, true, "ordinary") }
            check(tag.writes.isEmpty())
        }
        scenario("all sectors preflighted before any target mutation") {
            val tag = blank()
            source.block(63).copyInto(tag.blocks[63])
            expectFailure("TARGET_NOT_WRITABLE") { AmsTemplateEngine().restore(tag, source, true, "cuid") }
            check(tag.writes.isEmpty())
        }
        scenario("restore requires physical reselection and final full verification") {
            val tag = blank()
            val first = AmsTemplateEngine().restore(tag, source, true, "fuid")
            check(first == AmsRestoreResult.RESELECT_REQUIRED)
            check(amsHex(tag.uid) == "10203040") // old Android Tag UID is not synthesized
            check(tag.writes.last() == 0 && 3 !in tag.writes)
            check(tag.writes.take(47).all { it != 0 && it % 4 != 3 })
            val fresh = tag.reselect()
            check(amsHex(fresh.uid) == source.uid)
            check(AmsTemplateEngine().restore(fresh, source, true, "fuid") == AmsRestoreResult.VERIFIED)
            check(fresh.writes == listOf(3))
            check((0..63).all { fresh.blocks[it].contentEquals(source.block(it)) })
        }
        scenario("already restored FUID is idempotent and does not rewrite fused UID") {
            val tag = FakeCard((0..63).map(source::block).toMutableList(), uidWritable = false)
            check(AmsTemplateEngine().restore(tag, source, true, "fuid") == AmsRestoreResult.VERIFIED)
            check(tag.writes.isEmpty())
        }
        scenario("stale Android UID cannot finalize sector zero or report success") {
            val tag = blank()
            check(AmsTemplateEngine().restore(tag, source, true, "cuid") == AmsRestoreResult.RESELECT_REQUIRED)
            expectFailure("UID_RESELECT_REQUIRED") { AmsTemplateEngine().restore(tag, source, true, "cuid") }
            check(3 !in tag.writes)
        }
        scenario("a locked clone cannot be silently repurposed for another template") {
            val tag = FakeCard((0..63).map(source::block).toMutableList())
            expectFailure("TARGET_NOT_WRITABLE") { AmsTemplateEngine().restore(tag, fixture("10203040"), true, "fuid") }
            check(tag.writes.isEmpty())
        }
        scenario("ordinary immutable manufacturer block never reports success") {
            val tag = blank(uidWritable = false)
            runCatching { AmsTemplateEngine().restore(tag, source, true, "cuid") }
                .onSuccess { error("immutable UID card accepted") }
            check(amsHex(tag.reselect().uid) != source.uid)
        }
        scenario("readback mismatch stops before permanent trailer writes") {
            val tag = blank(); tag.corruptWrites = true
            expectFailure("VERIFY_FAILED") { AmsTemplateEngine().restore(tag, source, true, "cuid") }
            check(tag.writes == listOf(1))
        }
        scenario("cancelled operation cannot write another block") {
            val tag = blank()
            expectFailure("OPERATION_CANCELLED") {
                AmsTemplateEngine(checkActive = { throw AmsTemplateFailure("OPERATION_CANCELLED", "cancelled") })
                    .restore(tag, source, true, "cuid")
            }
            check(tag.writes.isEmpty())
        }
        scenario("cancellation during authentication prevents the following write") {
            val tag = blank()
            expectFailure("OPERATION_CANCELLED") {
                AmsTemplateEngine(checkActive = {
                    if (tag.authAttempts >= 33) throw AmsTemplateFailure("OPERATION_CANCELLED", "cancelled")
                }).restore(tag, source, true, "cuid")
            }
            check(tag.writes.isEmpty())
        }
        scenario("partial restoration can retry the same template") {
            val tag = blank(); tag.failAtBlock = 15
            runCatching { AmsTemplateEngine().restore(tag, source, true, "cuid") }
                .onSuccess { error("injected interruption was ignored") }
            val retry = tag.reselect()
            check(AmsTemplateEngine().restore(retry, source, true, "cuid") == AmsRestoreResult.RESELECT_REQUIRED)
            check(AmsTemplateEngine().restore(retry.reselect(), source, true, "cuid") == AmsRestoreResult.VERIFIED)
        }
        println("$passed native template checks passed; NFC/AMS hardware not tested")
    }

    private fun expectFailure(code: String, action: () -> Unit) {
        try { action(); error("expected $code") }
        catch (failure: AmsTemplateFailure) { check(failure.code == code) { "expected $code, got ${failure.code}" } }
    }

    /** Synthetic test image, not a vendor dump or a valid vendor signature. */
    private fun fixture(uid: String): AmsTemplate {
        val blocks = MutableList(64) { i -> ByteArray(16) { ((i * 7 + it) % 251).toByte() } }
        val bytes = amsUnhex(uid); bytes.copyInto(blocks[0])
        blocks[0][4] = bytes.fold(0) { a, b -> a xor (b.toInt() and 255) }.toByte()
        val keys = amsKeyA(bytes)
        for (s in 0..15) blocks[s * 4 + 3] = keys[s] + amsUnhex("87878769") + ByteArray(6)
        return AmsTemplate.fromBlocks(uid, blocks)
    }

    private fun blank(uidWritable: Boolean = true): FakeCard {
        val blocks = MutableList(64) { ByteArray(16) }
        amsUnhex("10203040400804000000000000000000").copyInto(blocks[0])
        for (s in 0..15) blocks[s * 4 + 3] = amsUnhex("FFFFFFFFFFFFFF078069FFFFFFFFFFFF")
        return FakeCard(blocks, uidWritable)
    }

    private class FakeCard(val blocks: MutableList<ByteArray>, val uidWritable: Boolean = true) : AmsMifareIo {
        override val uid = blocks[0].copyOfRange(0, 4)
        val writes = mutableListOf<Int>()
        var corruptWrites = false
        var failAtBlock: Int? = null
        private var authenticated = -1
        var authAttempts = 0
        fun reselect(): FakeCard = FakeCard(blocks, uidWritable)
        override fun authenticateA(sector: Int, key: ByteArray): Boolean {
            authAttempts++
            val okay = blocks[sector * 4 + 3].copyOfRange(0, 6).contentEquals(key)
            authenticated = if (okay) sector else -1
            return okay
        }
        override fun authenticateB(sector: Int, key: ByteArray): Boolean {
            val trailer = blocks[sector * 4 + 3]
            val okay = !AmsAccess.parse(trailer).keyBReadable && trailer.copyOfRange(10, 16).contentEquals(key)
            authenticated = if (okay) sector else -1
            return okay
        }
        override fun read(block: Int): ByteArray {
            check(authenticated == block / 4)
            return blocks[block].copyOf().also {
                if (block % 4 == 3) {
                    it.fill(0, 0, 6)
                    if (!AmsAccess.parse(it).keyBReadable) it.fill(0, 10, 16)
                }
            }
        }
        override fun write(block: Int, data: ByteArray) {
            check(authenticated == block / 4)
            check(AmsAccess.parse(blocks[(block / 4) * 4 + 3]).isTransport)
            if (block == failAtBlock || (block == 0 && !uidWritable)) throw java.io.IOException("simulated rejection")
            writes.add(block)
            blocks[block] = data.copyOf()
            if (corruptWrites) blocks[block][0] = (blocks[block][0].toInt() xor 255).toByte()
        }
    }
}

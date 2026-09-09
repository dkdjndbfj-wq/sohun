package top.sohun.consumable_tracker

import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * A local-only, complete Classic 1K image. This is not a signature generator or
 * an authenticity verifier. No brand/model/color supplied by Sohun is inserted.
 * Protocol references (implementation written independently):
 * https://github.com/Bambu-Research-Group/RFID-Tag-Guide/blob/main/deriveKeys.py
 * https://github.com/Bambu-Research-Group/RFID-Tag-Guide/blob/main/BambuLabRfid.md
 * NXP MF1S50YYX_V1, tables 7/8 (sector access conditions).
 */
internal class AmsTemplate private constructor(
    val uid: String,
    private val image: List<ByteArray>,
) {
    fun block(index: Int): ByteArray = image[index].copyOf()
    fun toMap(): Map<String, Any> = mapOf(
        "format" to "sohun.ams-template", "version" to 1,
        "uid" to uid, "blocks" to image.map(::amsHex),
    )

    // Never include block data or keys in exception/debug representations.
    override fun toString(): String = "AmsTemplate(local-only, 64 blocks)"

    companion object {
        fun parse(value: Map<*, *>?): AmsTemplate {
            if (value?.get("format") != "sohun.ams-template" || value["version"] != 1) {
                throw AmsTemplateFailure("INVALID_TEMPLATE", "模板格式或版本不受支持")
            }
            val uid = (value["uid"] as? String)?.uppercase(Locale.ROOT)
            if (uid == null || !uid.matches(Regex("[0-9A-F]{8}"))) {
                throw AmsTemplateFailure("INVALID_TEMPLATE", "模板必须包含 4 字节 UID")
            }
            val raw = value["blocks"] as? List<*>
            if (raw == null || raw.size != 64) {
                throw AmsTemplateFailure("INVALID_TEMPLATE", "必须提供完整 64 块模板，不能使用缺块记录")
            }
            val blocks = raw.map {
                val hex = it as? String
                if (hex == null || !hex.matches(Regex("[0-9a-fA-F]{32}"))) {
                    throw AmsTemplateFailure("INVALID_TEMPLATE", "模板数据块长度或编码无效")
                }
                amsUnhex(hex)
            }
            return fromBlocks(uid, blocks)
        }

        fun fromBlocks(uid: String, blocks: List<ByteArray>): AmsTemplate {
            if (!uid.matches(Regex("[0-9A-Fa-f]{8}")) || blocks.size != 64 ||
                blocks.any { it.size != 16 }
            ) throw AmsTemplateFailure("INVALID_TEMPLATE", "模板必须为完整 MIFARE Classic 1K 镜像")
            val uidBytes = amsUnhex(uid)
            val block0 = blocks[0]
            val bcc = uidBytes.fold(0) { acc, b -> acc xor (b.toInt() and 255) }.toByte()
            if (!block0.copyOfRange(0, 4).contentEquals(uidBytes) || block0[4] != bcc) {
                throw AmsTemplateFailure("INVALID_TEMPLATE", "模板 UID 与制造商块/BCC 不一致")
            }
            if (blocks[9].all { it == 0.toByte() } || blocks[9].all { it == 0xFF.toByte() }) {
                throw AmsTemplateFailure("INVALID_TEMPLATE", "模板缺少料盘身份，无法建立库存映射")
            }
            for (sector in 0..15) {
                val access = AmsAccess.parse(blocks[sector * 4 + 3])
                // Only the publicly documented Bambu profile is supported.
                // Reject unknown permissions before any irreversible target write.
                if (!access.isBambuProfile) {
                    throw AmsTemplateFailure("UNSUPPORTED_TEMPLATE_ACCESS", "模板使用未知访问权限，未进行写入")
                }
            }
            val signature = (40..62).filter { it % 4 != 3 }.flatMap { blocks[it].asList() }
            if (signature.all { it == 0.toByte() } || signature.all { it == 0xFF.toByte() }) {
                throw AmsTemplateFailure("INVALID_TEMPLATE", "模板签名区域为空；不能生成或补齐签名")
            }
            // Presence and structure are checked, not cryptographic authenticity.
            return AmsTemplate(uid.uppercase(Locale.ROOT), blocks.map { it.copyOf() })
        }
    }
}

internal class AmsTemplateFailure(val code: String, message: String) : Exception(message)

internal fun amsHex(bytes: ByteArray): String = bytes.joinToString("") { "%02X".format(it) }
internal fun amsUnhex(hex: String): ByteArray = ByteArray(hex.length / 2) {
    hex.substring(it * 2, it * 2 + 2).toInt(16).toByte()
}

/** HKDF-SHA256, public UID-based protocol derivation, 16 consecutive 6-byte keys. */
internal fun amsKeyA(uid: ByteArray): List<ByteArray> {
    require(uid.size == 4)
    val salt = amsUnhex("9A759CF2C4F7CAFF222CB9769B41BC96")
    fun hmac(key: ByteArray, message: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(key, "HmacSHA256"))
            doFinal(message)
        }
    val prk = hmac(salt, uid)
    val info = byteArrayOf(0x52, 0x46, 0x49, 0x44, 0x2D, 0x41, 0)
    var previous = byteArrayOf()
    val expanded = ByteArray(96)
    for (counter in 1..3) {
        previous = hmac(prk, previous + info + byteArrayOf(counter.toByte()))
        previous.copyInto(expanded, (counter - 1) * 32)
    }
    return (0..15).map { expanded.copyOfRange(it * 6, it * 6 + 6) }
}

internal class AmsAccess private constructor(private val bits: IntArray, val gpb: Int) {
    val isTransport: Boolean get() = bits.contentEquals(intArrayOf(0, 0, 0, 1))
    val isBambuProfile: Boolean get() = bits.contentEquals(intArrayOf(2, 2, 2, 5)) && gpb == 0x69
    val keyBReadable: Boolean get() = bits[3] in listOf(0, 1, 2)

    companion object {
        fun parse(trailer: ByteArray): AmsAccess {
            if (trailer.size != 16) throw AmsTemplateFailure("INVALID_ACCESS_BITS", "访问权限数据不完整")
            val b6 = trailer[6].toInt() and 255
            val b7 = trailer[7].toInt() and 255
            val b8 = trailer[8].toInt() and 255
            val c1 = b7 shr 4
            val c2 = b8 and 15
            val c3 = b8 shr 4
            if (((b6 and 15) xor c1) != 15 || ((b6 shr 4) xor c2) != 15 ||
                ((b7 and 15) xor c3) != 15
            ) throw AmsTemplateFailure("INVALID_ACCESS_BITS", "标签访问位及反码不一致，禁止写入")
            return AmsAccess(IntArray(4) { i ->
                (((c1 shr i) and 1) shl 2) or (((c2 shr i) and 1) shl 1) or ((c3 shr i) and 1)
            }, trailer[9].toInt() and 255)
        }
    }
}

/** Android-free seam, allowing interrupted/locked/readback behavior to be tested. */
internal interface AmsMifareIo {
    val uid: ByteArray
    fun authenticateA(sector: Int, key: ByteArray): Boolean
    fun authenticateB(sector: Int, key: ByteArray): Boolean
    fun read(block: Int): ByteArray
    fun write(block: Int, data: ByteArray)
}

internal enum class AmsRestoreResult { RESELECT_REQUIRED, VERIFIED }

/**
 * Fail-closed restore, no magic-card probing/backdoor commands. A card cannot be
 * identified as CUID/FUID through the standard Android API; the caller must get
 * explicit user confirmation of the purchased carrier type and UID-write risk.
 * Block 0 is written before sector 0's final read-only trailer. A fresh Tag.uid
 * after physical removal is mandatory before sector 0 is finalized or success.
 */
internal class AmsTemplateEngine(
    private val checkActive: () -> Unit = {},
    private val progress: (String, Int) -> Unit = { _, _ -> },
) {
    var blocksWritten: Int = 0
        private set
    private val defaultKey = ByteArray(6) { 0xFF.toByte() }
    private val zeroKey = ByteArray(6)

    private class SectorImage(val blocks: List<ByteArray>, val keyA: ByteArray) {
        val trailer: ByteArray get() = blocks[3]
    }

    private fun authenticateA(io: AmsMifareIo, sector: Int, candidates: List<ByteArray>): ByteArray {
        for (key in candidates.distinctBy(::amsHex)) {
            checkActive()
            if (io.authenticateA(sector, key)) return key
        }
        throw AmsTemplateFailure("AUTH_FAILED", "第 ${sector + 1} 扇区认证失败，未能读取完整内容")
    }

    private fun readSector(io: AmsMifareIo, sector: Int, keyAs: List<ByteArray>, keyBs: List<ByteArray>): SectorImage {
        val a = authenticateA(io, sector, keyAs)
        val raw = io.read(sector * 4 + 3)
        val access = AmsAccess.parse(raw)
        val b = if (access.keyBReadable) {
            raw.copyOfRange(10, 16)
        } else {
            var verified: ByteArray? = null
            for (key in keyBs.distinctBy(::amsHex)) {
                checkActive()
                if (io.authenticateB(sector, key)) {
                    verified = key
                    break
                }
            }
            verified ?: throw AmsTemplateFailure("TEMPLATE_KEY_B_UNAVAILABLE", "第 ${sector + 1} 扇区 Key B 不可读取或验证；不保存缺失密钥的模板")
        }
        checkActive()
        if (!io.authenticateA(sector, a)) throw AmsTemplateFailure("AUTH_FAILED", "标签重新认证失败")
        val blocks = (0..2).map {
            checkActive()
            io.read(sector * 4 + it).also { data ->
                if (data.size != 16) throw AmsTemplateFailure("READ_FAILED", "标签返回了不完整的数据块")
            }
        } + listOf(a + raw.copyOfRange(6, 10) + b)
        return SectorImage(blocks, a)
    }

    fun readTemplate(io: AmsMifareIo, suppliedKeys: AmsTemplate? = null): AmsTemplate {
        val uid = amsHex(io.uid)
        if (io.uid.size != 4) throw AmsTemplateFailure("UNSUPPORTED_TAG", "仅支持 4 字节 UID 的 Classic 1K 标签")
        if (suppliedKeys != null && suppliedKeys.uid != uid) throw AmsTemplateFailure("TEMPLATE_UID_MISMATCH", "所选密钥模板不属于此标签")
        val derived = amsKeyA(io.uid)
        val all = mutableListOf<ByteArray>()
        for (sector in 0..15) {
            val saved = suppliedKeys?.block(sector * 4 + 3)
            val aKeys = listOfNotNull(saved?.copyOfRange(0, 6), derived[sector], defaultKey)
            val bKeys = listOfNotNull(saved?.copyOfRange(10, 16), zeroKey, defaultKey)
            all.addAll(readSector(io, sector, aKeys, bKeys).blocks)
            progress("reading", all.size)
        }
        return AmsTemplate.fromBlocks(uid, all)
    }

    fun restore(io: AmsMifareIo, template: AmsTemplate, allowUidChange: Boolean, targetKind: String): AmsRestoreResult {
        if (targetKind !in listOf("cuid", "fuid") || !allowUidChange) {
            throw AmsTemplateFailure("UID_CHANGE_CONFIRMATION_REQUIRED", "请先确认 CUID/FUID 型号及 UID 写入风险；FUID 的 UID 只能写一次")
        }
        if (io.uid.size != 4) throw AmsTemplateFailure("UNSUPPORTED_TAG", "目标必须是 4 字节 UID 的 Classic 1K CUID/FUID")
        val derivedCurrent = amsKeyA(io.uid)
        val preflight = (0..15).map { sector ->
            val desired = template.block(sector * 4 + 3)
            val image = readSector(io, sector,
                listOf(defaultKey, desired.copyOfRange(0, 6), derivedCurrent[sector]),
                listOf(defaultKey, zeroKey, desired.copyOfRange(10, 16)))
            val same = (0..3).all { image.blocks[it].contentEquals(template.block(sector * 4 + it)) }
            if (!same && !AmsAccess.parse(image.trailer).isTransport) {
                throw AmsTemplateFailure("TARGET_NOT_WRITABLE", "第 ${sector + 1} 扇区不是可写空白权限且内容不同，未执行任何写入；已锁定标签不能更换模板")
            }
            progress("preflight", sector + 1)
            image
        }
        // All 16 sectors have been authenticated and access-checked before writes.
        for (sector in 0..15) {
            for (offset in 0..2) {
                val block = sector * 4 + offset
                if (block == 0) continue
                val desired = template.block(block)
                if (preflight[sector].blocks[offset].contentEquals(desired)) continue
                checkActive()
                if (!io.authenticateA(sector, preflight[sector].keyA)) throw AmsTemplateFailure("AUTH_FAILED", "写入前认证失败")
                checkActive()
                io.write(block, desired)
                blocksWritten++
                checkActive()
                if (!io.read(block).contentEquals(desired)) throw AmsTemplateFailure("VERIFY_FAILED", "第 $block 块回读不一致；已写入部分内容，请保留模板重试")
                progress("writing", blocksWritten)
            }
        }
        // Final permissions can make ordinary data blocks permanently read-only.
        // The source image must remain byte-for-byte unchanged, including keys.
        for (sector in 1..15) finalizeSector(io, template, sector, preflight[sector])
        val desired0 = template.block(0)
        if (!preflight[0].blocks[0].contentEquals(desired0)) {
            checkActive()
            if (!io.authenticateA(0, preflight[0].keyA)) throw AmsTemplateFailure("AUTH_FAILED", "UID 写入前认证失败")
            checkActive()
            // Only a user-confirmed CUID/FUID request reaches this standard
            // authenticated write. Never issue Gen1 unlock or undocumented probes.
            io.write(0, desired0)
            blocksWritten++
            progress("awaiting_reselect", blocksWritten)
            // Android's current Tag.id is immutable and may now be stale.
            return AmsRestoreResult.RESELECT_REQUIRED
        }
        if (amsHex(io.uid) != template.uid) {
            throw AmsTemplateFailure("UID_RESELECT_REQUIRED", "制造商块与当前 NFC UID 不一致，请移开标签后重新读取")
        }
        finalizeSector(io, template, 0, preflight[0])
        verify(io, template)
        return AmsRestoreResult.VERIFIED
    }

    private fun finalizeSector(io: AmsMifareIo, template: AmsTemplate, sector: Int, previous: SectorImage) {
        val desired = template.block(sector * 4 + 3)
        if (!previous.trailer.contentEquals(desired)) {
            checkActive()
            if (!io.authenticateA(sector, previous.keyA)) throw AmsTemplateFailure("AUTH_FAILED", "访问权限写入前认证失败")
            checkActive()
            io.write(sector * 4 + 3, desired)
            blocksWritten++
        }
        val verified = readSector(io, sector, listOf(desired.copyOfRange(0, 6)), listOf(desired.copyOfRange(10, 16)))
        if ((0..3).any { !verified.blocks[it].contentEquals(template.block(sector * 4 + it)) }) {
            throw AmsTemplateFailure("VERIFY_FAILED", "第 ${sector + 1} 扇区密钥/权限/内容回读失败；不能视为成功")
        }
        progress("verifying", sector + 1)
    }

    fun verify(io: AmsMifareIo, template: AmsTemplate) {
        if (amsHex(io.uid) != template.uid) throw AmsTemplateFailure("UID_MISMATCH", "实际 NFC UID 与模板不一致")
        for (sector in 0..15) {
            val trailer = template.block(sector * 4 + 3)
            val image = readSector(io, sector, listOf(trailer.copyOfRange(0, 6)), listOf(trailer.copyOfRange(10, 16)))
            if ((0..3).any { !image.blocks[it].contentEquals(template.block(sector * 4 + it)) }) {
                throw AmsTemplateFailure("VERIFY_FAILED", "最终全卡回读不一致，未确认恢复成功")
            }
            progress("verifying", (sector + 1) * 4)
        }
    }
}

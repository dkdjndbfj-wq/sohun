package top.sohun.consumable_tracker

import android.content.Context
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.TagLostException
import android.nfc.tech.MifareClassic
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Rejects retired inventory record methods before any Activity/NFC access. */
internal fun rejectLegacyConsumableNfcCall(
    call: MethodCall,
    result: MethodChannel.Result,
): Boolean {
    when (call.method) {
        "beginWrite" -> when (call.argument<String>("profile")?.trim()?.lowercase(Locale.ROOT)) {
            null, "", "ams" -> result.error(
                "AMS_TEMPLATE_REQUIRED",
                "AMS 写入必须选择完整兼容模板；品牌、型号和颜色仅保存到 Sohun，不写入签名数据",
                null,
            )
            "ntag213" -> result.error(
                "unsupported_tag_purpose",
                "NTAG213 不用于耗材资料或库存；请使用 CUID/FUID 耗材流程",
                null,
            )
            else -> result.error("INVALID_PAYLOAD", "未知的 NFC 写入模式", null)
        }
        "beginRead" -> result.error(
            "unsupported_tag_purpose",
            "NTAG213 不用于耗材读取入库；请使用 CUID/FUID 耗材流程",
            null,
        )
        else -> return false
    }
    return true
}

/**
 * Native NFC boundary for the mobile extension.
 *
 * Consumable operations use explicitly selected CUID/FUID carriers; legacy
 * NTAG213 consumable reads and writes are rejected before enabling reader
 * mode. AMS operations restore a complete local source template
 * without changing its signed contents. UID changes require explicit carrier
 * confirmation and fresh-tag reselection; successful readback is not an AMS
 * hardware compatibility verdict. Template blocks never enter inventory events.
 */
class MainActivity : FlutterActivity() {
    private var printerFaultBridge: PrinterFaultBridge? = null
    private var deviceTagNfc: DeviceTagNfc? = null
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        printerFaultBridge?.onPermissionsResult(requestCode)
    }
    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        printerFaultBridge?.onNewIntent(intent)
        deviceTagNfc?.onNewIntent(intent)
    }
    companion object {
        private const val CHANNEL_NAME = "top.sohun/consumable_rfid"
        private const val SECURE_CHANNEL_NAME = "top.sohun/secure_session"
        private const val EVENT_METHOD = "rfidEvent"

        private const val SECURE_STORAGE_ERROR = "SECURE_STORAGE_ERROR"
        private const val SECURE_INVALID_PAYLOAD = "SECURE_INVALID_PAYLOAD"
        private const val SECURE_PREFS_NAME = "sohun_secure_session"
        private const val SECURE_PREFS_KEY = "session_v1"
        private const val SECURE_KEY_ALIAS = "sohun_session_aes_v1"

        private const val ERROR_NFC_UNAVAILABLE = "NFC_UNAVAILABLE"
        private const val ERROR_NFC_DISABLED = "NFC_DISABLED"
        private const val ERROR_NFC_BUSY = "NFC_BUSY"
        private const val ERROR_INVALID_PAYLOAD = "INVALID_PAYLOAD"
        private const val ERROR_OPERATION_NOT_FOUND = "OPERATION_NOT_FOUND"

        private const val ERROR_UNSUPPORTED_TAG = "UNSUPPORTED_TAG"
        private const val ERROR_TAG_LOST = "TAG_LOST"
        private const val ERROR_WRITE_FAILED = "WRITE_FAILED"
        private const val ERROR_READ_UNSUPPORTED = "READ_UNSUPPORTED"
        private const val ERROR_SCAN_UNSUPPORTED = "SCAN_UNSUPPORTED"
        private const val ERROR_OPERATION_CANCELLED = "OPERATION_CANCELLED"

        private const val STATE_IDLE = "idle"
        private const val STATE_AWAITING_TAG = "awaiting_tag"
        private const val STATE_TAG_DETECTED = "tag_detected"
        private const val STATE_WRITING = "writing"
        private const val STATE_VERIFYING = "verifying"
        private const val STATE_SCAN_SUCCESS = "scan_success"
        private const val STATE_FAILED = "failed"
        private const val STATE_CANCELLED = "cancelled"

        private val DEFAULT_MIFARE_KEY = byteArrayOf(
            0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
            0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
        )

        private const val NFC_FLAGS = NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_NFC_F or
            NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK
    }

    private enum class OperationMode {
        SCAN_MIFARE,
        READ_AMS_TEMPLATE,
        RESTORE_AMS_TEMPLATE,
    }

    private data class PendingOperation(
        val id: String,
        val mode: OperationMode,
        val template: AmsTemplate? = null,
        val targetKind: String? = null,
        @Volatile var awaitingReselect: Boolean = false,
        @Volatile var blocksWritten: Int = 0,
        @Volatile var state: String = STATE_AWAITING_TAG,
        @Volatile var cancelled: Boolean = false,
    )

    private val operationLock = Any()
    private val processingTag = AtomicBoolean(false)
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var nfcAdapter: NfcAdapter? = null
    private var channel: MethodChannel? = null
    private var secureChannel: MethodChannel? = null
    private var templateVaultChannel: MethodChannel? = null
    private var pendingOperation: PendingOperation? = null
    private var lastTerminalEvent: Map<String, Any?>? = null
    private var readerModeEnabled = false
    private var activityResumed = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        printerFaultBridge = PrinterFaultBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        nfcAdapter = NfcAdapter.getDefaultAdapter(applicationContext)
        deviceTagNfc = DeviceTagNfc(this, flutterEngine.dartExecutor.binaryMessenger) {
            synchronized(operationLock) { pendingOperation != null } ||
                processingTag.get() || readerModeEnabled
        }
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel?.setMethodCallHandler(::handleMethodCall)
        secureChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SECURE_CHANNEL_NAME,
        )
        secureChannel?.setMethodCallHandler(::handleSecureMethodCall)
        templateVaultChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "top.sohun/rfid_template_vault",
        ).also { it.setMethodCallHandler(AmsTemplateVault(applicationContext)) }
    }

    override fun onResume() {
        super.onResume()
        activityResumed = true
        deviceTagNfc?.onResume()
        val operation = synchronized(operationLock) { pendingOperation }
        if (operation != null) {
            enableReaderModeIfNeeded()
        }
    }

    override fun onPause() {
        deviceTagNfc?.onPause()
        terminatePendingOperation(
            state = STATE_CANCELLED,
            code = ERROR_OPERATION_CANCELLED,
            message = "NFC 操作已暂停",
        )
        disableReaderMode()
        activityResumed = false
        super.onPause()
    }

    override fun onDestroy() {
        deviceTagNfc?.dispose()
        deviceTagNfc = null
        disableReaderMode()
        val operation = synchronized(operationLock) {
            val operation = pendingOperation
            if (operation != null) {
                operation.cancelled = true
                operation.state = STATE_CANCELLED
            }
            pendingOperation = null
            operation
        }
        if (operation != null) {
            emitEventNow(
                operation,
                state = STATE_CANCELLED,
                code = ERROR_OPERATION_CANCELLED,
                message = "RFID 操作已结束",
                force = true,
            )
        }
        ioExecutor.shutdownNow()
        channel?.setMethodCallHandler(null)
        channel = null
        secureChannel?.setMethodCallHandler(null)
        secureChannel = null
        templateVaultChannel?.setMethodCallHandler(null)
        templateVaultChannel = null
        super.onDestroy()
    }

    private fun handleSecureMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "read" -> result.success(readSecureSession())
                "write" -> {
                    val value = call.argument<String>("value")
                    if (value.isNullOrEmpty() || value.length > 32_768) {
                        result.error(
                            SECURE_INVALID_PAYLOAD,
                            "session value is required",
                            null,
                        )
                    } else {
                        writeSecureSession(value)
                        result.success(null)
                    }
                }
                "clear" -> {
                    getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
                        .edit()
                        .remove(SECURE_PREFS_KEY)
                        .apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error(SECURE_STORAGE_ERROR, "Android 安全存储不可用", error.message)
        }
    }

    /** Encrypts the short-lived sohun session with an AES key held by Android Keystore. */
    private fun writeSecureSession(value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secureKey())
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
        val packed = ByteArray(1 + iv.size + ciphertext.size)
        packed[0] = iv.size.toByte()
        iv.copyInto(packed, destinationOffset = 1)
        ciphertext.copyInto(packed, destinationOffset = 1 + iv.size)
        getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(
                SECURE_PREFS_KEY,
                Base64.encodeToString(packed, Base64.NO_WRAP),
            )
            .apply()
    }

    private fun readSecureSession(): String? {
        val encoded = getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
            .getString(SECURE_PREFS_KEY, null)
            ?: return null
        val packed = Base64.decode(encoded, Base64.DEFAULT)
        if (packed.size < 2) throw IllegalStateException("encrypted session is invalid")
        val ivSize = packed[0].toInt() and 0xFF
        if (ivSize < 12 || packed.size <= 1 + ivSize) {
            throw IllegalStateException("encrypted session is invalid")
        }
        val iv = packed.copyOfRange(1, 1 + ivSize)
        val ciphertext = packed.copyOfRange(1 + ivSize, packed.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secureKey(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8)
    }

    private fun secureKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = keyStore.getKey(SECURE_KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                SECURE_KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (rejectLegacyConsumableNfcCall(call, result)) return
        when (call.method) {
            "getStatus" -> result.success(statusMap())
            "beginScan" -> beginScan(call, result)
            "beginReadAmsTemplate" -> beginAmsTemplate(call, result, restore = false)
            "beginRestoreAmsTemplate" -> beginAmsTemplate(call, result, restore = true)
            "cancel" -> cancel(call, result)
            "getOperationState" -> getOperationState(call, result)
            else -> result.notImplemented()
        }
    }

    private fun beginAmsTemplate(call: MethodCall, result: MethodChannel.Result, restore: Boolean) {
        val operationId = call.argument<String>("operationId")?.trim().orEmpty()
        if (operationId.isEmpty() || operationId.length > 96) {
            result.error(ERROR_INVALID_PAYLOAD, "operationId is required", null)
            return
        }
        val template = try {
            val supplied = call.argument<Map<*, *>>(if (restore) "template" else "keyTemplate")
            if (restore || supplied != null) AmsTemplate.parse(supplied) else null
        } catch (failure: AmsTemplateFailure) {
            result.error(failure.code, failure.message, null)
            return
        }
        val kind = call.argument<String>("targetKind")?.lowercase(Locale.ROOT)
        if (restore && (call.argument<Boolean>("allowUidChange") != true ||
                kind !in listOf("cuid", "fuid"))) {
            result.error("UID_CHANGE_CONFIRMATION_REQUIRED",
                "必须确认所购 CUID/FUID 标签及 UID 写入风险；FUID 的 UID 写入不可逆", null)
            return
        }
        val adapter = nfcAdapter
        if (adapter == null || !adapter.isEnabled) {
            result.error(if (adapter == null) ERROR_NFC_UNAVAILABLE else ERROR_NFC_DISABLED,
                if (adapter == null) "此设备不支持 NFC" else "请先打开系统 NFC", null)
            return
        }
        val operation = PendingOperation(
            id = operationId,
            mode = if (restore) OperationMode.RESTORE_AMS_TEMPLATE else OperationMode.READ_AMS_TEMPLATE,
            template = template, targetKind = kind,
        )
        synchronized(operationLock) {
            if (pendingOperation != null || processingTag.get() || deviceTagNfc?.isBusy() == true) {
                result.error(ERROR_NFC_BUSY, "已有 NFC 操作进行中", null)
                return
            }
            pendingOperation = operation
            // Do not retain an earlier sensitive template read in the state cache.
            lastTerminalEvent = null
        }
        enableReaderModeIfNeeded()
        emitEvent(operation, STATE_AWAITING_TAG, message = if (restore) {
            "请贴紧已确认的 CUID/FUID，完成 UID 写入后需移开再贴进行全卡校验"
        } else {
            "请贴紧你有权使用的有效拓竹来源标签，正在等待读取完整本机模板"
        })
        // Native watchdog also covers Flutter being unresponsive while a tag is
        // being reselected. ReaderMode is only enabled for an explicit operation.
        mainHandler.postDelayed({
            if (isOperationActive(operation)) {
                terminatePendingOperation(
                    STATE_CANCELLED,
                    AmsTemplateTimeoutPolicy.TIMEOUT_CODE,
                    AmsTemplateTimeoutPolicy.timeoutMessage(operation.blocksWritten),
                )
                disableReaderMode()
            }
        }, AmsTemplateTimeoutPolicy.watchdogMillis(restore))
        result.success(mapOf("operationId" to operation.id, "state" to STATE_AWAITING_TAG))
    }

    /** Starts a read-only MIFARE Classic metadata scan for batch inventory. */
    private fun beginScan(call: MethodCall, result: MethodChannel.Result) {
        val operationId = call.argument<String>("operationId")?.trim().orEmpty()
        if (operationId.isEmpty() || operationId.length > 96) {
            result.error(ERROR_INVALID_PAYLOAD, "operationId is required", null)
            return
        }
        val profile = call.argument<String>("profile")?.trim()?.lowercase(Locale.ROOT)
        if (profile != null && profile.isNotEmpty() &&
            profile != "mifareclassic" && profile != "mifare_classic" &&
            profile != "cuid_fuid"
        ) {
            result.error(ERROR_INVALID_PAYLOAD, "未知的 NFC 扫描模式", null)
            return
        }
        val adapter = nfcAdapter
        if (adapter == null) {
            result.error(ERROR_NFC_UNAVAILABLE, "This device has no NFC adapter", null)
            return
        }
        if (!adapter.isEnabled) {
            result.error(ERROR_NFC_DISABLED, "NFC is disabled on this device", null)
            return
        }

        val operation = PendingOperation(
            id = operationId,
            mode = OperationMode.SCAN_MIFARE,
        )
        synchronized(operationLock) {
            if (pendingOperation != null || processingTag.get() || deviceTagNfc?.isBusy() == true) {
                result.error(
                    ERROR_NFC_BUSY,
                    "Another RFID operation is active; wait for it to finish",
                    null,
                )
                return
            }
            pendingOperation = operation
        }

        enableReaderModeIfNeeded()
        emitEvent(
            operation,
            state = STATE_AWAITING_TAG,
            message = "请将 MIFARE Classic CUID/FUID 标签靠近手机背面",
            amsCompatibility = "not_verified",
        )
        result.success(
            mapOf(
                "operationId" to operation.id,
                "state" to STATE_AWAITING_TAG,
                "profile" to "mifareClassic",
            ),
        )
    }

    private fun cancel(call: MethodCall, result: MethodChannel.Result) {
        val operationId = call.argument<String>("operationId")?.trim().orEmpty()
        val operation = synchronized(operationLock) {
            val current = pendingOperation
            if (current == null || current.id != operationId) {
                null
            } else {
                current.cancelled = true
                current.state = STATE_CANCELLED
                pendingOperation = null
                current
            }
        }
        if (operation == null) {
            val terminal = synchronized(operationLock) {
                lastTerminalEvent?.takeIf { it["operationId"] == operationId }
            }
            if (terminal != null) {
                result.success(terminal)
            } else {
                result.error(ERROR_OPERATION_NOT_FOUND, "No matching RFID operation", null)
            }
            return
        }

        disableReaderMode()
        emitEvent(
            operation,
            state = STATE_CANCELLED,
            code = ERROR_OPERATION_CANCELLED,
            message = "RFID 操作已取消",
            force = true,
        )
        result.success(
            mapOf(
                "operationId" to operation.id,
                "state" to STATE_CANCELLED,
                "code" to ERROR_OPERATION_CANCELLED,
                "message" to "RFID 操作已取消",
                "amsCompatibility" to "not_verified",
            ),
        )
    }

    private fun getOperationState(call: MethodCall, result: MethodChannel.Result) {
        val requestedId = call.argument<String>("operationId")?.trim().orEmpty()
        val operation = synchronized(operationLock) { pendingOperation }
        if (operation == null || (requestedId.isNotEmpty() && operation.id != requestedId)) {
            val terminal = synchronized(operationLock) {
                lastTerminalEvent?.takeIf {
                    requestedId.isNotEmpty() && it["operationId"] == requestedId
                }
            }
            result.success(terminal ?: mapOf("state" to STATE_IDLE))
            return
        }
        result.success(
            mapOf(
                "operationId" to operation.id,
                "state" to operation.state,
            ),
        )
    }

    private fun statusMap(): Map<String, Any?> {
        val adapter = nfcAdapter
        val operationId = synchronized(operationLock) { pendingOperation?.id }
        return mapOf(
            "available" to (adapter != null),
            "enabled" to (adapter?.isEnabled == true),
            "readerModeEnabled" to readerModeEnabled,
            "activeOperationId" to operationId,
        )
    }

    private fun enableReaderModeIfNeeded() {
        if (!activityResumed || readerModeEnabled) return
        val adapter = nfcAdapter ?: return
        if (!adapter.isEnabled) {
            val operation = synchronized(operationLock) { pendingOperation }
            if (operation != null) {
                finishOperation(
                    operation,
                    state = STATE_FAILED,
                    code = ERROR_NFC_DISABLED,
                    message = "NFC 已关闭，请在系统设置中重新开启",
                    amsCompatibility = "not_verified",
                )
            }
            return
        }
        try {
            adapter.enableReaderMode(
                this,
                { tag -> onTagDiscovered(tag) },
                NFC_FLAGS,
                Bundle(),
            )
            readerModeEnabled = true
        } catch (_: RuntimeException) {
            readerModeEnabled = false
            val operation = synchronized(operationLock) { pendingOperation }
            if (operation != null) {
                finishOperation(
                    operation,
                    state = STATE_FAILED,
                    code = ERROR_NFC_DISABLED,
                    message = "无法启用 NFC 阅读模式，请检查系统 NFC 设置",
                    amsCompatibility = "not_verified",
                )
            }
        }
    }

    private fun disableReaderMode() {
        if (!readerModeEnabled) return
        try {
            nfcAdapter?.disableReaderMode(this)
        } catch (_: RuntimeException) {
            // The activity may already be leaving; state cleanup is still safe.
        }
        readerModeEnabled = false
    }

    private fun onTagDiscovered(tag: Tag) {
        val operation = synchronized(operationLock) { pendingOperation }
        if (operation == null || operation.cancelled) return
        if (!processingTag.compareAndSet(false, true)) return

        try {
            ioExecutor.execute {
                try {
                    inspectTag(operation, tag)
                } catch (error: TagLostException) {
                    // Every inspection path normally handles tag loss itself,
                    // but keep the executor boundary defensive: an
                    // unexpected metadata/read exception must never leave a
                    // pending operation (and reader mode) hanging forever.
                    finishUnexpectedInspectionError(operation, error)
                } catch (error: IOException) {
                    finishUnexpectedInspectionError(operation, error)
                } catch (error: RuntimeException) {
                    finishUnexpectedInspectionError(operation, error)
                } finally {
                    processingTag.set(false)
                }
            }
        } catch (error: RejectedExecutionException) {
            processingTag.set(false)
            // This normally only occurs while the Activity is being
            // destroyed. If an operation is still active, complete it rather
            // than leaving Flutter waiting for a callback that can never run.
            if (isOperationActive(operation)) {
                finishOperation(
                    operation,
                    state = STATE_FAILED,
                    code = ERROR_WRITE_FAILED,
                    message = "NFC 任务无法启动，请重新尝试",
                    amsCompatibility = "not_verified",
                )
            }
        }
    }

    /**
     * Completes an operation when an inspection path raises an exception it
     * did not already translate into a terminal event. This is intentionally
     * kept at the native executor boundary so a malformed/removed tag cannot
     * strand [pendingOperation] and leave ReaderMode enabled indefinitely.
     */
    private fun finishUnexpectedInspectionError(
        operation: PendingOperation,
        error: Exception,
    ) {
        val code = when (operation.mode) {
            OperationMode.SCAN_MIFARE -> ERROR_SCAN_UNSUPPORTED
            OperationMode.READ_AMS_TEMPLATE -> ERROR_READ_UNSUPPORTED
            OperationMode.RESTORE_AMS_TEMPLATE -> ERROR_WRITE_FAILED
        }
        val action = when (operation.mode) {
            OperationMode.SCAN_MIFARE -> "扫描"
            OperationMode.READ_AMS_TEMPLATE -> "读取模板"
            OperationMode.RESTORE_AMS_TEMPLATE -> "恢复模板"
        }
        val message = when (error) {
            is TagLostException -> "标签在${action}时移开，请保持手机与标签贴合"
            // Platform exception details may contain transceive bytes. Never
            // expose raw blocks, derived keys or template material in errors.
            else -> "NFC 标签${action}失败，请重新贴紧标签后重试"
        }
        finishOperation(
            operation,
            state = STATE_FAILED,
            code = code,
            message = message,
            amsCompatibility = "not_verified",
        )
    }

    private fun terminatePendingOperation(
        state: String,
        code: String,
        message: String,
    ) {
        val operation = synchronized(operationLock) {
            val current = pendingOperation ?: return@synchronized null
            current.cancelled = true
            current.state = state
            pendingOperation = null
            current
        } ?: return
        emitEvent(
            operation,
            state = state,
            code = code,
            message = message,
            force = true,
        )
    }

    private fun inspectTag(operation: PendingOperation, tag: Tag) {
        if (!isOperationActive(operation)) return

        if (operation.mode == OperationMode.READ_AMS_TEMPLATE ||
            operation.mode == OperationMode.RESTORE_AMS_TEMPLATE) {
            inspectAmsTemplate(operation, tag)
            return
        }

        if (operation.mode == OperationMode.SCAN_MIFARE) {
            val mifare = try {
                MifareClassic.get(tag)
            } catch (_: RuntimeException) {
                null
            }
            if (mifare == null) {
                finishOperation(
                    operation,
                    state = STATE_FAILED,
                    code = ERROR_SCAN_UNSUPPORTED,
                    message = "CUID/FUID 扫描只支持 MIFARE Classic 标签",
                    amsCompatibility = "not_verified",
                )
            } else {
                inspectMifareScanTag(operation, tag, mifare)
            }
            return
        }
    }

    private fun inspectAmsTemplate(operation: PendingOperation, tag: Tag) {
        val mifare = try { MifareClassic.get(tag) } catch (_: RuntimeException) { null }
        if (mifare == null || mifare.size != MifareClassic.SIZE_1K ||
            mifare.sectorCount != 16 || tag.id.size != 4) {
            finishOperation(operation, STATE_FAILED, ERROR_UNSUPPORTED_TAG,
                "此手机/标签不支持 MIFARE Classic 1K 完整读写（仅有 NFC 并不代表支持 Classic）",
                amsCompatibility = "not_verified")
            return
        }
        val uid = amsHex(tag.id)
        val template = operation.template
        if (operation.awaitingReselect && template?.uid != uid) {
            operation.state = "awaiting_reselect"
            emitEvent(operation, "awaiting_reselect", code = "UID_RESELECT_REQUIRED",
                message = "还未读到模板对应的新 UID，请将刚才写入的标签完全移开后重新贴紧；不要更换其他标签")
            return
        }
        // A removal callback may arrive after discovery of the newly selected
        // tag. It must not reset ReaderMode during this new connection.
        operation.awaitingReselect = false
        val base = mapOf<String, Any?>(
            "uid" to uid, "technology" to "MIFARE_CLASSIC", "sizeBytes" to 1024,
            "uidLengthBytes" to 4, "sectorCount" to 16, "blockCount" to 64,
            "type" to (operation.targetKind?.uppercase(Locale.ROOT) ?: "MIFARE_CLASSIC_1K"),
            "carrierTypeSource" to if (operation.targetKind == null) "technology_only" else "user_declared",
        )
        val alreadyWritten = operation.blocksWritten
        var reselectAfterClose = false
        val engine = AmsTemplateEngine(
            checkActive = {
                if (!isOperationActive(operation)) throw AmsTemplateFailure(ERROR_OPERATION_CANCELLED, "NFC 操作已取消")
            },
            progress = { stage, count ->
                val state = when (stage) {
                    "writing" -> STATE_WRITING
                    "awaiting_reselect" -> "awaiting_reselect"
                    else -> STATE_VERIFYING
                }
                operation.state = state
                if (stage == "writing" || stage == "awaiting_reselect") {
                    operation.blocksWritten = alreadyWritten + count
                }
                val message = when (stage) {
                    "reading" -> "正在读取完整模板：$count / 64 块（仅保存在本机）"
                    "preflight" -> "正在检查全部扇区的密钥和写入权限：$count / 16"
                    "writing" -> "正在恢复原始模板，请保持贴紧；不要移动标签"
                    "awaiting_reselect" -> "UID 写入已提交，请完全移开标签，再贴回以确认新 UID 和全卡内容"
                    else -> "正在验证原始内容、密钥和访问权限，请保持贴紧"
                }
                emitEvent(operation, state, message = message, tag = base)
            },
        )
        try {
            mifare.connect()
            mifare.timeout = 1500
            val io = object : AmsMifareIo {
                // A new Android Tag object is the only source of verified UID.
                override val uid: ByteArray = tag.id.copyOf()
                override fun authenticateA(sector: Int, key: ByteArray): Boolean = try {
                    mifare.authenticateSectorWithKeyA(sector, key)
                } catch (lost: TagLostException) { throw lost
                } catch (_: IOException) { false }
                override fun authenticateB(sector: Int, key: ByteArray): Boolean = try {
                    mifare.authenticateSectorWithKeyB(sector, key)
                } catch (lost: TagLostException) { throw lost
                } catch (_: IOException) { false }
                override fun read(block: Int): ByteArray = mifare.readBlock(block)
                override fun write(block: Int, data: ByteArray) = mifare.writeBlock(block, data)
            }
            if (operation.mode == OperationMode.READ_AMS_TEMPLATE) {
                val read = engine.readTemplate(io, template)
                finishOperation(operation, "template_read_success", "TEMPLATE_READ_OK",
                    "完整来源模板读取成功，仅供本机恢复使用；未进行 AMS 实机验证",
                    tag = base + mapOf("bytesRead" to 1024, "blocksVerified" to 64,
                        "verification" to "passed", "trayIdentity" to amsHex(read.block(9))),
                    templatePayload = read.toMap(), amsCompatibility = "source_template_unverified")
                return
            }
            if (template == null) throw AmsTemplateFailure("AMS_TEMPLATE_REQUIRED", "没有选择完整来源模板")
            val outcome = engine.restore(io, template, allowUidChange = true,
                targetKind = operation.targetKind.orEmpty())
            operation.blocksWritten = alreadyWritten + engine.blocksWritten
            if (outcome == AmsRestoreResult.RESELECT_REQUIRED) {
                operation.awaitingReselect = true
                reselectAfterClose = true
                operation.state = "awaiting_reselect"
                // No terminal event and no synthetic UID: the next discovery
                // callback must carry a fresh tag with the restored UID.
                emitEvent(operation, "awaiting_reselect", code = "UID_RESELECT_REQUIRED",
                    message = "请将标签完全移开后再贴回，确认新 UID 并完成最后校验；当前尚未成功",
                    tag = base + mapOf("blocksWritten" to operation.blocksWritten))
                return
            }
            finishOperation(operation, "success", "TEMPLATE_RESTORED",
                "完整模板已恢复，新 UID、全卡内容和密钥权限已校验；请再放入 AMS 实测",
                tag = base + mapOf("blocksWritten" to operation.blocksWritten,
                    "blocksVerified" to 64, "bytesWritten" to operation.blocksWritten * 16,
                    "verification" to "passed", "trayIdentity" to amsHex(template.block(9))),
                amsCompatibility = "template_restored_unverified")
        } catch (failure: AmsTemplateFailure) {
            finishOperation(operation, STATE_FAILED, failure.code,
                failure.message ?: "模板操作失败", tag = base + mapOf(
                    "blocksWritten" to (alreadyWritten + engine.blocksWritten)), amsCompatibility = "not_verified")
        } catch (_: TagLostException) {
            finishOperation(operation, STATE_FAILED, ERROR_TAG_LOST,
                "标签连接中断；恢复时可能已部分写入，请保留同一模板并重新检查，不能视为成功",
                tag = base, amsCompatibility = "not_verified")
        } catch (_: IOException) {
            finishOperation(operation, STATE_FAILED, ERROR_WRITE_FAILED,
                "标签拒绝读写或连接中断；可能已部分写入。请确认卡型及 FUID 是否已锁定，再使用同一模板重试",
                tag = base, amsCompatibility = "not_verified")
        } catch (_: RuntimeException) {
            finishOperation(operation, STATE_FAILED, ERROR_WRITE_FAILED,
                "手机 NFC 无法完成模板操作，未确认写入成功；请保留模板并重新检查标签",
                tag = base, amsCompatibility = "not_verified")
        } finally {
            try { mifare.close() } catch (_: Exception) { /* No sensitive logging. */ }
            if (reselectAfterClose) rearmAfterTagRemoval(operation, tag)
        }
    }

    private fun rearmAfterTagRemoval(operation: PendingOperation, oldTag: Tag) {
        mainHandler.post {
            if (!isOperationActive(operation) || !activityResumed || !operation.awaitingReselect) return@post
            fun rearm() {
                if (!isOperationActive(operation) || !activityResumed || !operation.awaitingReselect) return
                disableReaderMode()
                enableReaderModeIfNeeded()
            }
            // API 24+: debounce physical removal and restart reader mode once
            // removed. No re-authentication is attempted with stale Android UID.
            val ignored = try {
                nfcAdapter?.ignore(oldTag, 350, { rearm() }, mainHandler) == true
            } catch (_: RuntimeException) { false }
            // false also means the user already removed the card; a fresh
            // discovery session is still needed in that case.
            if (!ignored) rearm()
        }
    }

    /**
     * Reads only public tag metadata and default-key readability. No block
     * contents, keys, UID writes, or vendor dumps cross this boundary.
     */
    private fun inspectMifareScanTag(
        operation: PendingOperation,
        tag: Tag,
        mifare: MifareClassic,
    ) {
        if (!isOperationActive(operation)) return

        val sizeBytes = try {
            mifare.size
        } catch (_: RuntimeException) {
            finishOperation(
                operation,
                state = STATE_FAILED,
                code = ERROR_TAG_LOST,
                message = "无法读取 MIFARE 标签容量，请保持手机与标签贴合",
                amsCompatibility = "not_verified",
            )
            return
        }
        val uidBytes = try {
            tag.id
        } catch (_: RuntimeException) {
            finishOperation(
                operation,
                state = STATE_FAILED,
                code = ERROR_TAG_LOST,
                message = "无法读取 MIFARE 标签 UID，请保持手机与标签贴合",
                amsCompatibility = "not_verified",
            )
            return
        }
        val sectorCount = try {
            mifare.sectorCount
        } catch (_: RuntimeException) {
            finishOperation(
                operation,
                state = STATE_FAILED,
                code = ERROR_TAG_LOST,
                message = "无法读取 MIFARE 标签扇区信息，请保持手机与标签贴合",
                amsCompatibility = "not_verified",
            )
            return
        }
        val baseTagInfo = mapOf<String, Any?>(
            "technology" to "MIFARE_CLASSIC",
            "type" to mifareTypeName(mifare.type),
            "sizeBytes" to sizeBytes,
            "blockCount" to (sizeBytes / MifareClassic.BLOCK_SIZE),
            "sectorCount" to sectorCount,
            "uid" to uidBytes.joinToString("") { "%02X".format(it) },
            "uidLengthBytes" to uidBytes.size,
        )

        // The AMS carrier workflow is deliberately constrained to the
        // 1-KiB/4-byte-UID shape used by CUID/FUID media. Reporting a larger
        // or differently shaped Classic card as a usable batch tag would make
        // the later write path fail after the user has already collected it.
        if (sizeBytes != MifareClassic.SIZE_1K || uidBytes.size != 4) {
            finishOperation(
                operation,
                state = STATE_FAILED,
                code = ERROR_SCAN_UNSUPPORTED,
                message = "请使用 MIFARE Classic 1K、4 字节 UID 的 CUID/FUID 标签",
                tag = baseTagInfo,
                amsCompatibility = "not_verified",
            )
            return
        }

        emitEvent(
            operation,
            state = STATE_TAG_DETECTED,
            message = "已检测到 MIFARE Classic 标签，正在读取标签信息",
            tag = baseTagInfo,
            amsCompatibility = "not_verified",
        )

        var connected = false
        var authenticatedSectors = 0
        var readableSectors = 0
        var readableBlocks = 0
        try {
            mifare.connect()
            connected = true
            emitEvent(
                operation,
                state = STATE_VERIFYING,
                message = "正在检测默认密钥可读数据块",
                tag = baseTagInfo,
                amsCompatibility = "not_verified",
            )
            for (sector in 0 until sectorCount) {
                if (!isOperationActive(operation)) return
                if (!authenticateSector(mifare, sector)) continue
                authenticatedSectors += 1
                val firstBlock = mifare.sectorToBlock(sector)
                val blockCount = mifare.getBlockCountInSector(sector)
                // Block 0 is the manufacturer/UID block and must never be
                // read or written as ordinary payload. Sector trailers also
                // contain keys/access bits; only probe a normal data block.
                if (blockCount <= 1) continue
                val dataBlock = if (firstBlock == 0) firstBlock + 1 else firstBlock
                // Read one ordinary data block per authenticated sector. The
                // contents are intentionally discarded and never serialized.
                try {
                    mifare.readBlock(dataBlock)
                    readableSectors += 1
                    readableBlocks += 1
                } catch (_: TagLostException) {
                    throw TagLostException()
                } catch (_: IOException) {
                    // A sector can authenticate but still reject reads due to
                    // access bits; keep scanning the remaining sectors.
                } catch (_: SecurityException) {
                    // Same as above: report metadata and continue safely.
                } catch (_: RuntimeException) {
                    // Some vendor cards throw a runtime error for a protected
                    // data block. No raw content is needed for this scan.
                }
            }
            val tagInfo = baseTagInfo + mapOf<String, Any?>(
                "defaultKeyAuthenticatedSectors" to authenticatedSectors,
                "defaultKeyReadableSectors" to readableSectors,
                "defaultKeyReadableBlocks" to readableBlocks,
                "defaultKeyReadable" to (readableBlocks > 0),
                "verification" to "metadata_only",
            )
            finishOperation(
                operation,
                state = STATE_SCAN_SUCCESS,
                code = "SCAN_OK",
                message = "MIFARE Classic 标签信息读取成功",
                tag = tagInfo,
                amsCompatibility = "not_verified",
            )
        } catch (_: TagLostException) {
            finishOperation(
                operation,
                state = STATE_FAILED,
                code = ERROR_TAG_LOST,
                message = "标签在读取时移开，请保持手机与标签贴合",
                tag = baseTagInfo,
                amsCompatibility = "not_verified",
            )
        } catch (error: IOException) {
            finishOperation(
                operation,
                state = STATE_FAILED,
                code = ERROR_SCAN_UNSUPPORTED,
                message = "MIFARE 标签读取失败：${error.message ?: "I/O 错误"}",
                tag = baseTagInfo,
                amsCompatibility = "not_verified",
            )
        } catch (error: RuntimeException) {
            finishOperation(
                operation,
                state = STATE_FAILED,
                code = ERROR_SCAN_UNSUPPORTED,
                message = "MIFARE 标签读取失败：${error.message ?: "未知错误"}",
                tag = baseTagInfo,
                amsCompatibility = "not_verified",
            )
        } finally {
            if (connected) {
                try {
                    mifare.close()
                } catch (_: IOException) {
                    // The tag may already have been removed.
                }
            }
        }
    }

    private fun authenticateSector(mifare: MifareClassic, sector: Int): Boolean {
        return try {
            // Blank MIFARE Classic cards conventionally use FF as the
            // transport key. Try it once per sector and never brute-force
            // arbitrary keys.
            mifare.authenticateSectorWithKeyA(sector, DEFAULT_MIFARE_KEY) ||
                mifare.authenticateSectorWithKeyB(sector, DEFAULT_MIFARE_KEY)
        } catch (error: TagLostException) {
            // A removed tag is not an ordinary authentication miss. Let the
            // caller surface TAG_LOST instead of reporting a misleading
            // metadata scan with zero authenticated sectors.
            throw error
        } catch (_: SecurityException) {
            false
        } catch (_: IOException) {
            false
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun finishOperation(
        operation: PendingOperation,
        state: String,
        code: String,
        message: String,
        tag: Map<String, Any?>? = null,
        templatePayload: Map<String, Any?>? = null,
        amsCompatibility: String,
    ) {
        val shouldFinish = synchronized(operationLock) {
            if (pendingOperation?.id != operation.id || operation.cancelled) {
                false
            } else {
                operation.state = state
                pendingOperation = null
                true
            }
        }
        if (!shouldFinish) return

        val terminalEvent = eventMap(
            operation = operation,
            state = state,
            code = code,
            message = message,
            tag = tag,
            amsCompatibility = amsCompatibility,
        )
        if (templatePayload != null) terminalEvent["template"] = templatePayload
        // Publish the terminal state before posting the Flutter callback. A
        // cancel request can arrive in this small hand-off window and must
        // observe the actual result rather than manufacture a cancellation.
        rememberTerminalEvent(terminalEvent)
        mainHandler.post {
            // A new operation may have started before this callback reached
            // the main thread. Only the operation that owns reader mode may
            // disable it; otherwise an old completion callback can silently
            // stop the new scan/write session.
            val ownsReaderMode = synchronized(operationLock) {
                pendingOperation == null || pendingOperation?.id == operation.id
            }
            if (ownsReaderMode) disableReaderMode()
            channel?.invokeMethod(EVENT_METHOD, terminalEvent)
        }
    }

    private fun isOperationActive(operation: PendingOperation): Boolean {
        return synchronized(operationLock) {
            pendingOperation?.id == operation.id && !operation.cancelled
        }
    }

    private fun emitEvent(
        operation: PendingOperation,
        state: String,
        code: String? = null,
        message: String? = null,
        tag: Map<String, Any?>? = null,
        amsCompatibility: String = "not_verified",
        force: Boolean = false,
    ) {
        if (!force && !isOperationActive(operation)) return
        val event = eventMap(
            operation = operation,
            state = state,
            code = code,
            message = message,
            tag = tag,
            amsCompatibility = amsCompatibility,
        )
        rememberTerminalEvent(event)
        mainHandler.post {
            channel?.invokeMethod(EVENT_METHOD, event)
        }
    }

    private fun emitEventNow(
        operation: PendingOperation,
        state: String,
        code: String? = null,
        message: String? = null,
        force: Boolean = false,
    ) {
        if (!force && !isOperationActive(operation)) return
        val event = eventMap(
            operation = operation,
            state = state,
            code = code,
            message = message,
            amsCompatibility = "not_verified",
        )
        rememberTerminalEvent(event)
        channel?.invokeMethod(EVENT_METHOD, event)
    }

    private fun eventMap(
        operation: PendingOperation,
        state: String,
        code: String? = null,
        message: String? = null,
        tag: Map<String, Any?>? = null,
        amsCompatibility: String,
    ): MutableMap<String, Any?> {
        val event = mutableMapOf<String, Any?>(
            "event" to "state",
            "operationId" to operation.id,
            "state" to state,
            "amsCompatibility" to amsCompatibility,
        )
        if (code != null) event["code"] = code
        if (message != null) event["message"] = message
        if (tag != null) {
            event["tag"] = tag
            // Keep common terminal metadata at the top level as well as in
            // the nested tag object. Older Flutter hosts only read the
            // nested shape; newer hosts can render these fields directly.
            tag["technology"]?.let { event["technology"] = it }
            tag["type"]?.let { event["tagType"] = it }
            tag["uid"]?.let { event["tagId"] = it }
            tag["sizeBytes"]?.let { event["sizeBytes"] = it }
            tag["blocksWritten"]?.let { event["blocksWritten"] = it }
            tag["blocksVerified"]?.let { event["blocksVerified"] = it }
            tag["writableBlocks"]?.let { event["writableBlocks"] = it }
            tag["bytesWritten"]?.let { event["bytesWritten"] = it }
            tag["pageSizeBytes"]?.let { event["pageSizeBytes"] = it }
            tag["pageCount"]?.let { event["pageCount"] = it }
            tag["dataStartPage"]?.let { event["dataStartPage"] = it }
            tag["verification"]?.let { event["verification"] = it }
            tag["bytesRead"]?.let { event["bytesRead"] = it }
            tag["pagesRead"]?.let { event["pagesRead"] = it }
            tag["uidLengthBytes"]?.let { event["uidLengthBytes"] = it }
            tag["blockCount"]?.let { event["blockCount"] = it }
            tag["sectorCount"]?.let { event["sectorCount"] = it }
            tag["trayIdentity"]?.let { event["trayIdentity"] = it }
            tag["defaultKeyAuthenticatedSectors"]?.let {
                event["defaultKeyAuthenticatedSectors"] = it
            }
            tag["defaultKeyReadableSectors"]?.let {
                event["defaultKeyReadableSectors"] = it
            }
            tag["defaultKeyReadableBlocks"]?.let {
                event["defaultKeyReadableBlocks"] = it
            }
            tag["defaultKeyReadable"]?.let { event["defaultKeyReadable"] = it }
            if ((state == "success" || state == "template_read_success" ||
                    state == STATE_SCAN_SUCCESS) &&
                tag["verification"] == "passed"
            ) {
                event["verified"] = true
            }
        }
        val tagId = tag?.get("uid") as? String
        if (!tagId.isNullOrBlank()) event["tagId"] = tagId
        return event
    }

    private fun rememberTerminalEvent(event: Map<String, Any?>) {
        val state = event["state"] as? String ?: return
        if (state != STATE_FAILED && state != STATE_CANCELLED &&
            state != "success" &&
            state != "template_read_success" &&
            state != STATE_SCAN_SUCCESS
        ) return
        synchronized(operationLock) {
            lastTerminalEvent = event.toMap()
        }
    }

    private fun mifareTypeName(type: Int): String {
        return when (type) {
            MifareClassic.TYPE_CLASSIC -> "CLASSIC"
            MifareClassic.TYPE_PLUS -> "PLUS"
            MifareClassic.TYPE_PRO -> "PRO"
            MifareClassic.TYPE_UNKNOWN -> "UNKNOWN"
            else -> "UNKNOWN"
        }
    }
}

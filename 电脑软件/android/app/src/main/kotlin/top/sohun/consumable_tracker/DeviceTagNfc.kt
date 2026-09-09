package top.sohun.consumable_tracker

import android.app.Activity
import android.content.Intent
import android.nfc.NdefMessage
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.TagLostException
import android.nfc.tech.Ndef
import android.nfc.tech.NfcA
import android.nfc.tech.TagTechnology
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/** NTAG213 device shortcuts are deliberately isolated from consumable NFC. */
internal class DeviceTagNfc(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val otherNfcBusy: () -> Boolean,
) {
    private class Operation(val id: String, val token: String?) {
        @Volatile var cancelled = false
        var timeout: Runnable? = null
    }

    private val channel = MethodChannel(messenger, "top.sohun/device_tag")
    private val adapter = NfcAdapter.getDefaultAdapter(activity.applicationContext)
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val lock = Any()
    private val processing = AtomicBoolean(false)
    private var pending: Operation? = null
    private var terminal: Map<String, Any?>? = null
    private var pendingUri: String? = null
    private var lastIntent: Intent? = null
    private var resumed = false
    private var readerEnabled = false
    private var destroyed = false
    @Volatile private var connectedTechnology: TagTechnology? = null

    init {
        channel.setMethodCallHandler(::handleCall)
        onNewIntent(activity.intent)
    }

    fun isBusy(): Boolean = synchronized(lock) { pending != null } || processing.get() || readerEnabled

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getStatus" -> result.success(mapOf(
                "available" to (adapter != null),
                "enabled" to (adapter?.isEnabled == true),
                "busy" to (isBusy() || otherNfcBusy()),
            ))
            "beginRead" -> begin(call, result, writing = false)
            "beginWrite" -> begin(call, result, writing = true)
            "cancel" -> cancel(call, result)
            "takePendingDeviceUri" -> {
                val value = pendingUri
                pendingUri = null
                result.success(value)
            }
            else -> result.notImplemented()
        }
    }

    private fun begin(call: MethodCall, result: MethodChannel.Result, writing: Boolean) {
        val supplied = call.arguments as? Map<*, *>
        val allowed = if (writing) setOf("operationId", "deviceToken") else setOf("operationId")
        if (supplied == null || supplied.keys.any { it !in allowed }) {
            result.error("INVALID_PAYLOAD", "设备标签接口只接受设备定位标识", null)
            return
        }
        val id = supplied["operationId"] as? String
        val token = supplied["deviceToken"] as? String
        if (id.isNullOrBlank() || id.length > 96 || (writing && token == null)) {
            result.error("INVALID_PAYLOAD", "设备标签请求格式无效", null)
            return
        }
        try {
            if (writing) DeviceTagProtocol.uriFor(token!!)
        } catch (failure: DeviceTagFailure) {
            result.error(failure.code, failure.message, null)
            return
        }
        if (destroyed || !resumed) {
            result.error("OPERATION_CANCELLED", "请返回前台后重新开始 NFC 操作", null)
            return
        }
        if (adapter == null || !adapter.isEnabled) {
            result.error(if (adapter == null) "NFC_UNAVAILABLE" else "NFC_DISABLED",
                if (adapter == null) "此手机不支持 NFC" else "请先打开系统 NFC", null)
            return
        }
        val operation = Operation(id, if (writing) token else null)
        synchronized(lock) {
            if (pending != null || processing.get() || readerEnabled || otherNfcBusy()) {
                result.error("NFC_BUSY", "已有 NFC 操作进行中，请先完成或取消", null)
                return
            }
            pending = operation
            terminal = null
        }
        try {
            // Keep Android's NDEF discovery enabled; SKIP_NDEF_CHECK would hide
            // the Ndef technology needed by the safe NDEF writer.
            adapter.enableReaderMode(activity, ::onTagDiscovered,
                NfcAdapter.FLAG_READER_NFC_A, Bundle())
            readerEnabled = true
        } catch (_: RuntimeException) {
            finish(operation, "failed", "NFC_DISABLED", "无法启用 NFC，请检查系统设置")
            result.error("NFC_DISABLED", "无法启用 NFC，请检查系统设置", null)
            return
        }
        operation.timeout = Runnable {
            finish(operation, "cancelled", "OPERATION_TIMEOUT", "NFC 操作超时，请重新开始")
            closeConnectedTechnology()
        }.also { main.postDelayed(it, 60_000) }
        emit(operation, "awaiting_tag")
        result.success(mapOf("operationId" to id, "state" to "awaiting_tag"))
    }

    private fun cancel(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("operationId")
        val operation = synchronized(lock) { pending?.takeIf { it.id == id } }
        if (operation != null) {
            finish(operation, "cancelled", "OPERATION_CANCELLED", "NFC 操作已取消；写入中断时请重新校验标签")
            closeConnectedTechnology()
        }
        val outcome = synchronized(lock) { terminal?.takeIf { it["operationId"] == id } }
        if (outcome != null) result.success(outcome)
        else result.error("OPERATION_NOT_FOUND", "没有对应的 NFC 操作", null)
    }

    fun onResume() { resumed = true }

    fun onPause() {
        resumed = false
        synchronized(lock) { pending }?.let {
            finish(it, "cancelled", "OPERATION_CANCELLED", "NFC 操作已暂停，请回到页面重新开始")
        }
        disableReader()
        closeConnectedTechnology()
    }

    fun dispose() {
        onPause()
        destroyed = true
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
        pendingUri = null
        lastIntent = null
    }

    /** Launch links are locators only; Flutter rechecks account/device access. */
    fun onNewIntent(intent: Intent?) {
        if (intent == null || intent === lastIntent) return
        lastIntent = intent
        if (intent.action != Intent.ACTION_VIEW && intent.action != NfcAdapter.ACTION_NDEF_DISCOVERED) return
        var value = intent.dataString
        if (value == null && intent.action == NfcAdapter.ACTION_NDEF_DISCOVERED) {
            @Suppress("DEPRECATION")
            val messages = intent.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES)
            val message = messages?.singleOrNull() as? NdefMessage
            value = message?.let { DeviceTagProtocol.uriFromMessage(it.toByteArray()) }
        }
        val token = value?.let(DeviceTagProtocol::tokenFromUri) ?: return
        val uri = DeviceTagProtocol.uriFor(token)
        pendingUri = uri
        channel.invokeMethod("deviceUri", uri)
    }

    private fun onTagDiscovered(tag: Tag) {
        val operation = synchronized(lock) { pending } ?: return
        if (!isActive(operation) || !processing.compareAndSet(false, true)) return
        try {
            executor.execute {
                try {
                    emit(operation, "tag_detected")
                    val verified = DeviceTagOperation.execute(AndroidTagIo(tag), operation.token,
                        { isActive(operation) }, { emit(operation, it) })
                    finish(operation, if (operation.token == null) "read_success" else "write_success",
                        data = mapOf(
                            "deviceToken" to verified.deviceToken,
                            "uri" to verified.uri,
                            "tagId" to verified.tagId,
                            "tagType" to "NTAG213",
                            "verified" to (operation.token != null),
                            "bytesWritten" to verified.bytesWritten,
                        ))
                } catch (failure: DeviceTagFailure) {
                    finish(operation, "failed", failure.code, failure.message)
                } catch (_: TagLostException) {
                    finish(operation, "failed", "TAG_LOST", "标签已移开，请贴紧后重试；写入中断时请重新校验")
                } catch (_: IOException) {
                    finish(operation, "failed", "NFC_IO_ERROR", "未能完成 NFC 通信，请贴紧标签重试")
                } catch (_: RuntimeException) {
                    finish(operation, "failed", "NFC_ERROR", "设备标签操作失败，请重试")
                } catch (_: Exception) {
                    finish(operation, "failed", "INVALID_DEVICE_TAG", "设备标签格式无效，请重新制作")
                } finally {
                    closeConnectedTechnology()
                    processing.set(false)
                }
            }
        } catch (_: RejectedExecutionException) {
            processing.set(false)
            finish(operation, "cancelled", "OPERATION_CANCELLED", "设备标签工具已关闭")
        }
    }

    private fun isActive(operation: Operation): Boolean =
        synchronized(lock) { pending === operation && !operation.cancelled && !destroyed }

    private fun emit(operation: Operation, state: String) {
        main.post {
            if (isActive(operation)) channel.invokeMethod("deviceTagEvent",
                mapOf("operationId" to operation.id, "state" to state))
        }
    }

    private fun finish(
        operation: Operation,
        state: String,
        code: String? = null,
        message: String? = null,
        data: Map<String, Any?> = emptyMap(),
    ) {
        val event = synchronized(lock) {
            if (pending !== operation || operation.cancelled) return
            operation.cancelled = true
            pending = null
            operation.timeout?.let(main::removeCallbacks)
            (mapOf("operationId" to operation.id, "state" to state,
                "code" to code, "message" to message) + data).also { terminal = it }
        }
        main.post {
            // Do not disable a newer operation's reader mode after an IO event
            // has crossed the main-thread queue.
            if (synchronized(lock) { pending == null }) disableReader()
            if (!destroyed) channel.invokeMethod("deviceTagEvent", event)
        }
    }

    private fun disableReader() {
        if (!readerEnabled) return
        try { adapter?.disableReaderMode(activity) } catch (_: RuntimeException) { }
        readerEnabled = false
    }

    private fun closeConnectedTechnology() {
        val current = connectedTechnology
        connectedTechnology = null
        try { current?.close() } catch (_: Exception) { }
    }

    private inner class AndroidTagIo(private val tag: Tag) : DeviceTagIo {
        override fun probe(writing: Boolean): DeviceTagProbe {
            val technology = NfcA.get(tag)
                ?: throw DeviceTagFailure("UNSUPPORTED_TAG", "请使用 NTAG213 设备标签")
            return withTechnology(technology) {
                technology.timeout = 1_500
                val version = technology.transceive(byteArrayOf(0x60))
                val id = tag.id.joinToString("") { "%02X".format(it.toInt() and 0xFF) }
                val identity = DeviceTagProbe(id, version)
                DeviceTagProtocol.validateTag(identity)
                if (!writing) identity else identity.copy(
                    header = technology.transceive(byteArrayOf(0x30, 0x00)),
                    configuration = technology.transceive(byteArrayOf(0x30, 0x28)),
                )
            }
        }

        override fun writableCapacity(): Int = withNdef { ndef ->
            if (!ndef.isWritable) throw DeviceTagFailure("TAG_LOCKED", "设备标签不可写，请换用空白 NTAG213")
            ndef.maxSize
        }

        override fun readMessage(): ByteArray = withNdef { ndef ->
            ndef.ndefMessage?.toByteArray()
                ?: throw DeviceTagFailure("INVALID_DEVICE_TAG", "此标签尚未制作设备入口")
        }

        override fun writeMessage(message: ByteArray) = withNdef { ndef ->
            if (!ndef.isWritable) throw DeviceTagFailure("TAG_LOCKED", "设备标签不可写，请换用空白 NTAG213")
            if (message.size > ndef.maxSize) throw DeviceTagFailure("TAG_CAPACITY", "标签容量不足")
            ndef.writeNdefMessage(NdefMessage(message))
        }

        private fun <T> withNdef(action: (Ndef) -> T): T {
            val ndef = Ndef.get(tag)
                ?: throw DeviceTagFailure("UNSUPPORTED_FORMAT", "请使用标准 NDEF 格式的 NTAG213 标签")
            return withTechnology(ndef) { action(ndef) }
        }

        private fun <T> withTechnology(technology: TagTechnology, action: () -> T): T {
            connectedTechnology = technology
            try {
                technology.connect()
                return action()
            } finally {
                if (connectedTechnology === technology) connectedTechnology = null
                try { technology.close() } catch (_: Exception) { }
            }
        }
    }
}

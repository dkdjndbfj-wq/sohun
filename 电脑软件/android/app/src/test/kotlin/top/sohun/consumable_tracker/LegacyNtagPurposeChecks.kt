package top.sohun.consumable_tracker

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Test

/**
 * JVM checks of the purpose gate used before MainActivity's NFC dispatch.
 * The gate must explicitly reject legacy inventory reads/writes while leaving
 * status, Classic scans and complete template operations to their own handlers.
 */
class LegacyNtagPurposeChecks {
    @Test
    fun legacyConsumablePurposeIsRejectedBeforeNfc() {
        var passed = 0
        fun rejected(method: String, profile: String?, code: String) {
            val result = CapturedResult()
            check(rejectLegacyConsumableNfcCall(MethodCall(method, mapOf("profile" to profile)), result))
            check(result.code == code) { "$method/$profile: ${result.code}" }
            check(result.calls == 1 && !result.succeeded)
            passed++
            println("PASS $method/$profile rejects before NFC: $code")
        }

        rejected("beginWrite", "ntag213", "unsupported_tag_purpose")
        rejected("beginWrite", " NTAG213 ", "unsupported_tag_purpose")
        rejected("beginRead", null, "unsupported_tag_purpose")
        rejected("beginRead", "cuid", "unsupported_tag_purpose")
        rejected("beginWrite", "ams", "AMS_TEMPLATE_REQUIRED")
        rejected("beginWrite", null, "AMS_TEMPLATE_REQUIRED")
        rejected("beginWrite", "other", "INVALID_PAYLOAD")
        for (method in listOf("getStatus", "beginScan", "beginReadAmsTemplate",
                "beginRestoreAmsTemplate", "cancel", "getOperationState")) {
            val result = CapturedResult()
            check(!rejectLegacyConsumableNfcCall(MethodCall(method, null), result))
            check(result.calls == 0)
            passed++
            println("PASS $method preserves the existing native handler")
        }
        println("$passed native purpose checks passed")
    }

    private class CapturedResult : MethodChannel.Result {
        var code: String? = null
        var succeeded = false
        var calls = 0
        override fun success(result: Any?) { calls++; succeeded = true }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            calls++
            code = errorCode
        }
        override fun notImplemented() { error("Legacy contract must fail explicitly") }
    }
}

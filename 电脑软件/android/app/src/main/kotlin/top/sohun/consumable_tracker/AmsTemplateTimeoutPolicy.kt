package top.sohun.consumable_tracker

/** Native watchdog limits for complete AMS template operations. */
internal object AmsTemplateTimeoutPolicy {
    const val TIMEOUT_CODE = "OPERATION_TIMEOUT"
    const val READ_TIMEOUT_MS = 120_000L
    const val RESTORE_TIMEOUT_MS = 180_000L

    fun watchdogMillis(restore: Boolean): Long =
        if (restore) RESTORE_TIMEOUT_MS else READ_TIMEOUT_MS

    fun timeoutMessage(blocksWritten: Int): String =
        if (blocksWritten > 0) {
            "NFC 操作超时，标签可能已部分写入；请保留模板重新校验"
        } else {
            "NFC 操作已超时，请重新开始"
        }
}

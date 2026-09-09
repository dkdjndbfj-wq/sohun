package top.sohun.consumable_tracker

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM contract checks for the native AMS operation watchdog. */
class AmsTemplateTimeoutPolicyChecks {
    @Test
    fun readAndRestoreUseTheirOwnDeadlines() {
        assertEquals(120_000L, AmsTemplateTimeoutPolicy.watchdogMillis(restore = false))
        assertEquals(180_000L, AmsTemplateTimeoutPolicy.watchdogMillis(restore = true))
        assertTrue(
            AmsTemplateTimeoutPolicy.RESTORE_TIMEOUT_MS >
                AmsTemplateTimeoutPolicy.READ_TIMEOUT_MS,
        )
    }

    @Test
    fun partialWriteTimeoutRequiresVerificationAndNeverClaimsSuccess() {
        assertEquals("OPERATION_TIMEOUT", AmsTemplateTimeoutPolicy.TIMEOUT_CODE)
        val beforeWrite = AmsTemplateTimeoutPolicy.timeoutMessage(blocksWritten = 0)
        assertTrue(beforeWrite.contains("重新开始"))

        val afterWrite = AmsTemplateTimeoutPolicy.timeoutMessage(blocksWritten = 1)
        assertTrue(afterWrite.contains("部分写入"))
        assertTrue(afterWrite.contains("重新校验"))
        assertTrue(!afterWrite.contains("成功"))
    }
}

package top.sohun.consumable_tracker

import android.Manifest
import android.app.*
import android.app.job.*
import android.content.*
import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.security.KeyStore
import java.util.concurrent.Executors
import java.util.concurrent.Future
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Local Android notifications plus OS-scheduled catch-up, without holding a
 * background foreground-service or sharing the account refresh credential. */
class PrinterFaultBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "top.sohun/printer_faults")
    private var permissionResult: MethodChannel.Result? = null
    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "permission" -> result.success(PrinterFaultNotifications.allowed(activity))
                    "requestPermission" -> {
                        if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            if (permissionResult != null) result.error("BUSY", "通知授权正在进行", null)
                            else { permissionResult = result; activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7126) }
                        } else result.success(PrinterFaultNotifications.allowed(activity))
                    }
                    "status" -> {
                        val config = PrinterFaultNotifications.config(activity)
                        result.success(mapOf("accountKey" to config?.optString("accountKey"),
                            "enabled" to (config != null), "allowed" to PrinterFaultNotifications.allowed(activity),
                            "expiresAt" to config?.optString("expiresAt")))
                    }
                    "configure" -> {
                        val data = JSONObject(call.arguments as Map<*, *>)
                        PrinterFaultNotifications.configure(activity, data); result.success(true)
                    }
                    "clear" -> { PrinterFaultNotifications.clear(activity); result.success(true) }
                    "deliver" -> {
                        val args = JSONObject(call.arguments as Map<*, *>)
                        PrinterFaultNotifications.deliver(activity, args.getString("accountKey"), args.getJSONArray("events"))
                        result.success(true)
                    }
                    "takeOpenRequest" -> {
                        val open = activity.intent?.getBooleanExtra("openPrinterFaults", false) == true
                        activity.intent?.removeExtra("openPrinterFaults"); result.success(open)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("FAULT_NOTIFICATIONS", "打印提醒设置失败，请重试", null) }
        }
    }
    fun onPermissionsResult(code: Int) {
        if (code != 7126) return
        permissionResult?.success(PrinterFaultNotifications.allowed(activity)); permissionResult = null
    }
    fun onNewIntent(intent: Intent) {
        if (intent.getBooleanExtra("openPrinterFaults", false)) channel.invokeMethod("openFaults", null)
    }
}

object PrinterFaultNotifications {
    private const val JOB = 7126
    private const val PREFS = "sohun_printer_fault_monitor"
    private const val KEY = "sohun_fault_monitor_aes_v1"
    private const val CHANNEL = "printer_faults_v1"
    private val lock = Any()
    private val network = Executors.newSingleThreadExecutor()
    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(KEY, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun config(context: Context): JSONObject? = synchronized(lock) {
        try {
            val stored = prefs(context).getString("encrypted", null) ?: return@synchronized null
            val envelope = JSONObject(stored)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(envelope.getString("iv"), Base64.NO_WRAP)))
            JSONObject(String(cipher.doFinal(Base64.decode(envelope.getString("data"), Base64.NO_WRAP)), Charsets.UTF_8))
        } catch (_: Exception) { null }
    }
    private fun save(context: Context, data: JSONObject) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val encrypted = cipher.doFinal(data.toString().toByteArray(Charsets.UTF_8))
        check(prefs(context).edit().putString("encrypted", JSONObject()
            .put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("data", Base64.encodeToString(encrypted, Base64.NO_WRAP)).toString()).commit())
    }
    fun configure(context: Context, data: JSONObject) = synchronized(lock) {
        val base = URI(data.getString("baseUrl"))
        require(base.scheme == "https" && base.host != null && base.userInfo == null)
        require(data.getString("token").matches(Regex("[A-Za-z0-9_-]{40,100}")))
        val previous = config(context)
        if (previous?.optString("accountKey") == data.getString("accountKey")) {
            data.put("cursor", previous.optLong("cursor", 0))
        } else {
            clear(context); data.put("cursor", 0)
        }
        save(context, data)
        val job = JobInfo.Builder(JOB, ComponentName(context, PrinterFaultPollJob::class.java))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPeriodic(15 * 60 * 1000L)
            .setPersisted(true).build()
        check(context.getSystemService(JobScheduler::class.java).schedule(job) == JobScheduler.RESULT_SUCCESS)
    }
    fun clear(context: Context) = synchronized(lock) {
        val previous = config(context)
        prefs(context).edit().clear().commit()
        context.getSystemService(JobScheduler::class.java).cancel(JOB)
        context.getSystemService(NotificationManager::class.java).cancelAll()
        if (previous != null) network.execute { try { request(previous, "DELETE", "") } catch (_: Exception) { } }
    }
    fun allowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return false
        return Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
    }
    fun deliver(context: Context, owner: String, events: JSONArray) = synchronized(lock) {
        if (config(context)?.optString("accountKey") != owner) return@synchronized
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(
            CHANNEL, "打印机故障", NotificationManager.IMPORTANCE_HIGH).apply { description = "拓竹设备故障与打印任务异常" })
        val seen = JSONObject(prefs(context).getString("seen", "{}") ?: "{}")
        for (index in 0 until events.length()) {
            val event = events.getJSONObject(index)
            val id = event.getString("eventId")
            val severity = event.getString("severity")
            if (!event.isNull("clearedAt") || !event.isNull("readAt") || severity == "info") {
                manager.cancel(id, 0); seen.put(id, severity); continue
            }
            if (seen.optString(id) == severity || !allowed(context)) continue
            val intent = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra("openPrinterFaults", true)
            val pending = PendingIntent.getActivity(context, id.hashCode(), intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else Notification.Builder(context)
            val message = event.getString("message")
            manager.notify(id, 0, builder.setSmallIcon(R.drawable.ic_stat_printer)
                .setContentTitle(event.getString("printerName") + " · 打印机提醒")
                .setContentText(message).setStyle(Notification.BigTextStyle().bigText(message + "\n" + event.getString("code")))
                .setVisibility(Notification.VISIBILITY_PRIVATE).setCategory(Notification.CATEGORY_ERROR)
                .setContentIntent(pending).setAutoCancel(true).build())
            seen.put(id, severity)
        }
        // Retain enough dedup keys for a long print; remove old history first.
        while (seen.length() > 4000) seen.remove(seen.keys().next())
        prefs(context).edit().putString("seen", seen.toString()).commit()
    }
    private fun request(config: JSONObject, method: String, query: String): JSONObject {
        val endpoint = config.getString("baseUrl").trimEnd('/') + "/v1/notifications/printer-faults" + query
        val connection = URI(endpoint).toURL().openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.requestMethod = method
            connection.connectTimeout = 10_000; connection.readTimeout = 10_000
            connection.setRequestProperty("Authorization", "Bearer " + config.getString("token"))
            if (connection.responseCode != 200) throw IllegalStateException("Fault service unavailable")
            val bytes = connection.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(output.size() + count <= 2 * 1024 * 1024)
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            require(bytes.size <= 2 * 1024 * 1024)
            return JSONObject(String(bytes, Charsets.UTF_8))
        } finally { connection.disconnect() }
    }
    fun poll(context: Context, stopped: () -> Boolean) {
        val captured = config(context) ?: return
        var cursor = captured.optLong("cursor", 0)
        val latest = linkedMapOf<String, JSONObject>()
        var pages = 0
        do {
            if (stopped()) return
            val page = request(captured, "GET", "?after=$cursor")
            val events = page.getJSONArray("events")
            for (i in 0 until events.length()) { val e = events.getJSONObject(i); latest[e.getString("eventId")] = e }
            val next = page.getLong("cursor")
            require(!page.optBoolean("hasMore") || next > cursor)
            cursor = next
            pages++
            if (pages > 100) throw IllegalStateException("Too many pending fault pages")
        } while (page.optBoolean("hasMore"))
        synchronized(lock) {
            if (stopped() || config(context)?.optString("token") != captured.getString("token")) return
            deliver(context, captured.getString("accountKey"), JSONArray(latest.values.toList()))
            captured.put("cursor", cursor); save(context, captured)
        }
    }
}

class PrinterFaultPollJob : JobService() {
    private val executor = Executors.newSingleThreadExecutor()
    private var future: Future<*>? = null
    private val generation = java.util.concurrent.atomic.AtomicInteger()
    override fun onStartJob(params: JobParameters): Boolean {
        val run = generation.incrementAndGet()
        future = executor.submit {
            var retry = false
            try { PrinterFaultNotifications.poll(this) { generation.get() != run } } catch (_: Exception) { retry = true }
            if (generation.get() == run) jobFinished(params, retry)
        }
        return true
    }
    override fun onStopJob(params: JobParameters): Boolean { generation.incrementAndGet(); future?.cancel(true); return true }
    override fun onDestroy() { generation.incrementAndGet(); executor.shutdownNow(); super.onDestroy() }
}

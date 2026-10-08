package com.sshtab.ssh_pad_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Same-process FGS for session keepalive.
 *
 * Holds PARTIAL_WAKE_LOCK + WifiLock while sessions are active.
 * Starts with mediaPlayback|dataSync and a weak AudioTrack by default so CN
 * OEMs do not freeze the Flutter/Dart SSH isolate when the user leaves the app.
 * Does NOT aggressively auto-reconnect.
 */
class SessionForegroundService : Service() {
    companion object {
        private const val TAG = "SshPadFGS"
        const val CHANNEL_ID = "ssh_pad_sessions"
        const val NOTIFICATION_ID = 1001
        const val ACTION_STOP = "com.sshtab.ssh_pad_flutter.STOP_SESSIONS"
        const val ACTION_OPEN = "com.sshtab.ssh_pad_flutter.OPEN_APP"
        const val ACTION_ENSURE = "com.sshtab.ssh_pad_flutter.ENSURE"
        const val EXTRA_SESSIONS = "sessions"
        const val EXTRA_TITLE = "title"
        const val EXTRA_WEAK_AUDIO = "weakAudio"

        @Volatile
        var stopCallback: (() -> Unit)? = null

        @Volatile
        private var lastSessions: ArrayList<String> = arrayListOf()

        @Volatile
        private var lastTitleCached: String = ""

        @Volatile
        private var lastWeakAudio: Boolean = true

        fun start(
            context: Context,
            sessions: List<String>,
            title: String?,
            weakAudio: Boolean,
        ) {
            lastSessions = ArrayList(sessions)
            lastTitleCached = title.orEmpty()
            lastWeakAudio = weakAudio
            val intent = Intent(context, SessionForegroundService::class.java).apply {
                putStringArrayListExtra(EXTRA_SESSIONS, ArrayList(sessions))
                putExtra(EXTRA_TITLE, title ?: "")
                putExtra(EXTRA_WEAK_AUDIO, weakAudio)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                Log.i(TAG, "startForegroundService requested n=${sessions.size} weakAudio=$weakAudio")
            } catch (t: Throwable) {
                Log.e(TAG, "startForegroundService failed: ${t.message}", t)
                try {
                    context.startService(intent)
                } catch (t2: Throwable) {
                    Log.e(TAG, "startService fallback failed: ${t2.message}", t2)
                }
            }
        }

        fun ensure(context: Context) {
            if (lastSessions.isEmpty()) return
            val intent = Intent(context, SessionForegroundService::class.java).apply {
                action = ACTION_ENSURE
                putStringArrayListExtra(EXTRA_SESSIONS, ArrayList(lastSessions))
                putExtra(EXTRA_TITLE, lastTitleCached)
                putExtra(EXTRA_WEAK_AUDIO, lastWeakAudio)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                Log.i(TAG, "ensure FGS n=${lastSessions.size}")
            } catch (t: Throwable) {
                Log.e(TAG, "ensure failed: ${t.message}", t)
            }
        }

        fun stop(context: Context) {
            lastSessions = arrayListOf()
            lastTitleCached = ""
            context.stopService(Intent(context, SessionForegroundService::class.java))
            Log.i(TAG, "stopService requested")
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var player: KeepAlivePlayer? = null
    private var floatBubble: KeepAliveFloat? = null
    private var lastCount = 0
    private var lastTitle = ""
    private var weakAudioEnabled = true

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "onCreate pid=${android.os.Process.myPid()}")
        floatBubble = KeepAliveFloat(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Defense in depth: never run keepalive inside 卓易通 (e.g. sticky restart).
        if (ZhuoyitongGuard.check(this).detected) {
            Log.w(TAG, "Zhuoyitong — refusing to start FGS")
            stopSelf(startId)
            return START_NOT_STICKY
        }
        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(TAG, "ACTION_STOP")
                stopCallback?.invoke()
                teardown()
                return START_NOT_STICKY
            }
            ACTION_OPEN -> {
                val launch = packageManager.getLaunchIntentForPackage(packageName)
                launch?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                if (launch != null) startActivity(launch)
                return START_STICKY
            }
        }

        val sessions = intent?.getStringArrayListExtra(EXTRA_SESSIONS)
            ?: ArrayList(lastSessions)
        val title = intent?.getStringExtra(EXTRA_TITLE).orEmpty().ifBlank { lastTitleCached }
        val weakAudio = intent?.getBooleanExtra(EXTRA_WEAK_AUDIO, lastWeakAudio) ?: lastWeakAudio
        lastCount = sessions.size
        lastTitle = title
        weakAudioEnabled = weakAudio
        lastSessions = ArrayList(sessions)
        lastTitleCached = title
        lastWeakAudio = weakAudio

        ensureChannel()
        val notification = buildNotification(sessions.size, title)
        startInForegroundSafely(notification)

        if (sessions.isEmpty()) {
            Log.i(TAG, "no sessions — teardown")
            teardown()
            return START_NOT_STICKY
        }

        acquireLocks()
        holdNetwork()
        // Weak audio ON by default: mediaPlayback FGS without real playback is
        // often frozen by CN OEMs within seconds of leaving the app.
        if (weakAudio) {
            if (player == null) player = KeepAlivePlayer()
            player?.start()
            Log.i(TAG, "weak audio started")
        } else {
            player?.stop()
            player = null
            Log.i(TAG, "weak audio disabled by setting")
        }
        floatBubble?.show()
        Log.i(TAG, "FGS active n=${sessions.size} title=$title weakAudio=$weakAudio")
        return START_STICKY
    }

    override fun onTimeout(startId: Int) {
        Log.w(TAG, "onTimeout startId=$startId — re-promote FGS, NOT stopping")
        startInForegroundSafely(buildNotification(lastCount, lastTitle))
        acquireLocks()
        if (weakAudioEnabled) {
            if (player == null) player = KeepAlivePlayer()
            player?.start()
        }
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "onTimeout startId=$startId type=$fgsType — re-promote FGS")
        onTimeout(startId)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "onTaskRemoved — keeping FGS sticky")
        startInForegroundSafely(buildNotification(lastCount, lastTitle))
        acquireLocks()
        if (lastCount > 0 && weakAudioEnabled) {
            if (player == null) player = KeepAlivePlayer()
            player?.start()
        }
        // Re-deliver sticky start so system restarts us if killed.
        if (lastCount > 0) {
            ensure(applicationContext)
        }
    }

    private fun startInForegroundSafely(notification: Notification) {
        val errors = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 34) {
            val media = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            val dataSync = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            try {
                startForeground(NOTIFICATION_ID, notification, media or dataSync)
                Log.i(TAG, "startForeground mediaPlayback|dataSync ok")
                return
            } catch (t: Throwable) {
                errors += "combo:${t.javaClass.simpleName}:${t.message}"
            }
            try {
                startForeground(NOTIFICATION_ID, notification, media)
                Log.i(TAG, "startForeground mediaPlayback ok")
                return
            } catch (t: Throwable) {
                errors += "media:${t.javaClass.simpleName}"
            }
            try {
                startForeground(NOTIFICATION_ID, notification, dataSync)
                Log.i(TAG, "startForeground dataSync ok")
                return
            } catch (t: Throwable) {
                errors += "dataSync:${t.javaClass.simpleName}"
            }
            try {
                @Suppress("DEPRECATION")
                startForeground(NOTIFICATION_ID, notification)
                Log.i(TAG, "startForeground plain ok")
                return
            } catch (t: Throwable) {
                errors += "plain:${t.javaClass.simpleName}"
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK or
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
                Log.i(TAG, "startForeground Q+ media|dataSync ok")
                return
            } catch (t: Throwable) {
                errors += t.javaClass.simpleName
            }
            try {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
                return
            } catch (t: Throwable) {
                errors += t.javaClass.simpleName
            }
            try {
                @Suppress("DEPRECATION")
                startForeground(NOTIFICATION_ID, notification)
                return
            } catch (t: Throwable) {
                errors += t.javaClass.simpleName
            }
        } else {
            startForeground(NOTIFICATION_ID, notification)
            return
        }
        Log.e(TAG, "startForeground FAILED $errors")
    }

    private fun teardown() {
        Log.i(TAG, "teardown")
        player?.stop()
        player = null
        floatBubble?.hide()
        floatBubble = null
        releaseLocks()
        releaseNetwork()
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {
        }
        stopSelf()
    }

    override fun onDestroy() {
        Log.i(TAG, "onDestroy lastCount=$lastCount")
        val hadSessions = lastCount > 0
        player?.stop()
        player = null
        floatBubble?.hide()
        releaseLocks()
        releaseNetwork()
        super.onDestroy()
        if (hadSessions) {
            try {
                ensure(applicationContext)
                Log.i(TAG, "requested FGS restart after onDestroy")
            } catch (t: Throwable) {
                Log.e(TAG, "restart after onDestroy failed: ${t.message}")
            }
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val existing = nm.getNotificationChannel(CHANNEL_ID)
        if (existing == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "SSH Pad 会话保活",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "保持 SSH/Telnet 等会话在后台不被冻结"
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(count: Int, title: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val contentPi = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = Intent(this, SessionForegroundService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPi = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val openIntent = Intent(this, SessionForegroundService::class.java).apply {
            action = ACTION_OPEN
        }
        val openPi = PendingIntent.getService(
            this,
            2,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val text = when {
            count <= 0 -> "无活动会话"
            title.isNotBlank() -> title
            else -> "活动会话：$count"
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(if (count > 1) "SSH Pad 会话 ×$count" else "SSH Pad 会话保活")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(contentPi)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(0, "打开应用", openPi)
            .addAction(0, "断开全部", stopPi)
            .build()
    }

    private fun acquireLocks() {
        try {
            if (wakeLock?.isHeld != true) {
                val pm = getSystemService(POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "sshpad:session").apply {
                    setReferenceCounted(false)
                    acquire()
                }
                Log.i(TAG, "PARTIAL_WAKE_LOCK acquired")
            }
        } catch (t: Throwable) {
            Log.w(TAG, "wakelock failed: ${t.message}")
        }
        try {
            if (wifiLock?.isHeld != true) {
                @Suppress("DEPRECATION")
                val wm = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
                @Suppress("DEPRECATION")
                wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "sshpad:wifi").apply {
                    setReferenceCounted(false)
                    acquire()
                }
                Log.i(TAG, "WifiLock acquired")
            }
        } catch (t: Throwable) {
            Log.w(TAG, "wifilock failed: ${t.message}")
        }
    }

    private fun releaseLocks() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wakeLock = null
        try {
            wifiLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wifiLock = null
    }

    private fun holdNetwork() {
        if (networkCallback != null) return
        try {
            val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            // Do not require INTERNET capability — LAN SSH Wi‑Fi may lack it.
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    Log.i(TAG, "holdNetwork wifi available $network")
                }

                override fun onLost(network: Network) {
                    Log.w(TAG, "holdNetwork wifi lost $network")
                }
            }
            cm.requestNetwork(request, cb)
            networkCallback = cb
            Log.i(TAG, "holdNetwork wifi request ok")
        } catch (t: Throwable) {
            Log.w(TAG, "holdNetwork failed: ${t.message}")
        }
    }

    private fun releaseNetwork() {
        val cb = networkCallback ?: return
        networkCallback = null
        try {
            val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.unregisterNetworkCallback(cb)
        } catch (_: Throwable) {
        }
    }
}

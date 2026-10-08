package com.sshtab.ssh_pad_flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import android.widget.Toast
import java.io.File

/**
 * 卓易通 (Zhuoyitong) detect-and-exit guard.
 *
 * 卓易通 is the Android-compat container that HarmonyOS NEXT / HarmonyOS 5+
 * uses to run APKs (iSulad/LXC container, "ANCO"). SSH Pad intentionally does
 * NOT support it: when detected, the app shows a short native message and
 * exits instead of crashing. No compatibility work is done for it.
 *
 * Normal Android (ColorOS/OnePlus, MIUI, stock, and Huawei/Honor EMUI /
 * HarmonyOS 2–4 which are real AOSP-based Android) must never be affected,
 * so the rules are:
 *
 * STRONG signals (any one ⇒ detected):
 *  1. Install source == `com.zhuoyi.appstore.lite`. This is the 卓易通 store /
 *     installer bundle; OpenHarmony's own netmanager & notification services
 *     hard-code it as the install source of 卓易通 apps
 *     (INSTALL_SOURCE_FROM_SIM / BUNDLE_NAME_ZYT). SSH Pad is only shipped as
 *     a GitHub APK, so this installer can only appear via 卓易通.
 *  2. `/proc/self/cgroup` contains `isulad` or `zhuoyi` — the container runs
 *     on Huawei's iSulad engine. Regular Android cgroups look like
 *     `/uid_10xxx/pid_yyy`, `/top-app`, `/system` and never contain these.
 *  3. Build.DISPLAY / FINGERPRINT / HOST / PRODUCT / DEVICE contains
 *     `zhuoyi`.
 *
 * WEAK signals require BOTH a container hint AND a Huawei/Harmony hint, so a
 * real Huawei phone (Harmony hint only) or Waydroid/Anbox on a PC (LXC hint
 * only) or a Droi/Freeme ROM phone with a zhuoyi app (package hint only)
 * never exits:
 *  - container hints: cgroup path `/lxc/` or token `anco`; 卓易通 host
 *    packages visible (`com.zhuoyi.appstore.lite`, `com.droi.tong`,
 *    `com.droi.iapps`); props `persist.sys.zyt_flag` set,
 *    `ro.vendor.build.ohos.family`=zyt, `ro.build.characteristics` token
 *    `droi`; Build.DISPLAY token `zyt`.
 *  - Huawei/Harmony hints: Build.MANUFACTURER/BRAND == HUAWEI;
 *    `hw_sc.build.platform.version` set; `/proc/version` mentions
 *    harmony/ohos.
 *
 * Note: Build.MANUFACTURER/BRAND/MODEL alone cannot identify 卓易通 (it
 * reports the real Huawei model), so they are only ever used as corroboration.
 *
 * Every probe is wrapped in try/catch; on any error or doubt the result is
 * "not detected" (normal Android, app keeps running).
 */
object ZhuoyitongGuard {
    private const val TAG = "SshPadMain"

    const val EXIT_MESSAGE = "当前运行在卓易通环境，SSH Pad 不支持，即将退出。"

    private const val ZYT_INSTALLER = "com.zhuoyi.appstore.lite"
    private val ZYT_PACKAGES = listOf(ZYT_INSTALLER, "com.droi.tong", "com.droi.iapps")

    data class Result(val detected: Boolean, val signal: String)

    @Volatile
    private var cached: Result? = null

    /** True only after [check] has positively detected 卓易通. */
    val isBlocked: Boolean
        get() = cached?.detected == true

    /** Cached detection; never throws. */
    fun check(context: Context): Result {
        cached?.let { return it }
        val result = try {
            detect(context.applicationContext ?: context)
        } catch (t: Throwable) {
            Result(false, "probe-error:${t.javaClass.simpleName}")
        }
        cached = result
        try {
            if (result.detected) {
                Log.w(TAG, "Zhuoyitong detected via ${result.signal} — exiting by design")
            } else {
                Log.i(TAG, "Zhuoyitong not detected (${result.signal})")
            }
        } catch (_: Throwable) {
        }
        return result
    }

    private fun detect(context: Context): Result {
        // ---- strong signals ----
        installerOf(context)?.let { if (it == ZYT_INSTALLER) return Result(true, "installer=$it") }

        val cgroup = readSmall("/proc/self/cgroup")?.lowercase().orEmpty()
        for (kw in listOf("isulad", "zhuoyi")) {
            if (cgroup.contains(kw)) return Result(true, "cgroup:$kw")
        }

        val buildFields = mapOf(
            "DISPLAY" to Build.DISPLAY,
            "FINGERPRINT" to Build.FINGERPRINT,
            "HOST" to Build.HOST,
            "PRODUCT" to Build.PRODUCT,
            "DEVICE" to Build.DEVICE,
        )
        for ((name, value) in buildFields) {
            if (value?.lowercase()?.contains("zhuoyi") == true) {
                return Result(true, "Build.$name~zhuoyi")
            }
        }

        // ---- weak signals: need container hint AND Huawei/Harmony hint ----
        val container = containerHint(context, cgroup) ?: return Result(false, "no-signal")
        val harmony = harmonyHint() ?: return Result(false, "container-hint-only:$container")
        return Result(true, "$container+$harmony")
    }

    private fun containerHint(context: Context, cgroup: String): String? {
        if (cgroup.contains("/lxc/")) return "cgroup:/lxc/"
        if (hasToken(cgroup, "anco")) return "cgroup:anco"
        for (pkg in ZYT_PACKAGES) {
            if (isInstalled(context, pkg)) return "pkg:$pkg"
        }
        if (prop("persist.sys.zyt_flag").isNotEmpty()) return "prop:persist.sys.zyt_flag"
        if (prop("ro.vendor.build.ohos.family").equals("zyt", ignoreCase = true)) {
            return "prop:ro.vendor.build.ohos.family=zyt"
        }
        if (hasToken(prop("ro.build.characteristics").lowercase(), "droi")) {
            return "prop:ro.build.characteristics~droi"
        }
        if (hasToken(Build.DISPLAY?.lowercase().orEmpty(), "zyt")) return "Build.DISPLAY~zyt"
        return null
    }

    private fun harmonyHint(): String? {
        val mfr = Build.MANUFACTURER.orEmpty()
        val brand = Build.BRAND.orEmpty()
        if (mfr.equals("HUAWEI", true) || brand.equals("HUAWEI", true)) return "brand=HUAWEI"
        if (prop("hw_sc.build.platform.version").isNotEmpty()) return "prop:hw_sc"
        val ver = readSmall("/proc/version")?.lowercase().orEmpty()
        if (ver.contains("harmony") || hasToken(ver, "ohos")) return "kernel:harmony"
        return null
    }

    /** Whole-word match (letters/digits not adjacent), so "droi" ≠ "android". */
    private fun hasToken(haystack: String, token: String): Boolean {
        if (haystack.isEmpty()) return false
        return Regex("(^|[^a-z0-9])${Regex.escape(token)}([^a-z0-9]|$)").containsMatchIn(haystack)
    }

    private fun installerOf(context: Context): String? = try {
        val pm = context.packageManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val info = pm.getInstallSourceInfo(context.packageName)
            info.installingPackageName ?: info.initiatingPackageName
        } else {
            @Suppress("DEPRECATION")
            pm.getInstallerPackageName(context.packageName)
        }
    } catch (_: Throwable) {
        null
    }

    private fun isInstalled(context: Context, pkg: String): Boolean = try {
        context.packageManager.getPackageInfo(pkg, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    } catch (_: Throwable) {
        false
    }

    private fun prop(key: String): String = try {
        val cls = Class.forName("android.os.SystemProperties")
        (cls.getMethod("get", String::class.java).invoke(null, key) as? String)?.trim().orEmpty()
    } catch (_: Throwable) {
        ""
    }

    private fun readSmall(path: String): String? = try {
        val f = File(path)
        f.inputStream().use { input ->
            val buf = ByteArray(16 * 1024)
            val n = input.read(buf)
            if (n <= 0) null else String(buf, 0, n, Charsets.UTF_8)
        }
    } catch (_: Throwable) {
        null
    }

    /**
     * Called from MainActivity.onCreate (before super.onCreate) when blocked:
     * open the native exit dialog and finish MainActivity so it never reaches
     * onStart (no Dart entrypoint, no plugins, no FGS). Never throws.
     */
    fun leave(activity: Activity) {
        try {
            activity.startActivity(Intent(activity, ZytExitActivity::class.java))
            activity.finish()
            return
        } catch (t: Throwable) {
            try {
                Log.w(TAG, "ZytExitActivity launch failed: $t — toast fallback")
            } catch (_: Throwable) {
            }
        }
        try {
            Toast.makeText(activity.applicationContext, EXIT_MESSAGE, Toast.LENGTH_LONG).show()
        } catch (_: Throwable) {
        }
        try {
            activity.finishAndRemoveTask()
        } catch (_: Throwable) {
            try {
                activity.finish()
            } catch (_: Throwable) {
            }
        }
        killProcessLater(2500)
    }

    fun killProcessLater(delayMs: Long) {
        try {
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                try {
                    android.os.Process.killProcess(android.os.Process.myPid())
                } catch (_: Throwable) {
                }
                kotlin.system.exitProcess(0)
            }, delayMs)
        } catch (_: Throwable) {
        }
    }
}

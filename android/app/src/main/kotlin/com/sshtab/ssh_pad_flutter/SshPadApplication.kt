package com.sshtab.ssh_pad_flutter

import android.app.Application

/**
 * Earliest native hook: runs 卓易通 detection once per process, before any
 * Activity, Flutter engine, or foreground service exists. The result is
 * cached in [ZhuoyitongGuard] and acted on by MainActivity / the FGS.
 * (Replaces the Flutter default `android.app.Application`; no other change.)
 */
class SshPadApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        ZhuoyitongGuard.check(this)
    }
}

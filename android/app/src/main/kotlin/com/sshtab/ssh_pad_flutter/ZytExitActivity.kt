package com.sshtab.ssh_pad_flutter

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast

/**
 * Plain native (non-Flutter) screen shown only inside 卓易通: tells the user
 * the environment is unsupported, then finishAndRemoveTask() + stops the
 * process. Normal Android never launches this activity.
 */
class ZytExitActivity : Activity() {
    private var exiting = false
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Light_Dialog_Alert)
                .setTitle("SSH Pad")
                .setMessage(ZhuoyitongGuard.EXIT_MESSAGE)
                .setCancelable(false)
                .setPositiveButton("退出") { _, _ -> exitNow() }
                .setOnDismissListener { exitNow() }
                .show()
        } catch (_: Throwable) {
            try {
                Toast.makeText(applicationContext, ZhuoyitongGuard.EXIT_MESSAGE, Toast.LENGTH_LONG).show()
            } catch (_: Throwable) {
            }
        }
        // Auto-exit even if the user does nothing.
        handler.postDelayed({ exitNow() }, AUTO_EXIT_MS)
    }

    @Deprecated("Back exits too")
    override fun onBackPressed() {
        exitNow()
    }

    private fun exitNow() {
        if (exiting) return
        exiting = true
        try {
            finishAndRemoveTask()
        } catch (_: Throwable) {
            try {
                finish()
            } catch (_: Throwable) {
            }
        }
        ZhuoyitongGuard.killProcessLater(300)
    }

    companion object {
        private const val AUTO_EXIT_MS = 4000L
    }
}

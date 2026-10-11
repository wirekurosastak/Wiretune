// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

package com.wiretune.platform

import android.annotation.SuppressLint
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Answers `wiretune/platform` (is this a television? where do downloads go?) and `wiretune/power` (playback started or
 * stopped).
 *
 * While music plays, the app holds a CPU lock and a Wi-Fi lock, so a stream from the server keeps flowing with the screen
 * off: without the Wi-Fi lock many phones put the radio to sleep and the stream stalls after a few minutes.
 */
class WiretunePlatformPlugin : FlutterPlugin {
    private var platformChannel: MethodChannel? = null
    private var powerChannel: MethodChannel? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        platformChannel = MethodChannel(binding.binaryMessenger, "wiretune/platform").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTelevision" -> result.success(isTelevision(context))
                    "musicDirectory" -> result.success(musicDirectory(context))
                    else -> result.notImplemented()
                }
            }
        }
        powerChannel = MethodChannel(binding.binaryMessenger, "wiretune/power").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "setPlaying" -> {
                        setPlaying(context, call.arguments as? Boolean ?: false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        platformChannel?.setMethodCallHandler(null)
        powerChannel?.setMethodCallHandler(null)
        platformChannel = null
        powerChannel = null
        release()
    }

    private fun isTelevision(context: Context): Boolean {
        val uiMode = context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        if (uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) return true
        return context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    /**
     * The music folder downloads go into. From Android 11 on, the shared Music folder: an app may add audio files of its
     * own there without any permission, and they show up in other music apps too. Before that, writing there takes a
     * storage permission, so the app's own music folder on the shared storage instead, which needs none. Null without
     * shared storage.
     */
    private fun musicDirectory(context: Context): String? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            @Suppress("DEPRECATION") // still the path of the shared folder; scoped storage governs what may go there
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC).absolutePath
        } else {
            context.getExternalFilesDir(Environment.DIRECTORY_MUSIC)?.absolutePath
        }

    // The locks are released when playback stops, so they need no timeout.
    @SuppressLint("WakelockTimeout")
    private fun setPlaying(context: Context, playing: Boolean) {
        if (!playing) {
            release()
            return
        }
        val wake = wakeLock ?: (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Wiretune:playback")
            .apply { setReferenceCounted(false) }
        wakeLock = wake
        if (!wake.isHeld) wake.acquire()

        @Suppress("DEPRECATION") // still the lock that keeps the radio awake for a stream (it is what ExoPlayer uses)
        val wifi = wifiLock ?: (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager)
            ?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "Wiretune:stream")
            ?.apply { setReferenceCounted(false) }
        wifiLock = wifi
        if (wifi != null && !wifi.isHeld) wifi.acquire()
    }

    private fun release() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wifiLock?.takeIf { it.isHeld }?.release()
    }
}

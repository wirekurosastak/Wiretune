// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

package com.wiretune.platform

import android.annotation.SuppressLint
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.wifi.WifiManager
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Answers `wiretune/platform` (is this a television?) and `wiretune/power` (playback started or stopped).
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

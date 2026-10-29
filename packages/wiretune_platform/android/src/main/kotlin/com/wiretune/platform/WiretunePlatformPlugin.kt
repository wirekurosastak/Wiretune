// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

package com.wiretune.platform

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.PendingIntent
import android.app.UiModeManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import java.io.File
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Answers `wiretune/platform` (is this a television? where do downloads go? may the app read the music on the
 * device? which app installed this one? install this update) and `wiretune/power` (playback started or stopped).
 *
 * The permission to read audio files is asked for only when the user scans a folder of the phone's own, never at start:
 * a player that streams from its server needs none.
 *
 * While music plays, the app holds a CPU lock and a Wi-Fi lock, so a stream from the server keeps flowing with the screen
 * off: without the Wi-Fi lock many phones put the radio to sleep and the stream stalls after a few minutes.
 */
class WiretunePlatformPlugin : FlutterPlugin, ActivityAware, PluginRegistry.RequestPermissionsResultListener {
    private var platformChannel: MethodChannel? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingAccess: MethodChannel.Result? = null
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
                    "requestAudioAccess" -> requestAudioAccess(context, result)
                    "installUpdate" -> installUpdate(context, call.arguments as? String, result)
                    else -> result.notImplemented()
                }
            }
        }
        powerChannel = MethodChannel(binding.binaryMessenger, "wiretune/power").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "setPlaying" -> {
                        val arguments = call.arguments as? Map<*, *>
                        setPlaying(context, arguments?.get("playing") == true, arguments?.get("streaming") == true)
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

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        pendingAccess?.success(false)
        pendingAccess = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    /** Reading other apps' audio files: READ_MEDIA_AUDIO from Android 13 on, the whole shared storage before. */
    private val audioPermission =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) Manifest.permission.READ_MEDIA_AUDIO
        else Manifest.permission.READ_EXTERNAL_STORAGE

    /** True when the app may read the audio files on the device, asking the user first if need be. */
    private fun requestAudioAccess(context: Context, result: MethodChannel.Result) {
        if (context.checkSelfPermission(audioPermission) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        val activity: Activity? = activityBinding?.activity
        if (activity == null || pendingAccess != null) {
            result.success(false)
            return
        }
        pendingAccess = result
        activity.requestPermissions(arrayOf(audioPermission), AUDIO_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != AUDIO_REQUEST) return false
        pendingAccess?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        pendingAccess = null
        return true
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

    /**
     * Hands the APK at [path] to the system's installer, which asks the user first (and, the first time, to allow
     * Wiretune to install apps). Android only installs it over this app when it is signed with the same key. Answers
     * once the installer has it; installing ends this process.
     */
    private fun installUpdate(context: Context, path: String?, result: MethodChannel.Result) {
        val apk = path?.let(::File)
        if (apk == null || !apk.isFile) {
            result.error("missing", "No update at $path", null)
            return
        }
        try {
            val installer = context.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            val sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                apk.inputStream().use { input ->
                    session.openWrite("update.apk", 0, apk.length()).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }
                listenForInstallStatus(context)
                val status = Intent(INSTALL_STATUS).setPackage(context.packageName)
                // The installer adds its status to the intent, so it has to stay mutable.
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
                session.commit(PendingIntent.getBroadcast(context, sessionId, status, flags).intentSender)
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("failed", e.message, null)
        }
    }

    /** Shows the installer's confirmation when it asks for one; any other status (done, cancelled, failed) ends it. */
    private fun listenForInstallStatus(context: Context) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context, intent: Intent) {
                val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
                if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                    @Suppress("DEPRECATION") // the typed getParcelableExtra is Android 13 and later only
                    val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
                    receiverContext.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } else {
                    receiverContext.applicationContext.unregisterReceiver(this)
                }
            }
        }
        val filter = IntentFilter(INSTALL_STATUS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
    }

    /**
     * The CPU stays awake while music plays, the Wi-Fi radio only while it is [streaming] over the network: a local file
     * or a download leaves the radio free to sleep. The locks are released when playback stops, so they need no timeout.
     */
    @SuppressLint("WakelockTimeout")
    private fun setPlaying(context: Context, playing: Boolean, streaming: Boolean) {
        if (playing) {
            val wake = wakeLock ?: (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Wiretune:playback")
                .apply { setReferenceCounted(false) }
            wakeLock = wake
            if (!wake.isHeld) wake.acquire()
        } else {
            wakeLock?.takeIf { it.isHeld }?.release()
        }

        if (streaming) {
            @Suppress("DEPRECATION") // still the lock that keeps the radio awake for a stream (it is what ExoPlayer uses)
            val wifi = wifiLock ?: (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager)
                ?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "Wiretune:stream")
                ?.apply { setReferenceCounted(false) }
            wifiLock = wifi
            if (wifi != null && !wifi.isHeld) wifi.acquire()
        } else {
            wifiLock?.takeIf { it.isHeld }?.release()
        }
    }

    private fun release() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wifiLock?.takeIf { it.isHeld }?.release()
    }

    private companion object {
        const val AUDIO_REQUEST = 0x5754 // "WT"
        const val INSTALL_STATUS = "com.wiretune.platform.INSTALL_STATUS"
    }
}

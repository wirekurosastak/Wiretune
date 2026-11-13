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
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Answers `wiretune/platform` (is this a television? where do downloads go? may the app read the music on the
 * device? which app installed this one? install this update) and `wiretune/power` (playback started or stopped, what
 * the home-screen widget shows: [NowPlayingWidget]), and
 * streams `wiretune/pcm` (a track decoded for the spectrum: [PcmDecoder]).
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
    private var pcmChannel: EventChannel? = null
    private val pcm = PcmDecoder()
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
                    "shareLog" -> shareLog(context, call.arguments as? String, result)
                    "bluetoothOutputLatency" -> result.success(bluetoothOutputLatency(context))
                    else -> result.notImplemented()
                }
            }
        }
        pcmChannel = EventChannel(binding.binaryMessenger, "wiretune/pcm").apply { setStreamHandler(pcm) }
        powerChannel = MethodChannel(binding.binaryMessenger, "wiretune/power").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "setPlaying" -> {
                        val arguments = call.arguments as? Map<*, *>
                        setPlaying(context, arguments?.get("playing") == true, arguments?.get("streaming") == true)
                        result.success(null)
                    }
                    "showOnWidget" -> {
                        val arguments = call.arguments as? Map<*, *>
                        NowPlayingWidget.show(
                            context,
                            arguments?.get("title") as? String,
                            arguments?.get("artist") as? String,
                            arguments?.get("playing") == true,
                            arguments?.get("cover") as? String,
                            arguments?.get("favorite") == true,
                            arguments?.get("shuffle") == true,
                        )
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
        pcmChannel?.setStreamHandler(null)
        pcm.stop()
        platformChannel = null
        powerChannel = null
        pcmChannel = null
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

    /**
     * How long, in milliseconds, sound takes from the player to the ears when media goes to a Bluetooth device (its codec
     * and radio, often 150 to 300 ms); 0 for anything else, where it is too short to see. Android tells it only through
     * a hidden method, which ExoPlayer uses for its timing too; 0 when that isn't there.
     */
    private fun bluetoothOutputLatency(context: Context): Int {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return 0
        val bluetooth = setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_HEARING_AID,
        )
        val toBluetooth = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val media = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build()
            audio.getAudioDevicesForAttributes(media).any { it.type in bluetooth }
        } else {
            @Suppress("DEPRECATION")
            audio.isBluetoothA2dpOn
        }
        if (!toBluetooth) return 0
        return try {
            val method = AudioManager::class.java.getMethod("getOutputLatency", Int::class.javaPrimitiveType)
            (method.invoke(audio, AudioManager.STREAM_MUSIC) as? Int)?.coerceIn(0, 1000) ?: 0
        } catch (e: Exception) {
            0
        }
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

    /**
     * Opens Android's share sheet with a copy of the log at [path], for sending it to whoever helps: the log itself is in
     * the app's private storage, out of the user's reach. The copy goes in the cache's shared/ folder, the only one
     * [WiretuneFileProvider] hands out, and the app picked may read it for this share only.
     */
    private fun shareLog(context: Context, path: String?, result: MethodChannel.Result) {
        val log = path?.let(::File)
        if (log == null || !log.isFile) {
            result.error("missing", "No log at $path", null)
            return
        }
        try {
            val shared = File(context.cacheDir, "shared").apply { mkdirs() }
            val copy = log.copyTo(File(shared, "wiretune.log"), overwrite = true)
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.wiretune.shared", copy)
            val send = Intent(Intent.ACTION_SEND)
                .setType("text/plain")
                .putExtra(Intent.EXTRA_STREAM, uri)
                .putExtra(Intent.EXTRA_SUBJECT, "wiretune.log")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val chooser = Intent.createChooser(send, null)
            val activity = activityBinding?.activity
            if (activity != null) {
                activity.startActivity(chooser)
            } else {
                context.startActivity(chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
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

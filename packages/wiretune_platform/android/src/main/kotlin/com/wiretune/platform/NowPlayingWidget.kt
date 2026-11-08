// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

package com.wiretune.platform

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Bundle
import android.support.v4.media.MediaBrowserCompat
import android.support.v4.media.session.MediaControllerCompat
import android.view.KeyEvent
import android.widget.RemoteViews
import java.io.File

/**
 * The home-screen widget: the cover, title and artist of what plays, with previous, play or pause, and next; made two
 * cells tall, also the heart and shuffle. The app tells it what plays ([show], over `wiretune/power`'s `showOnWidget`),
 * and it keeps the last of it, so a widget added later shows it too. Previous, play and next are a headset's media
 * buttons, sent to the app's media session (audio_service's receiver); the heart and shuffle are the session's own
 * actions, as the notification's are ([sendToSession]). They work with the app in the background; a tap elsewhere opens
 * the app.
 */
class NowPlayingWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, views(context, manager.getAppWidgetOptions(id)))
    }

    /** Resized: one line or two. */
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        manager.updateAppWidget(id, views(context, options))
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = when (intent.action) {
            ACTION_FAVORITE -> "favorite"
            ACTION_SHUFFLE -> "shuffle"
            else -> return super.onReceive(context, intent)
        }
        sendToSession(context, action, goAsync())
    }

    companion object {
        private const val ACTION_FAVORITE = "com.wiretune.platform.widget.FAVORITE"
        private const val ACTION_SHUFFLE = "com.wiretune.platform.widget.SHUFFLE"

        /** The media session's service, which audio_service declares in the app. */
        private const val MEDIA_SERVICE = "com.ryanheise.audioservice.AudioService"

        /** From this height on (in dp) the widget has its second line. */
        private const val TWO_LINES_FROM = 100

        /**
         * Asks the app's media session to do its own [action] (the heart's or shuffle's, as the notification's buttons
         * do): connects to its service, sends the action and lets go, then lets the broadcast that asked end.
         */
        private fun sendToSession(context: Context, action: String, pending: PendingResult) {
            var browser: MediaBrowserCompat? = null
            val done = {
                browser?.disconnect()
                pending.finish()
            }
            browser = MediaBrowserCompat(
                context,
                ComponentName(context.packageName, MEDIA_SERVICE),
                object : MediaBrowserCompat.ConnectionCallback() {
                    override fun onConnected() {
                        val token = browser?.sessionToken
                        if (token != null) MediaControllerCompat(context, token).transportControls.sendCustomAction(action, null)
                        done()
                    }

                    override fun onConnectionFailed() = done()

                    override fun onConnectionSuspended() = done()
                },
                null,
            )
            browser.connect()
        }

        private const val PREFERENCES = "wiretune_widget"

        /** The media session's receiver of media buttons, which audio_service declares in the app. */
        private const val MEDIA_BUTTON_RECEIVER = "com.ryanheise.audioservice.MediaButtonReceiver"

        /** The cover's side in pixels: enough for the widget's 56 dp at any density, small enough to send. */
        private const val COVER_PIXELS = 192

        /**
         * Remembers what plays ([cover]: a picture file, or null; whether it is a [favorite]; whether [shuffle] is on)
         * and redraws the widgets on the home screen.
         */
        fun show(
            context: Context,
            title: String?,
            artist: String?,
            playing: Boolean,
            cover: String?,
            favorite: Boolean,
            shuffle: Boolean,
        ) {
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
                .putString("title", title)
                .putString("artist", artist)
                .putBoolean("playing", playing)
                .putString("cover", cover)
                .putBoolean("favorite", favorite)
                .putBoolean("shuffle", shuffle)
                .apply()
            val manager = AppWidgetManager.getInstance(context)
            for (id in manager.getAppWidgetIds(ComponentName(context, NowPlayingWidget::class.java))) {
                manager.updateAppWidget(id, views(context, manager.getAppWidgetOptions(id)))
            }
        }

        private fun views(context: Context, options: Bundle): RemoteViews {
            val saved = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            val title = saved.getString("title", null)
            val playing = saved.getBoolean("playing", false)
            val twoLines = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) >= TWO_LINES_FROM
            val layout = if (twoLines) R.layout.wiretune_widget_large else R.layout.wiretune_widget
            return RemoteViews(context.packageName, layout).apply {
                if (twoLines) {
                    setImageViewResource(
                        R.id.wiretune_widget_favorite,
                        if (saved.getBoolean("favorite", false)) {
                            R.drawable.wiretune_widget_favorite
                        } else {
                            R.drawable.wiretune_widget_favorite_border
                        },
                    )
                    setImageViewResource(
                        R.id.wiretune_widget_shuffle,
                        if (saved.getBoolean("shuffle", false)) {
                            R.drawable.wiretune_widget_shuffle_on
                        } else {
                            R.drawable.wiretune_widget_shuffle
                        },
                    )
                    setOnClickPendingIntent(R.id.wiretune_widget_favorite, ownAction(context, ACTION_FAVORITE))
                    setOnClickPendingIntent(R.id.wiretune_widget_shuffle, ownAction(context, ACTION_SHUFFLE))
                }
                setTextViewText(R.id.wiretune_widget_title, title ?: context.getString(R.string.wiretune_widget_name))
                setTextViewText(
                    R.id.wiretune_widget_artist,
                    if (title == null) context.getString(R.string.wiretune_widget_idle) else saved.getString("artist", ""),
                )
                val cover = saved.getString("cover", null)?.let(::coverBitmap)
                if (cover != null) {
                    setImageViewBitmap(R.id.wiretune_widget_cover, cover)
                } else {
                    setImageViewResource(R.id.wiretune_widget_cover, context.applicationInfo.icon)
                }
                setImageViewResource(
                    R.id.wiretune_widget_play,
                    if (playing) R.drawable.wiretune_widget_pause else R.drawable.wiretune_widget_play,
                )
                setOnClickPendingIntent(R.id.wiretune_widget_previous, mediaButton(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS))
                setOnClickPendingIntent(R.id.wiretune_widget_play, mediaButton(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
                setOnClickPendingIntent(R.id.wiretune_widget_next, mediaButton(context, KeyEvent.KEYCODE_MEDIA_NEXT))
                context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
                    setOnClickPendingIntent(
                        R.id.wiretune_widget,
                        PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_IMMUTABLE),
                    )
                }
            }
        }

        /** The widget's own [action], back to itself ([onReceive]). */
        private fun ownAction(context: Context, action: String): PendingIntent {
            val intent = Intent(action).setComponent(ComponentName(context, NowPlayingWidget::class.java))
            return PendingIntent.getBroadcast(context, action.hashCode(), intent, PendingIntent.FLAG_IMMUTABLE)
        }

        /** A press of the media button [keyCode], as a headset sends it. */
        private fun mediaButton(context: Context, keyCode: Int): PendingIntent {
            val intent = Intent(Intent.ACTION_MEDIA_BUTTON)
                .setComponent(ComponentName(context.packageName, MEDIA_BUTTON_RECEIVER))
                .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
            return PendingIntent.getBroadcast(context, keyCode, intent, PendingIntent.FLAG_IMMUTABLE)
        }

        /** The picture at [path], decoded small; null when it is gone or isn't a picture. */
        private fun coverBitmap(path: String): Bitmap? {
            if (!File(path).isFile) return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= COVER_PIXELS && bounds.outHeight / (sample * 2) >= COVER_PIXELS) {
                sample *= 2
            }
            val decoded = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
                ?: return null
            // Its shorter side to COVER_PIXELS, keeping its shape: the widget crops it to a square.
            val scale = COVER_PIXELS.toFloat() / minOf(decoded.width, decoded.height)
            if (scale >= 1f) return decoded
            return Bitmap.createScaledBitmap(
                decoded,
                (decoded.width * scale).toInt().coerceAtLeast(1),
                (decoded.height * scale).toInt().coerceAtLeast(1),
                true,
            )
        }
    }
}

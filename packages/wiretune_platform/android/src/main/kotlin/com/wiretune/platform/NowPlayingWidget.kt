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
import android.view.KeyEvent
import android.widget.RemoteViews
import java.io.File

/**
 * The home-screen widget: the cover, title and artist of what plays, with previous, play or pause, and next. The app
 * tells it what plays ([show], over `wiretune/power`'s `showOnWidget`), and it keeps the last of it, so a widget added
 * later shows it too. Its buttons are a headset's media buttons, sent to the app's media session (audio_service's
 * receiver), so they work with the app in the background; a tap elsewhere opens the app.
 */
class NowPlayingWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        manager.updateAppWidget(ids, views(context))
    }

    companion object {
        private const val PREFERENCES = "wiretune_widget"

        /** The media session's receiver of media buttons, which audio_service declares in the app. */
        private const val MEDIA_BUTTON_RECEIVER = "com.ryanheise.audioservice.MediaButtonReceiver"

        /** The cover's side in pixels: enough for the widget's 56 dp at any density, small enough to send. */
        private const val COVER_PIXELS = 192

        /** Remembers what plays ([cover]: a picture file, or null) and redraws the widgets on the home screen. */
        fun show(context: Context, title: String?, artist: String?, playing: Boolean, cover: String?) {
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
                .putString("title", title)
                .putString("artist", artist)
                .putBoolean("playing", playing)
                .putString("cover", cover)
                .apply()
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, NowPlayingWidget::class.java))
            if (ids.isNotEmpty()) manager.updateAppWidget(ids, views(context))
        }

        private fun views(context: Context): RemoteViews {
            val saved = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            val title = saved.getString("title", null)
            val playing = saved.getBoolean("playing", false)
            return RemoteViews(context.packageName, R.layout.wiretune_widget).apply {
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

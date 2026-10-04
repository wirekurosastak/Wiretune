package com.wiretune.player

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import com.ryanheise.audioservice.AudioServiceActivity

/**
 * The activity shares its Flutter engine with the media service (AudioServiceActivity), so the music, the notification
 * and Android Auto keep running when the activity is closed.
 *
 * It also asks for the display's highest refresh rate while the user touches the screen or a flick is gliding, and
 * withdraws the wish when nothing has happened for a while. Many phones with a variable refresh rate (Xiaomi's HyperOS in
 * particular) otherwise run an app's surface at 60 Hz or lower, because it says nothing about the rate it wants; when the
 * wish is withdrawn the panel can drop to a low rate and save battery again.
 */
class MainActivity : AudioServiceActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private var boosted = false
    private val relax = Runnable { setPreferredMode(0) }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (!boosted) setPreferredMode(fastestModeId())
        handler.removeCallbacks(relax)
        handler.postDelayed(relax, BOOST_MS)
        return super.dispatchTouchEvent(event)
    }

    override fun onPause() {
        handler.removeCallbacks(relax)
        setPreferredMode(0)
        super.onPause()
    }

    /** The mode with the highest refresh rate at the current resolution, or 0 (no preference). */
    private fun fastestModeId(): Int {
        @Suppress("DEPRECATION")
        val display = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else windowManager.defaultDisplay)
            ?: return 0
        val current = display.mode
        return display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .maxByOrNull { it.refreshRate }
            ?.modeId ?: 0
    }

    private fun setPreferredMode(modeId: Int) {
        boosted = modeId != 0
        val attributes = window.attributes
        if (attributes.preferredDisplayModeId == modeId) return
        attributes.preferredDisplayModeId = modeId
        window.attributes = attributes
    }

    private companion object {
        // How long the high refresh rate stays after the last touch: long enough for the glide of a fast flick.
        const val BOOST_MS = 3500L
    }
}

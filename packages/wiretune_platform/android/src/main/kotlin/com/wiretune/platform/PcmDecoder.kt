// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

package com.wiretune.platform

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.plugin.common.EventChannel
import java.nio.ByteOrder
import kotlin.math.floor

/**
 * Answers `wiretune/pcm`: the track given on listening (a file path or a stream URL) decoded by Android's own decoder
 * for the spectrum, as the app's PCM cache takes it from `ffmpeg` on a computer: 16-bit mono 44.1 kHz, little-endian,
 * in chunks of about a second. One track at a time; cancelling stops it.
 *
 * It never touches the audio that plays: a stream is fetched from the server a second time. An error says only what
 * kind it was, never the source, whose URL holds the stream token. Given as `{source, fromMs}`, it starts at that time
 * in the track (after a jump in it), so the bars don't wait for everything before it to be decoded.
 */
class PcmDecoder : EventChannel.StreamHandler {
    private var decoding: Decoding? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        stop()
        val map = arguments as? Map<*, *>
        val source = map?.get("source") as? String ?: arguments as? String
        if (source == null) {
            events.endOfStream()
            return
        }
        val fromUs = ((map?.get("fromMs") as? Number)?.toLong() ?: 0L) * 1000
        decoding = Decoding(source, fromUs, events).also { it.start() }
    }

    override fun onCancel(arguments: Any?) = stop()

    fun stop() {
        decoding?.stopped = true
        decoding = null
    }

    private class Decoding(
        private val source: String,
        private val fromUs: Long,
        private val events: EventChannel.EventSink,
    ) : Thread("wiretune-pcm") {
        @Volatile var stopped = false
        private val main = Handler(Looper.getMainLooper())

        /** The samples decoded and not sent yet. */
        private val chunk = ShortArray(RATE)
        private var filled = 0

        override fun run() {
            // The music plays on; this is only for the bars.
            Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
            val extractor = MediaExtractor()
            var codec: MediaCodec? = null
            try {
                extractor.setDataSource(source)
                val track = (0 until extractor.trackCount).firstOrNull {
                    extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
                }
                if (track == null) {
                    post { events.error("decode", "no audio track", null) }
                    return
                }
                extractor.selectTrack(track)
                // To the frame at or before the time; what comes before it is dropped as it is decoded.
                if (fromUs > 0) extractor.seekTo(fromUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                val format = extractor.getTrackFormat(track)
                codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
                codec.configure(format, null, null, 0)
                codec.start()
                decode(extractor, codec, format)
                if (!stopped) {
                    send()
                    post { events.endOfStream() }
                }
            } catch (e: Exception) {
                post { events.error("decode", e.javaClass.simpleName, null) }
            } finally {
                try {
                    codec?.stop()
                } catch (ignored: IllegalStateException) {
                    // Failed before it started.
                }
                codec?.release()
                extractor.release()
            }
        }

        private fun decode(extractor: MediaExtractor, codec: MediaCodec, format: MediaFormat) {
            val info = MediaCodec.BufferInfo()
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var resampler = Resampler(rate)
            var float = false
            var inputDone = false
            while (!stopped) {
                if (!inputDone) {
                    val index = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (index >= 0) {
                        val size = extractor.readSampleData(codec.getInputBuffer(index)!!, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val index = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val output = codec.outputFormat
                    channels = output.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    rate = output.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    resampler = Resampler(rate)
                    float = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                        output.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        output.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                } else if (index >= 0) {
                    val buffer = codec.getOutputBuffer(index)!!.order(ByteOrder.LITTLE_ENDIAN)
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    // Each frame's channels mixed into one, -1..1.
                    val mono = if (float) {
                        val samples = buffer.asFloatBuffer()
                        FloatArray(samples.remaining() / channels) { frame ->
                            var sum = 0f
                            for (c in 0 until channels) sum += samples.get(frame * channels + c)
                            sum / channels
                        }
                    } else {
                        val samples = buffer.asShortBuffer()
                        FloatArray(samples.remaining() / channels) { frame ->
                            var sum = 0f
                            for (c in 0 until channels) sum += samples.get(frame * channels + c)
                            sum / channels / 32768f
                        }
                    }
                    codec.releaseOutputBuffer(index, false)
                    // The frames before the time asked for, from the sync frame the jump landed on.
                    val early = if (info.presentationTimeUs < fromUs) {
                        ((fromUs - info.presentationTimeUs) * rate / 1_000_000L).toInt().coerceAtMost(mono.size)
                    } else {
                        0
                    }
                    resampler.feed(if (early > 0) mono.copyOfRange(early, mono.size) else mono) { add(it) }
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }

        private fun add(sample: Float) {
            chunk[filled++] = (sample.coerceIn(-1f, 1f) * 32767f).toInt().toShort()
            if (filled == chunk.size) send()
        }

        /** The samples so far, as little-endian bytes, to the app. */
        private fun send() {
            if (filled == 0) return
            val bytes = ByteArray(filled * 2)
            for (i in 0 until filled) {
                val sample = chunk[i].toInt()
                bytes[i * 2] = sample.toByte()
                bytes[i * 2 + 1] = (sample shr 8).toByte()
            }
            filled = 0
            post { events.success(bytes) }
        }

        private fun post(event: () -> Unit) = main.post { if (!stopped) event() }
    }

    /** Takes mono samples at [from] Hz to [RATE], each new one between the two nearest old ones. */
    private class Resampler(from: Int) {
        private val step = from.toDouble() / RATE

        /** Where the next sample falls, in the next buffer's samples; -1 is the last buffer's last. */
        private var position = 0.0
        private var last = 0f

        fun feed(samples: FloatArray, emit: (Float) -> Unit) {
            if (samples.isEmpty()) return
            while (position < samples.size - 1) {
                val index = floor(position).toInt()
                val a = if (index < 0) last else samples[index]
                val b = samples[index + 1]
                emit(a + (b - a) * (position - index).toFloat())
                position += step
            }
            last = samples[samples.size - 1]
            position -= samples.size
        }
    }

    private companion object {
        const val RATE = 44100
        const val TIMEOUT_US = 10_000L
    }
}

package com.miquottty.drivescope.audio

import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.SystemClock
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/** Where the beep came out and when (iOS `SyncBeep`): `onsetBoot` on the elapsedRealtime clock, NaN if unknown. */
data class SyncBeep(val onsetBoot: Double, val latency: Double, val route: Int)

/**
 * The SYNC beep and the satellite chime, the same sounds as iOS (`SyncBeeper.swift`):
 * - SYNC "chirp3-v1": 2.5 kHz pips of 40 ms at 0 / 160 / 400 ms — keep the editor's detector in step
 * - chime: 1.0 kHz 80 ms, then 1.5 kHz 120 ms at 120 ms (never taken for a SYNC)
 *
 * The SYNC marker is the first pip's onset at the output: the track's timestamp (frame ↔ `System.nanoTime`, the
 * monotonic clock) is mapped onto elapsedRealtime, the clock of the recording.
 */
class SyncBeeper {
    private class Tone(val onset: Double, val duration: Double, val frequency: Double)

    private val sync = pcm(listOf(0.0, 0.160, 0.400).map { Tone(LEAD + it, 0.040, 2_500.0) })
    private val chime = pcm(listOf(Tone(0.0, 0.080, 1_000.0), Tone(0.120, 0.120, 1_500.0)))

    /** Plays the SYNC pattern and waits (≤ 0.6 s) for the output timestamp. Call off the main thread. */
    fun playSync(): SyncBeep {
        val track = track(sync)
        val playedAt = System.nanoTime()
        track.play()
        val timestamp = AudioTimestamp()
        val deadline = playedAt + 600_000_000L
        var onsetNano = Double.NaN
        while (System.nanoTime() < deadline) {
            if (track.getTimestamp(timestamp) && timestamp.framePosition > 0) {
                // Frame LEAD·rate (the first pip) reaches the output this long after the stamped frame.
                val leadFrames = LEAD * RATE
                onsetNano = timestamp.nanoTime + (leadFrames - timestamp.framePosition) / RATE * 1e9
                break
            }
            Thread.sleep(5)
        }
        val bootMinusMonotonic = SystemClock.elapsedRealtimeNanos() - System.nanoTime()
        val onsetBoot = if (onsetNano.isNaN()) Double.NaN else (onsetNano + bootMinusMonotonic) / 1e9
        val latency = if (onsetNano.isNaN()) 0.0 else (onsetNano - playedAt) / 1e9 - LEAD
        val route = route(track.routedDevice)
        Thread.sleep(500) // let the pattern finish before releasing the track
        track.release()
        return SyncBeep(onsetBoot, latency.coerceAtLeast(0.0), route)
    }

    fun playChime() {
        val track = track(chime)
        track.play()
        Thread.sleep(300)
        track.release()
    }

    private fun track(samples: FloatArray): AudioTrack {
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build(),
            )
            .setAudioFormat(
                AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_FLOAT).setSampleRate(RATE.toInt())
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build(),
            )
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(samples.size * 4)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
        track.write(samples, 0, samples.size, AudioTrack.WRITE_BLOCKING)
        return track
    }

    /** The device the beep actually played on → 0 speaker, 1 Bluetooth / car / wireless, 2 other (iOS `SyncBeep.Route`). */
    private fun route(output: AudioDeviceInfo?): Int {
        return when (output?.type) {
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> 0
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> 1
            else -> 2
        }
    }

    companion object {
        const val RATE = 48_000.0
        /** Silence before the first pip, so the track is running when the measured part plays. */
        const val LEAD = 0.1
        /** Raised-cosine ramps so the pips don't click (a click is broadband and blurs the onset). */
        private const val RAMP = 0.005

        private fun pcm(tones: List<Tone>): FloatArray {
            val total = tones.maxOf { it.onset + it.duration }
            val samples = FloatArray((total * RATE).toInt())
            val rampFrames = RAMP * RATE
            for (tone in tones) {
                val start = (tone.onset * RATE).toInt()
                val frames = (tone.duration * RATE).toInt()
                for (j in 0 until frames) {
                    if (start + j >= samples.size) break
                    val edge = min(j, frames - 1 - j).toDouble()
                    val gain = if (edge < rampFrames) 0.5 - 0.5 * cos(PI * edge / rampFrames) else 1.0
                    samples[start + j] = (0.9 * gain * sin(2 * PI * tone.frequency * j / RATE)).toFloat()
                }
            }
            return samples
        }
    }
}

package com.miquottty.drivescope.probe

import android.annotation.SuppressLint
import android.location.GnssStatus
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlin.math.abs

/**
 * What iOS cannot tell us (PLAN §9.3): satellites seen / used, signal strength, constellations and the
 * time to first fix, next to the raw GPS-provider fix.
 */
data class GnssSnapshot(
    val visible: Int = 0,
    val used: Int = 0,
    /** Mean C/N0 (dB-Hz) of the four strongest satellites used in the fix; the usual "fix quality" measure. */
    val top4Cn0: Double? = null,
    /** Constellation name → satellites used. */
    val usedByConstellation: Map<String, Int> = emptyMap(),
    /** Satellites used on the L5 / E5a band (≈1176 MHz). */
    val usedOnL5: Int = 0,
    /** From GnssStatus.Callback.onFirstFix. */
    val firstFixSeconds: Double? = null,
    val secondsSinceStart: Double = 0.0,
    val fix: Location? = null,
    val fixCount: Int = 0,
)

class GnssProbe(private val locationManager: LocationManager) {
    private val state = MutableStateFlow(GnssSnapshot())
    val snapshot: StateFlow<GnssSnapshot> = state.asStateFlow()

    private val handler = Handler(Looper.getMainLooper())
    private var startedAt = 0L

    private val statusCallback = object : GnssStatus.Callback() {
        override fun onFirstFix(ttffMillis: Int) {
            state.update { it.copy(firstFixSeconds = ttffMillis / 1000.0) }
        }

        override fun onSatelliteStatusChanged(status: GnssStatus) {
            val used = (0 until status.satelliteCount).filter { status.usedInFix(it) }
            val top4 = used.map { status.getCn0DbHz(it).toDouble() }.sortedDescending().take(4)
            val byConstellation = used.groupingBy { constellationName(status.getConstellationType(it)) }.eachCount()
            val l5 = used.count { status.hasCarrierFrequencyHz(it) && abs(status.getCarrierFrequencyHz(it) - 1_176.45e6) < 5e6 }
            state.update {
                it.copy(
                    visible = status.satelliteCount,
                    used = used.size,
                    top4Cn0 = if (top4.isEmpty()) null else top4.average(),
                    usedByConstellation = byConstellation,
                    usedOnL5 = l5,
                    secondsSinceStart = secondsSinceStart(),
                )
            }
        }
    }

    private val locationListener = LocationListener { location ->
        state.update { it.copy(fix = location, fixCount = it.fixCount + 1, secondsSinceStart = secondsSinceStart()) }
    }

    @SuppressLint("MissingPermission") // The caller starts the probe only once fine location is granted.
    fun start() {
        startedAt = SystemClock.elapsedRealtime()
        state.value = GnssSnapshot()
        locationManager.registerGnssStatusCallback(statusCallback, handler)
        locationManager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1_000L, 0f, locationListener, Looper.getMainLooper())
    }

    fun stop() {
        locationManager.unregisterGnssStatusCallback(statusCallback)
        locationManager.removeUpdates(locationListener)
    }

    private fun secondsSinceStart() = (SystemClock.elapsedRealtime() - startedAt) / 1000.0

    companion object {
        fun constellationName(type: Int): String = when (type) {
            GnssStatus.CONSTELLATION_GPS -> "GPS"
            GnssStatus.CONSTELLATION_GLONASS -> "GLONASS"
            GnssStatus.CONSTELLATION_GALILEO -> "Galileo"
            GnssStatus.CONSTELLATION_BEIDOU -> "BeiDou"
            GnssStatus.CONSTELLATION_QZSS -> "QZSS"
            GnssStatus.CONSTELLATION_SBAS -> "SBAS"
            GnssStatus.CONSTELLATION_IRNSS -> "NavIC"
            else -> "Other"
        }
    }
}

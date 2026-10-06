package com.miquottty.drivescope

import com.miquottty.drivescope.recording.Conventions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConventionsTest {
    /** Pixel 7, flat and screen up: Android reports +9.81 on z, Core Motion −1 g (measured in the S0 spike). */
    @Test
    fun androidReactionForceBecomesCoreMotionG() {
        assertEquals(-1f, Conventions.toCoreMotion(9.80665f), 1e-6f)
        assertEquals(0.932f, Conventions.toCoreMotion(-9.139f), 1e-3f) // right edge down: iOS x ≈ +0.93
        assertEquals(100.0f, Conventions.toKPa(1000f), 1e-4f)
    }

    /**
     * 200 Hz input with delivery jitter → a 50 Hz record stream with no gap DriveKit counts as a drop (> 30 ms), and a
     * stall restarts the grid instead of bursting.
     */
    @Test
    fun gridThinsTo50HzWithoutDropsAndRestartsAfterAStall() {
        val grid = Conventions.Grid(50.0)
        val taken = mutableListOf<Long>()
        var t = 1_000_000_000L
        repeat(2_000) { i ->
            t += 5_000_000L + (if (i % 7 == 0) 1_300_000L else -200_000L) // ~5 ms, jittered
            if (grid.take(t)) taken += t
        }
        val gaps = taken.zipWithNext { a, b -> (b - a) / 1e6 }
        assertTrue("max gap ${gaps.max()} ms", gaps.max() <= 30.0)
        assertEquals(50.0, taken.size / ((taken.last() - taken.first()) / 1e9), 1.0)

        t += 2_000_000_000L // 2 s stall
        assertTrue(grid.take(t))
        assertTrue(!grid.take(t + 5_000_000L))
    }
}

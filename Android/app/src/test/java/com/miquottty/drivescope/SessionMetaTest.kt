package com.miquottty.drivescope

import com.miquottty.drivescope.store.ManifestDate
import com.miquottty.drivescope.store.SessionMeta
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class SessionMetaTest {
    /** `session.json` is the Android stand-in for SwiftData: everything the list and Detail need must survive a round trip. */
    @Test
    fun sessionJsonRoundTrips() {
        val meta = SessionMeta(
            id = "0CA4D72A-CF39-486A-AE44-5C77449134A8",
            state = SessionMeta.State.STOPPED,
            title = "足利市 → 太田市",
            titleIsUserEdited = true,
            notes = "雨",
            startedAt = ManifestDate.parse("2026-10-06T09:38:29.398090Z"),
            endedAt = 1_791_281_598.5,
            summary = JSONObject().put("distance", 12_951.4).put("duration", 2_089.1),
            routePreview = listOf(36.31 to 139.47, 36.29 to 139.39),
            places = listOf(JSONObject().put("role", "start").put("locality", "足利市").put("latitude", 36.31).put("longitude", 139.47)),
            sections = JSONArray().put(JSONObject().put("kind", "corner")),
            sectionsVersion = 2,
            peakLateralElapsed = 380.4,
        )
        val back = SessionMeta.fromJson(JSONObject(meta.toJson().toString()))
        assertEquals(meta.toJson().toString(), back.toJson().toString())
        assertEquals(1_791_279_509.39809, back.startedAt, 1e-6)
        assertEquals("足利市", back.place("start")?.getString("locality"))
    }
}

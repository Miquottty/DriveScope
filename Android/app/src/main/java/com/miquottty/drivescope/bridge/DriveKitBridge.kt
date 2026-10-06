package com.miquottty.drivescope.bridge

/**
 * DriveKit (Swift) on the phone, through JNI — Android/swift/DriveKitBridge, built by Android/swift/build-bridge.sh.
 * The spike's test of sharing the iOS core instead of porting it (docs/ANDROID_SPIKE.md).
 */
object DriveKitBridge {
    init {
        System.loadLibrary("c++_shared")
        System.loadLibrary("DriveKitBridge")
    }

    /**
     * Foundation writes `.atomic` files through the temporary directory, which Android leaves unset (→ /tmp, not
     * writable). Call once with the app's cache directory before anything else.
     */
    fun configure(cacheDir: String) {
        android.system.Os.setenv("TMPDIR", cacheDir, true)
    }

    /** The app's JSON export of `sessionDir` into `outDir`; returns the file path or "error: …". */
    external fun exportJson(sessionDir: String, title: String, workDir: String, outDir: String): String

    /** A few Quality-screen figures for `sessionDir`, computed by DriveKit. */
    external fun quality(sessionDir: String): String
}

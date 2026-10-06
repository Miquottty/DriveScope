package com.miquottty.drivescope

import android.Manifest
import android.content.pm.PackageManager
import android.hardware.SensorManager
import android.location.LocationManager
import android.os.Bundle
import java.io.File
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.miquottty.drivescope.map.MapScreen
import com.miquottty.drivescope.probe.GnssProbe
import com.miquottty.drivescope.probe.MotionProbe
import com.miquottty.drivescope.probe.ProbeScreen

class MainActivity : ComponentActivity() {
    private lateinit var gnss: GnssProbe
    private lateinit var motion: MotionProbe

    private val locationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) gnss.start()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        gnss = GnssProbe(getSystemService(LocationManager::class.java))
        motion = MotionProbe(getSystemService(SensorManager::class.java))
        setContent {
            DriveScopeTheme {
                var mapSession by remember { mutableStateOf<File?>(null) }
                val session = mapSession
                if (session == null) {
                    ProbeScreen(gnss, motion, onOpenMap = { mapSession = it })
                } else {
                    MapScreen(session, onBack = { mapSession = null })
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        motion.start()
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) {
            gnss.start()
        } else {
            locationPermission.launch(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }

    override fun onStop() {
        super.onStop()
        motion.stop()
        gnss.stop()
    }
}

package com.miquottty.drivescope

import android.Manifest
import android.content.pm.PackageManager
import android.hardware.SensorManager
import android.location.LocationManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
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
            DriveScopeTheme { ProbeScreen(gnss, motion) }
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

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.compose.compiler)
}

android {
    namespace = "com.miquottty.drivescope"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.miquottty.drivescope"
        // Location-type foreground services (Android 14) are the recording model.
        minSdk = 34
        targetSdk = 37
        versionCode = 1
        versionName = "1.0"
        // DriveKitBridge is built for arm64 only (Pixel 7).
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    buildTypes {
        // Personal use: side-loaded debug-signed APKs only.
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    buildFeatures {
        compose = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.service)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.material3)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.maplibre.android)
    testImplementation(libs.junit)
    // org.json is part of Android but only stubbed in JVM unit tests.
    testImplementation(libs.org.json)
}

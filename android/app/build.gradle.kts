plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Google services Gradle plugin
    id("com.google.gms.google-services")
}

android {
    namespace = "com.example.lumix_h1"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required for MultiDex on older APIs
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.example.lumix_h1"

        // MultiDex requires minSdk 21 — Firebase also needs 21 minimum
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ── FIX: enables MultiDex so the app class can be found ──
        multiDexEnabled = true
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // ── MultiDex — fixes ClassNotFoundException on startup ────
    implementation("androidx.multidex:multidex:2.0.1")

    // ── Core library desugaring (needed for isCoreLibraryDesugaringEnabled) ──
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")

    // ── Firebase BoM — controls all Firebase versions together ──
    implementation(platform("com.google.firebase:firebase-bom:33.1.0"))

    // Firebase Realtime Database
    implementation("com.google.firebase:firebase-database")

    // Firebase Analytics (optional but often needed by BoM)
    implementation("com.google.firebase:firebase-analytics")
}

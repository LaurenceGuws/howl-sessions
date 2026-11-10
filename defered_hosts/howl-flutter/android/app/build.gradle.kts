plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "uk.laurencegouws.howl_sessions"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "uk.laurencegouws.howl_sessions"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    packaging {
        // The selected product host ships Android arm64 only. JNI helpers
        // supplied transitively by plugins must not add unsupported ABIs.
        jniLibs {
            excludes += setOf(
                "lib/armeabi-v7a/libdartjni.so",
                "lib/armeabi-v7a/libdatastore_shared_counter.so",
                "lib/x86_64/libdartjni.so",
                "lib/x86_64/libdatastore_shared_counter.so",
            )
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDir("../../native/android")
        }
    }
}

val howlServerClient = file("../../native/android/arm64-v8a/libhowl_sessions_native.so")

tasks.register("verifyHowlServerClient") {
    doLast {
        check(howlServerClient.isFile) {
            "missing composed native Client/Render; build it with hosts/howl-flutter/native/build-android.sh"
        }
    }
}

tasks.named("preBuild").configure {
    dependsOn("verifyHowlServerClient")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

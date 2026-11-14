plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.photoalbum.photo_album"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.photoalbum.photo_album"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = providers.environmentVariable("LUMABERTH_KEYSTORE").orNull?.let { file(it) }
            storePassword = providers.environmentVariable("LUMABERTH_SIGNING_PASSWORD").orNull
            keyAlias = "lumaberth"
            keyPassword = storePassword
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// AGP may otherwise emit an unsigned artifact when a signing field is absent.
tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    doFirst {
        require(!providers.environmentVariable("LUMABERTH_KEYSTORE").orNull.isNullOrBlank() &&
            !providers.environmentVariable("LUMABERTH_SIGNING_PASSWORD").orNull.isNullOrBlank()) {
            "Set LUMABERTH_KEYSTORE and LUMABERTH_SIGNING_PASSWORD for Android release builds."
        }
    }
}

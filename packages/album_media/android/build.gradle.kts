plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}
kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
group = "dev.photoalbum.media"
version = "1.0"
android {
    namespace = "dev.photoalbum.media"
    compileSdk = 36
    defaultConfig { minSdk = 30 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

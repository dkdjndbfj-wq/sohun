import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningFile = rootProject.file("key.properties")
val releaseSigningProperties = Properties()
val isReleaseTask = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true)
}
if (isReleaseTask && !releaseSigningFile.isFile) {
    throw GradleException(
        "Android release signing is not configured. Create android/key.properties " +
            "(keyAlias, keyPassword, storeFile, storePassword) before publishing."
    )
}
if (releaseSigningFile.isFile) {
    releaseSigningFile.inputStream().use(releaseSigningProperties::load)
}

android {
    namespace = "top.sohun.consumable_tracker"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "top.sohun.consumable_tracker"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Never ship an Android release signed with the public debug key.
            signingConfig = signingConfigs.create("release").apply {
                keyAlias = releaseSigningProperties.getProperty("keyAlias")
                keyPassword = releaseSigningProperties.getProperty("keyPassword")
                storeFile = releaseSigningProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = releaseSigningProperties.getProperty("storePassword")
            }
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
    // Android APKs launch the native mobile extension, not the Windows
    // window/tray bootstrap in lib/main.dart.
    target = "lib/main_mobile.dart"
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

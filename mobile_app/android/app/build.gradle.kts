import java.util.Base64
import java.util.Properties
import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeys = Properties()
val releaseKeyFile = rootProject.file(providers.environmentVariable("NOXBRAIN_SIGNING_PROPERTIES").orNull ?: "key.properties")
if (releaseKeyFile.exists()) releaseKeyFile.inputStream().use { releaseKeys.load(it) }
val releaseKeysPresent = listOf("storeFile", "storePassword", "keyAlias", "keyPassword").all { !releaseKeys.getProperty(it).isNullOrBlank() }
val playStoreBuild = providers.gradleProperty("noxbrainStore").orNull == "play"
if (playStoreBuild) {
    // The Android and Dart halves of the Play build must always match.
    val dartDefines = providers.gradleProperty("dart-defines").orNull.orEmpty()
        .split(",").filter { it.isNotBlank() }
        .map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
    check("NOXBRAIN_STORE=play" in dartDefines) { "Play build needs dart-define NOXBRAIN_STORE=play (use tools/build_android.ps1 -Store Play)." }
}
val validateReleaseSigning = tasks.register("validateReleaseSigning") {
    doLast { check(releaseKeysPresent) { "Release signing is required. Configure android/key.properties; debug signing is prohibited for release." } }
}
tasks.configureEach {
    // Resource/Kotlin compilation is useful before keys are available; gate
    // only final release packaging, never packageReleaseResources.
    if (name.matches(Regex("^(assemble|bundle|package).*Release$|^sign.*ReleaseBundle$"))) dependsOn(validateReleaseSigning)
}

android {
    namespace = "com.noxbrainsolarmonitoring"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.noxbrainsolarmonitoring"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 29 // Android 10+ local Wi-Fi NetworkSpecifier provisioning.
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseKeysPresent) create("production") {
            val configuredPath = File(releaseKeys.getProperty("storeFile"))
            storeFile = if (configuredPath.isAbsolute) configuredPath else releaseKeyFile.parentFile.resolve(configuredPath.path)
            storePassword = releaseKeys.getProperty("storePassword")
            keyAlias = releaseKeys.getProperty("keyAlias")
            keyPassword = releaseKeys.getProperty("keyPassword")
        }
    }
    buildTypes {
        release {
            signingConfig = if (releaseKeysPresent) signingConfigs.getByName("production") else null
        }
    }

    // Google Play build: no APK self-update permission/provider. The Dart
    // side gets NOXBRAIN_STORE=play from build_android.ps1 (dart-defines).
    if (playStoreBuild) {
        sourceSets.getByName("release").manifest.srcFile("src/play/AndroidManifest.xml")
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

dependencies {
    // FileProvider for handing the verified update APK to Android's installer.
    implementation("androidx.core:core:1.13.1")
}

import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing reads the keystore from env/secret values first (CI:
// KEYSTORE_BASE64, KEYSTORE_PASSWORD, KEY_PASSWORD, KEY_ALIAS), falling back to
// android/key.properties for local builds. There is no debug-key fallback: a
// release build without signing material fails instead of signing with the debug key.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        load(keystorePropertiesFile.inputStream())
    }
}

fun envOrProperty(env: String, property: String): String? =
    System.getenv(env) ?: keystoreProperties.getProperty(property)

val releaseStoreFile: java.io.File? = System.getenv("KEYSTORE_BASE64")?.let { base64 ->
    val out = layout.buildDirectory.file("keystore/harbor-release.jks").get().asFile
    out.parentFile.mkdirs()
    out.writeBytes(Base64.getDecoder().decode(base64.replace(Regex("\\s"), "")))
    out
} ?: keystoreProperties.getProperty("storeFile")?.let(::file)

val releaseStorePassword: String? = envOrProperty("KEYSTORE_PASSWORD", "storePassword")

val releaseKeyAlias: String? = envOrProperty("KEY_ALIAS", "keyAlias")

val releaseKeyPassword: String? = envOrProperty("KEY_PASSWORD", "keyPassword")

android {
    namespace = "dev.harbor.harbor_companion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.harbor.harbor_companion"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = releaseStoreFile
            storePassword = releaseStorePassword
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword
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

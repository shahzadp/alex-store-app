import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── Release signing ─────────────────────────────────────────────────────────
//
// Read from android/key.properties, which .gitignore excludes along with the
// *.jks it names. Nothing about the signing identity is in the repository, so a
// clone has none until someone supplies one — and the build says so rather than
// quietly producing something else.
//
// This used to read `signingConfig = signingConfigs.getByName("debug")`, which
// shipped release APKs signed with the Android debug key. That is worse than it
// sounds. The debug keystore is a public file whose password is literally
// "android", so anyone could build an APK Android would accept as an update to
// this app. And swapping in a real key later changes the signing identity, at
// which point Android refuses to install the update over the existing app and
// every install has to be uninstalled first. Fixing it now avoids both.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKey = keystorePropertiesFile.exists()
if (hasReleaseKey) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

// A release build with no key is a mistake, not a variant, so it stops here with
// the fix in the message. Keyed off the requested task rather than the build
// type, because Gradle configures every build type on every invocation and a
// plain `flutter build apk --debug` must not be blocked by a missing signing key.
if (hasReleaseKey.not() && gradle.startParameter.taskNames.any { it.contains("release", true) }) {
    throw GradleException(
        """
        |No release signing key.
        |
        |Expected ${keystorePropertiesFile.absolutePath}
        |which .gitignore excludes, so it is absent on a fresh clone.
        |
        |Create one with:
        |
        |  keytool -genkeypair -keystore app/release-keystore.jks \
        |    -storetype PKCS12 -alias alex-store -keyalg RSA -keysize 4096 \
        |    -validity 10000
        |
        |then write android/key.properties:
        |
        |  storePassword=<password>
        |  keyPassword=<password>
        |  keyAlias=alex-store
        |  storeFile=app/release-keystore.jks
        |
        |A debug build needs none of this:  flutter build apk --debug
        """.trimMargin(),
    )
}

// ── Which ABIs to package ───────────────────────────────────────────────────
//
// scripts/build-apk.mjs builds one libalex_store_native.so per ABI into
// src/main/jniLibs, and that directory is the only place that says which ABIs
// this app actually supports. Derived from it rather than hard-coded, so adding
// an ABI to the build script is the only change needed.
//
// Without this filter the APK is dishonest about what it runs on. Flutter
// honours --target-platform and builds only arm64, but plugins ship prebuilt
// native code for every ABI: path_provider pulls in jni_flutter, whose
// libdartjni.so covers arm64-V8A, armeabi-v7a and x86_64. Gradle merges those
// directories in regardless, so the APK ends up advertising armv7 and x86_64
// support that does not exist — there is no libflutter.so or libapp.so for
// either — and Android installs it on such a device and dies at launch.
//
// An empty jniLibs (a fresh clone that has not run cargo yet) means no
// filtering, which is the previous behaviour.
val engineAbis: List<String> = file("src/main/jniLibs")
    .listFiles { f -> f.isDirectory }
    ?.map { it.name }
    ?.sorted()
    .orEmpty()

android {
    namespace = "io.github.shahzadp.alex_store"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.shahzadp.alex_store"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        if (engineAbis.isNotEmpty()) {
            ndk {
                abiFilters.clear()
                abiFilters.addAll(engineAbis)
            }
        }
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storePassword = keystoreProperties.getProperty("storePassword")
                // Resolved against rootProject (android/), which is what the path
                // in key.properties is written relative to. The app module's own
                // file() would look in android/app/app/ and fail confusingly.
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))

                // APK Signature Scheme v3 alongside the v2 that AGP signs with by
                // default. v3 is what carries a key's rotation history, so it is
                // the difference between being able to rotate this key later and
                // every install having to be removed first — the exact trap that
                // moving off the debug key would have sprung, one key further
                // out. Devices older than Android 9 ignore the v3 block and
                // verify with v2. v1 is deliberately left off: it is only needed
                // below API 24, and this app's minSdk is 24.
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            // Null rather than a fallback to the debug key: a release build
            // without a real signing identity is not a thing this project
            // produces, and silently substituting the debug key is exactly the
            // behaviour being removed above.
            signingConfig =
                if (hasReleaseKey) signingConfigs.getByName("release") else null

            // R8: shrink and obfuscate. Flutter's own Gradle plugin turns both on
            // for release unless `-Pshrink=false` is passed (FlutterPlugin.kt
            // sets isMinifyEnabled, and isShrinkResources when built as an app),
            // so this is mostly a statement of intent — but it is the intent that
            // matters, and it should not be possible for it to quietly stop.
            //
            // R8 rewrites Java/Kotlin bytecode and nothing else. The semantic
            // search path contains no Java/Kotlin bytecode, which is the whole
            // argument in proguard-rules.pro and the thing
            // scripts/verify-release-apk.mjs checks in the built artifact.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.playernostalgico.player_nostalgico"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.playernostalgico.player_nostalgico"
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
    }

    // Chave fixa vinda dos secrets do GitHub (o CI grava em app/release.jks). Sem ela, usa a de debug.
    val releaseKeystore = file("release.jks")
    val keystorePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: ""
    signingConfigs {
        create("fixa") {
            storeFile = releaseKeystore
            storePassword = keystorePassword
            keyAlias = "nostalgic"
            keyPassword = keystorePassword
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseKeystore.exists() && keystorePassword.isNotEmpty()) signingConfigs.getByName("fixa") else signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // yt-dlp + Python + ffmpeg pesam ~50 MB por arquitetura: o APK de release leva só a dos celulares (arm64).
            ndk { abiFilters += listOf("arm64-v8a") }
        }
    }

    // O yt-dlp embarcado precisa das bibliotecas nativas extraídas em disco.
    packaging {
        jniLibs { useLegacyPackaging = true }
    }
}

// Garante que o release leve só arm64 (o Flutter e o yt-dlp trariam também armeabi-v7a, x86 e x86_64).
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(listOf("lib/armeabi-v7a/**", "lib/x86/**", "lib/x86_64/**"))
    }
}

dependencies {
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
    implementation("androidx.core:core-ktx:1.17.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

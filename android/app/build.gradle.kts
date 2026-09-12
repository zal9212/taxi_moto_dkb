import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Signature stable entre tous les builds release, generee une seule fois par
// android/app/upload-keystore.jks (voir android/key.properties.example) : sans
// elle, chaque build release re-signe avec la cle debug generee au hasard sur
// chaque machine/CI, et Android refuse d'installer une mise a jour signee
// differemment (obligeant a desinstaller, donc a perdre les donnees locales).
// Absent => on retombe sur la signature debug, pour ne jamais casser le build.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val keystoreDisponible = keystorePropertiesFile.exists()
if (keystoreDisponible) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.doukabusiness.moto_taxi_douka"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.doukabusiness.moto_taxi_douka"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystoreDisponible) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystoreDisponible) {
                signingConfigs.getByName("release")
            } else {
                // Repli : `key.properties` absent (contributeur sans la cle,
                // ou CI avant configuration des secrets). Permet au build de
                // continuer, mais produit un APK signe differemment a chaque
                // fois — voir le commentaire au-dessus de keystorePropertiesFile.
                signingConfigs.getByName("debug")
            }

            // Le "code shrinking" (R8) casse la (de)serialisation Gson interne
            // de flutter_local_notifications (TypeToken generique strippe),
            // ce qui fait planter la creation de moto des qu'un rappel est
            // programme. Desactive explicitement : cette app est petite,
            // le gain de taille d'APK n'en vaut pas la casse.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

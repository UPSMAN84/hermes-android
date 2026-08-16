import java.io.FileInputStream
import java.util.Properties

plugins {
   id("com.android.application")
   id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePath = rootProject.projectDir.parentFile.resolve("key.properties")
if (keystorePath.exists()) {
   keystoreProperties.load(FileInputStream(keystorePath))
}

android {
   namespace = "com.hermesagent.hermes_android"
   compileSdk = 36

   compileOptions {
       sourceCompatibility = JavaVersion.VERSION_17
       targetCompatibility = JavaVersion.VERSION_17
       isCoreLibraryDesugaringEnabled = true
   }

   defaultConfig {
       applicationId = "com.hermesagent.hermes_android"
       minSdk = 24
       targetSdk = 36
       versionCode = flutter.versionCode
       versionName = flutter.versionName
   }

   signingConfigs {
       create("release") {
           if (keystoreProperties.containsKey("storeFile")) {
               storeFile = file(keystoreProperties["storeFile"] as String)
               storePassword = keystoreProperties["storePassword"] as String
               keyAlias = keystoreProperties["keyAlias"] as String
               keyPassword = keystoreProperties["keyPassword"] as String
           }
       }
   }

   buildTypes {
       release {
           signingConfig = signingConfigs.getByName("release")
           // Shrink the Java/Kotlin half of the app. Dart is AOT-compiled and
           // tree-shaken separately, but the plugin code and Android resources
           // shipped unshrunk before this. Keep rules for the plugins that are
           // reached reflectively / from the manifest live in proguard-rules.pro.
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

dependencies {
   coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
   testImplementation("junit:junit:4.13.2")
}

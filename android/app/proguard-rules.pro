# Keep rules for release builds (isMinifyEnabled = true in build.gradle.kts).
#
# R8 only sees the Java/Kotlin side. Anything reached reflectively, by JNI, or
# by class name from a manifest/plugin registration has to be kept explicitly
# or it gets stripped and fails at runtime rather than at build time.

# Flutter embedding and the generated plugin registrant.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# media_kit / libmpv: the native layer calls back into these by JNI signature.
-keep class com.alexmercerind.** { *; }
-keep class media.kit.** { *; }

# flutter_foreground_task: the service and its task handler are instantiated
# by the OS from the manifest, and the Dart entry points are looked up by name.
-keep class com.pravera.flutter_foreground_task.** { *; }

# speech_to_text / audioplayers / image_picker use platform callbacks.
-keep class com.csdcorp.speech_to_text.** { *; }
-keep class xyz.luan.audioplayers.** { *; }

# Kotlin coroutines internals referenced reflectively.
-dontwarn kotlinx.coroutines.**
-keepclassmembers class kotlinx.coroutines.** { volatile <fields>; }

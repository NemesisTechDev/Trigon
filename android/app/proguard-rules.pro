# Nemesis release shrink rules. Plugins that call into Java by name (JNI /
# reflection) must not have those classes renamed or removed by R8.

# FFmpeg (cover conversion, TS remux)
-keep class com.antonkarpenko.ffmpegkit.** { *; }
-keep class com.arthenica.** { *; }

# Google Cast
-keep class com.felnanuke.google_cast.** { *; }
-keep class com.google.android.gms.cast.** { *; }

# Background audio / lock-screen widget
-keep class com.ryanheise.audioservice.** { *; }

# media_kit (libmpv JNI helpers)
-keep class com.alexmercerind.** { *; }

# Permissions, picture-in-picture
-keep class com.baseflow.permissionhandler.** { *; }
-keep class cl.puntito.simple_pip_mode.** { *; }

# Flutter references Play Core split-install classes it doesn't ship
-dontwarn com.google.android.play.core.**

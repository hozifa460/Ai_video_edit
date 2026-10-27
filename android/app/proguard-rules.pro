# Keep FFmpegKit / FFprobeKit JNI bridge classes (R8 strips them otherwise,
# which breaks video import in Release builds).
-keep class com.arthenica.** { *; }
-dontwarn com.arthenica.**

# Keep the bundled ffmpeg-kit Flutter plugin classes.
-keep class com.antonkarpenko.** { *; }
-dontwarn com.antonkarpenko.**

# Keep ML Kit classes used through platform channels.
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**

# Flutter ProGuard / R8 Rules

# Flutter Wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.**  { *; }

# Flutter Engine & Embedding
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# Firebase & Google Play Services
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# Desugaring JDK Libs
-dontwarn java.lang.invoke.**
-dontwarn java.time.**

# Hive
-keep class io.hivedb.** { *; }
-dontwarn io.hivedb.**

# Workmanager & AndroidX Background
-keep class androidx.work.** { *; }
-dontwarn androidx.work.**

# Package Info Plus & OTA Updater
-keep class dev.fluttercommunity.plus.packageinfo.** { *; }

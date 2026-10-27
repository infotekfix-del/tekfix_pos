# Flutter ProGuard / R8 Rules

# Preserve all annotations, signatures, and reflection metadata
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod,Exceptions

# Flutter Wrapper & Plugins
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.**  { *; }

# Flutter Engine & Embedding (v2)
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# Firebase Core, Auth, Firestore & Google Play Services
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# Desugaring JDK Libs
-dontwarn java.lang.invoke.**
-dontwarn java.time.**

# Hive Database & Box Adapters
-keep class io.hivedb.** { *; }
-dontwarn io.hivedb.**

# Workmanager & AndroidX Background / Lifecycle
-keep class androidx.work.** { *; }
-dontwarn androidx.work.**
-keep class androidx.lifecycle.** { *; }
-dontwarn androidx.lifecycle.**
-keep class androidx.core.** { *; }
-dontwarn androidx.core.**

# Package Info Plus
-keep class dev.fluttercommunity.plus.packageinfo.** { *; }
-dontwarn dev.fluttercommunity.plus.packageinfo.**

# Connectivity Plus
-keep class dev.fluttercommunity.plus.connectivity.** { *; }
-dontwarn dev.fluttercommunity.plus.connectivity.**

# OTA Update (FileProvider & InstallResultReceiver)
-keep class sk.fourq.otaupdate.** { *; }
-dontwarn sk.fourq.otaupdate.**

# Geolocator Location Services
-keep class com.baseflow.geolocator.** { *; }
-dontwarn com.baseflow.geolocator.**

# Printing & PDF rendering
-keep class net.nfet.flutter.printing.** { *; }
-dontwarn net.nfet.flutter.printing.**

# URL Launcher
-keep class io.flutter.plugins.urllauncher.** { *; }
-dontwarn io.flutter.plugins.urllauncher.**

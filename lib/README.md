# TekFix ERP — Cloud Sync + Staff Tracking

## Setup (once)
1. Copy `lib/` into your project (your old file is replaced by `lib/main.dart`; it must be named main.dart because the new files import it).
2. `flutter pub add firebase_core firebase_auth cloud_firestore connectivity_plus provider uuid`
3. `flutterfire configure` (Android + iOS + Windows) -> regenerates `firebase_options.dart`
4. Firebase console: enable Authentication > Email/Password; create Firestore (production mode).
5. `firebase deploy --only firestore:rules,firestore:indexes` (files in `firebase/`)
6. Optional but recommended: enable App Check.

## First run
1. On the Windows PC (the one with your real data): "First time? Create shop owner account". Its local data uploads once (it becomes the "seed" device).
2. On the phone: sign in with the same Shop ID. If the phone has old local data you will be asked to discard it and download from the cloud.
3. Owner > More > Staff Logins > add staff. Staff sign in on their own devices.

## Test checklist
- Bill on Windows -> appears on phone within seconds; Live tab updates.
- Airplane mode on Windows, make 3 bills, reconnect -> amber cloud -> rotating -> green tick; phone shows them.
- Sell the same item offline on both devices -> stock ends at (start - both qty).
- Staff login: no Cash & Bank / Reports / Settings / profit cards; Live tab absent.
- Owner voids a bill -> red warning on Live tab with who/when/device.
- Disable a staff account -> they are signed out on next profile load.

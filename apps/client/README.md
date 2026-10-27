# Ionic Flutter client

The product client is Flutter. It calls the `/api/v1` contract for account authorization, PostgreSQL persistence, and server-side recommendation ranking. The first release is text-first with optional photo and voice attachments; short video is deferred. The local web proxy defaults to the target Dart server on port 3001 so current Flutter features use the same backend contract. Set `IONIC_API_PORT=3000` to inspect the NestJS reference while route parity is being completed. Keep the Angular app as a rollback/reference until signed-in flows pass through Flutter and the Dart API.

## Local development

1. Install Flutter and its bundled Dart SDK, then confirm `flutter --version` works in the terminal that will run the app.
2. Start PostgreSQL with `docker compose -f compose.dev.yaml up -d db` from the project root.
3. From this directory, run `flutter pub get`.
4. Start the Dart API from `apps/server` with `DATABASE_URL=postgresql://ionic_app:ionic_local_only@127.0.0.1:5433/ionic?sslmode=disable`, `PORT=3001`, apply pending migrations with `dart run bin/migrate.dart`, then run `dart run lib/main.dart`. This explicit no-TLS mode is only for the loopback Compose database; shared and production databases must use verified TLS. The NestJS reference remains available on port 3000 while route parity is being completed.
5. Run `node tool/run_dev.mjs`. Flutter listens privately on port 4201; the local proxy serves the app at `http://127.0.0.1:4200` and forwards `/api` to port 3001 by default. Set `IONIC_API_PORT=3000` in the same shell to select NestJS. Use `IONIC_WEB_PORT` and `IONIC_FLUTTER_WEB_PORT` to run a parallel preview when the default ports are occupied. Both options keep authenticated cookies same-origin.
6. Build the web PWA with `flutter build web --release`.

## Native Android (first mobile target)

The Flutter Android project is under `android/` and uses application ID `app.ionic.mobile`. On an Android emulator, point the app at a server running on the development machine with:

On Windows, keep Pub's package cache on the same drive as the project. This avoids a Kotlin incremental-cache failure observed with a project on `D:` and a Pub cache on `C:`. From the repository root, use one PowerShell session for dependency resolution and builds:

```powershell
$env:PUB_CACHE = Join-Path $PWD '.pub-cache'
Set-Location apps/client
flutter pub get
```

The Android Gradle config disables Kotlin incremental compilation because the current Windows Kotlin toolchain failed while closing its plugin caches; clean Android builds can take longer as a result.

```powershell
flutter run -d <emulator-id> --dart-define=API_BASE_URL=http://10.0.2.2:3001/api/v1
```

`10.0.2.2` is the Android emulator's host bridge. For a physical phone, use the development machine's reachable LAN IP instead, bind the Dart server to `0.0.0.0`, and allow the phone to reach port 3001. The debug manifest allows cleartext traffic for local development only. Release builds must point to an HTTPS API:

```powershell
# Emulator debug build and install (from apps/client)
flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:3001/api/v1
adb install -r build\app\outputs\flutter-apk\app-debug.apk

# For a physical phone, replace the emulator host with the PC's LAN address.
flutter build apk --debug --dart-define=API_BASE_URL=http://192.168.1.20:3001/api/v1

# Production build after HTTPS API and signing are configured.
flutter build apk --release --dart-define=API_BASE_URL=https://api.example.com/api/v1
```

The currently generated debug APK targets the emulator host address; it will not reach the development PC from a physical phone without rebuilding with that PC's LAN address.

This creates an installable APK; use `flutter build appbundle --release` for a Play Store bundle after the production API domain and signing key are configured. Do not commit signing keys. The Android manifest still carries camera/microphone permissions for retained video source; that source is outside the first release flow and must not trigger a permission prompt from the text-first experience. Photo/voice support needs its own permission, upload, authorization, and playback verification before release.

The iOS project scaffold is present under `ios/`, but this environment is prioritizing Android. iOS build/signing and camera/media review require macOS and Xcode.

The Flutter app has Home/feed, profiles, messages, settings, and a text-first composer. Home presents one feed without a “Bảng tin” heading or For You/Following selector; signed-in retrieval remains personalized and Following stays available as a service capability for a later discovery surface. In dark mode, actions use charcoal gray with white text; light mode retains the blue brand palette. Images are downscaled on-device and again validated/re-encoded by the Dart API; voice uses mono 16 kHz PCM, capped at 60 seconds. Uploads are staged in private local storage, attached atomically with a post/reply, and fetched only through parent visibility checks. The current adapter is for local development only; object storage, rate limits, scheduled deletion cleanup, and full runtime/device verification remain open. Image/audio bytes do not contribute to text ranking. Dark charcoal mode is the default, with a local light-mode setting. Video source remains in the repository but is deferred from primary navigation and launch requirements.

## Migration status

The Flutter client previously resolved dependencies, passed analysis, and produced a Web release build and a universal Android debug APK. APK metadata confirmed package `app.ionic.mobile`, label `Ionic`, min SDK 24, target SDK 36, and arm64/armv7/x86_64 support. That earlier debug APK installed and launched on the `Ionic_Android_API35` Pixel 6 emulator. A narrow signed-in journey against local Dart API/PostgreSQL covered sign-in, session restore after app restart, a For You response, and text-post publish/readback. The current public guest feed, settings, profile editing, and dark/light appearance changes still need runtime review and a fresh build. Other Dart route parity, photo/voice support, and measured ranking quality remain open. Do not remove `apps/web` or `apps/api` until remaining route parity and signed-in journeys have been verified. iOS requires macOS/Xcode.

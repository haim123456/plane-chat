# צ'אט טיסה (Plane Chat)

Offline chat between an Android phone and an iPhone (or two phones) with no internet,
for example in flight. Hebrew RTL UI. Text, compressed photos, hold-to-record voice notes,
delivered ticks, local history, Android share target.

## How it works
- The Android phone hosts: native Kotlin creates a Wi-Fi Direct group with a fixed
  `DIRECT-xx-TisaChat` network name and passphrase (Android 10+), shown big on screen.
- The other phone joins that network from its Wi-Fi settings (works in airplane mode with Wi-Fi on).
- The app talks over TCP port 47474 to the group owner at `192.168.49.1`, with acks,
  resend after reconnect, heartbeat and auto-reconnect.

## Layout
- `lib/core/` pure Dart: wire protocol (length-prefixed JSON), link, store, controller.
- `lib/ui/` Flutter screens. `lib/platform/` method-channel bridge.
- `android/app/src/main/kotlin/` Wi-Fi Direct, share intake, keep-alive service.
- `test/` protocol unit tests and a two-instance TCP loopback test.

## Build
- `flutter test`
- `flutter build apk --release` (add your own `android/key.properties` for release signing).
- CI (`.github/workflows/build.yml`) builds an unsigned IPA on macOS and an APK on Linux.
  The IPA must be signed at install time (e.g. a sideloading tool with an Apple ID).

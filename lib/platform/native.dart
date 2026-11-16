// Thin wrappers over the Kotlin method channels. On iOS (later) the Wi-Fi
// Direct and keep-alive calls are simply unavailable: the iPhone is always the
// client and joins the network from Settings.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class GroupInfo {
  GroupInfo(this.ssid, this.passphrase, this.ownerIp, this.clients, this.frequency);
  final String ssid;
  final String passphrase;
  final String ownerIp;
  final int clients;
  final int? frequency;

  static GroupInfo? fromMap(Map? m) {
    if (m == null || m['ssid'] == null) return null;
    return GroupInfo(m['ssid'] as String, (m['passphrase'] as String?) ?? '',
        (m['ownerIp'] as String?) ?? '192.168.49.1', (m['clients'] as int?) ?? 0, m['frequency'] as int?);
  }
}

class WifiDirectError implements Exception {
  WifiDirectError(this.code, this.message);
  final String code;
  final String message;
}

class NativeBridge {
  static const _wifi = MethodChannel('plane_chat/wifi_direct');
  static const _sys = MethodChannel('plane_chat/system');
  static const _share = MethodChannel('plane_chat/share');

  static bool get canHost => Platform.isAndroid;

  /// Fixed SSID "DIRECT-xy-TisaChat" (Wi-Fi Direct requires the DIRECT-xy prefix).
  static String generateSsid() {
    const a = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return 'DIRECT-${a[r.nextInt(a.length)]}${a[r.nextInt(a.length)]}-TisaChat';
  }

  /// Easy to type on an iPhone: lowercase letters and digits, no look-alikes.
  static String generatePassphrase() {
    const a = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    return List.generate(10, (_) => a[r.nextInt(a.length)]).join();
  }

  static Future<int> sdkInt() async => (await _sys.invokeMethod<int>('sdkInt')) ?? 0;

  /// Returns null when everything needed is granted, else a Hebrew explanation.
  static Future<String?> ensureHostPermissions() async {
    final sdk = await sdkInt();
    if (sdk >= 33) {
      final s = await Permission.nearbyWifiDevices.request();
      if (!s.isGranted) return 'צריך לאשר את ההרשאה "מכשירים בקרבת מקום" כדי ליצור את הרשת.';
      await Permission.notification.request();
    } else {
      final s = await Permission.locationWhenInUse.request();
      if (!s.isGranted) return 'בגרסת האנדרואיד הזאת צריך לאשר הרשאת מיקום כדי ליצור רשת Wi-Fi Direct. האפליקציה לא משתמשת במיקום.';
    }
    final st = await status();
    if (st['p2pSupported'] == false) return 'הטלפון הזה לא תומך ב־Wi-Fi Direct.';
    if (st['wifiEnabled'] == false) return 'צריך להדליק Wi-Fi (גם במצב טיסה אפשר).';
    if (sdk < 33 && st['locationEnabled'] == false) {
      return 'בגרסת האנדרואיד הזאת צריך להדליק את שירותי המיקום בזמן יצירת הרשת.';
    }
    return null;
  }

  static Future<Map> status() async =>
      (await _wifi.invokeMethod<Map>('status')) ?? {};

  static Future<GroupInfo> startGroup(String ssid, String pass) async {
    try {
      final m = await _wifi.invokeMethod<Map>('startGroup', {'ssid': ssid, 'passphrase': pass, 'band2g': true});
      final g = GroupInfo.fromMap(m);
      if (g == null) throw WifiDirectError('NO_GROUP', 'no group info');
      return g;
    } on PlatformException catch (e) {
      throw WifiDirectError(e.code, e.message ?? '');
    }
  }

  static Future<void> stopGroup() => _wifi.invokeMethod('stopGroup');
  static Future<GroupInfo?> groupInfo() async =>
      GroupInfo.fromMap(await _wifi.invokeMethod<Map>('groupInfo'));
  static Future<void> openWifiSettings() => _wifi.invokeMethod('openWifiSettings');
  static Future<void> openLocationSettings() => _wifi.invokeMethod('openLocationSettings');

  static Future<void> startKeepAlive() async {
    if (Platform.isAndroid) await _sys.invokeMethod('startKeepAlive');
  }

  static Future<void> stopKeepAlive() async {
    if (Platform.isAndroid) await _sys.invokeMethod('stopKeepAlive');
  }

  static Future<void> notify(String title, String body) async {
    if (Platform.isAndroid) await _sys.invokeMethod('notify', {'title': title, 'body': body});
  }

  // Share target
  static final _shares = StreamController<SharedPayload>.broadcast();
  static Stream<SharedPayload> get shares => _shares.stream;

  static void initShare() {
    if (!Platform.isAndroid) return;
    _share.setMethodCallHandler((call) async {
      if (call.method == 'onShare') {
        final p = SharedPayload.fromMap(call.arguments as Map?);
        if (p != null) _shares.add(p);
      }
    });
  }

  static Future<SharedPayload?> takeInitialShare() async {
    if (!Platform.isAndroid) return null;
    return SharedPayload.fromMap(await _share.invokeMethod<Map>('takeInitialShare'));
  }
}

class SharedPayload {
  SharedPayload(this.text, this.imagePaths);
  final String? text;
  final List<String> imagePaths;
  static SharedPayload? fromMap(Map? m) {
    if (m == null) return null;
    final imgs = ((m['images'] as List?) ?? []).cast<String>();
    final t = m['text'] as String?;
    if ((t == null || t.trim().isEmpty) && imgs.isEmpty) return null;
    return SharedPayload(t, imgs);
  }
}

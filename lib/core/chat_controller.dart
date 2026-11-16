// Glue between the link, the store and the UI. No platform plugins here,
// so it runs in plain `flutter test`.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'link.dart';
import 'protocol.dart';
import 'store.dart';

String newMessageId() {
  final r = Random.secure();
  final rand = List.generate(6, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$rand';
}

class ChatController extends ChangeNotifier {
  ChatController(this.store);

  final ChatStore store;
  final List<ChatMessage> messages = [];
  final Map<String, ChatMessage> _byId = {};
  ChatLink? link;
  LinkState linkState = LinkState.stopped;
  String? peerName;
  Map<String, dynamic> settings = {};
  final List<StreamSubscription> _subs = [];

  String get deviceId => settings['deviceId'] as String;
  String get deviceName => (settings['name'] as String?) ?? 'טלפון';

  Future<void> init() async {
    settings = await store.loadSettings();
    if (settings['deviceId'] == null) {
      settings['deviceId'] = newMessageId();
      await store.saveSettings(settings);
    }
    messages
      ..clear()
      ..addAll(await store.load());
    _byId
      ..clear()
      ..addEntries(messages.map((m) => MapEntry(m.id, m)));
    notifyListeners();
  }

  Future<void> updateSettings(Map<String, dynamic> patch) async {
    settings.addAll(patch);
    await store.saveSettings(settings);
    notifyListeners();
  }

  Future<void> startLink({
    required LinkRole role,
    String host = kDefaultHostIp,
    int port = kDefaultPort,
    InternetAddress? bindAddress,
  }) async {
    await stopLink();
    final l = ChatLink(
      role: role,
      host: host,
      port: port,
      bindAddress: bindAddress,
      deviceName: deviceName,
      deviceId: deviceId,
    );
    link = l;
    _subs.add(l.states.listen((s) {
      linkState = s;
      if (s == LinkState.connected) _markQueuedAsSent();
      notifyListeners();
    }));
    _subs.add(l.peerNames.listen((n) {
      peerName = n;
      notifyListeners();
    }));
    _subs.add(l.acks.listen(_onAck));
    _subs.add(l.messages.listen(_onIncoming));
    // Re-queue our messages that were never confirmed (app restarted mid-flight).
    for (final m in messages.where((m) => m.fromMe && m.status != MsgStatus.delivered)) {
      final f = await _frameFor(m);
      if (f != null) l.send(f);
    }
    await l.start();
    linkState = l.state;
    notifyListeners();
  }

  Future<void> stopLink() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await link?.dispose();
    link = null;
    linkState = LinkState.stopped;
    await store.flush();
  }

  void _markQueuedAsSent() {
    var changed = false;
    for (final m in messages) {
      if (m.fromMe && m.status == MsgStatus.pending) {
        m.status = MsgStatus.sent;
        changed = true;
      }
    }
    if (changed) store.save(messages);
  }

  Future<Map<String, dynamic>?> _frameFor(ChatMessage m) async {
    List<int>? data;
    if (m.mediaPath != null) {
      final f = File(m.mediaPath!);
      if (!await f.exists()) return null;
      data = await f.readAsBytes();
    }
    return msgFrame(
      id: m.id,
      kind: m.kind,
      ts: m.ts,
      text: m.text,
      data: data,
      durationMs: m.durationMs,
      sender: deviceName,
    );
  }

  Future<ChatMessage> _sendNew(ChatMessage m) async {
    messages.add(m);
    _byId[m.id] = m;
    notifyListeners();
    final f = await _frameFor(m);
    if (f != null && link != null && link!.send(f)) {
      m.status = MsgStatus.sent;
    }
    await store.save(messages);
    notifyListeners();
    return m;
  }

  Future<ChatMessage?> sendText(String text) async {
    final t = text.trim();
    if (t.isEmpty) return null;
    return _sendNew(ChatMessage(
        id: newMessageId(),
        kind: MsgKind.text,
        fromMe: true,
        ts: DateTime.now().millisecondsSinceEpoch,
        text: t));
  }

  Future<ChatMessage> sendImage(List<int> jpegBytes, {String? caption}) async {
    final id = newMessageId();
    final path = await store.writeMedia(id, 'jpg', jpegBytes);
    return _sendNew(ChatMessage(
        id: id,
        kind: MsgKind.image,
        fromMe: true,
        ts: DateTime.now().millisecondsSinceEpoch,
        text: (caption?.trim().isEmpty ?? true) ? null : caption!.trim(),
        mediaPath: path));
  }

  Future<ChatMessage> sendVoice(List<int> m4aBytes, int durationMs) async {
    final id = newMessageId();
    final path = await store.writeMedia(id, 'm4a', m4aBytes);
    return _sendNew(ChatMessage(
        id: id,
        kind: MsgKind.voice,
        fromMe: true,
        ts: DateTime.now().millisecondsSinceEpoch,
        mediaPath: path,
        durationMs: durationMs));
  }

  void _onAck(String id) {
    final m = _byId[id];
    if (m == null) return;
    m.status = MsgStatus.delivered;
    store.save(messages);
    notifyListeners();
  }

  Future<void> _onIncoming(Map<String, dynamic> f) async {
    final id = f['id'] as String;
    if (_byId.containsKey(id)) return; // duplicate after a resend
    final kind = parseKind(f['kind'] as String?);
    String? path;
    final data = frameData(f);
    if (data != null) {
      path = await store.writeMedia(id, kind == MsgKind.voice ? 'm4a' : 'jpg', data);
    }
    if (_byId.containsKey(id)) return;
    final m = ChatMessage(
      id: id,
      kind: kind,
      fromMe: false,
      ts: (f['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      text: f['text'] as String?,
      mediaPath: path,
      durationMs: (f['dur'] as num?)?.toInt(),
      status: MsgStatus.received,
    );
    messages.add(m);
    messages.sort((a, b) => a.ts.compareTo(b.ts));
    _byId[id] = m;
    await store.save(messages);
    onIncoming?.call(m);
    notifyListeners();
  }

  /// UI hook (vibrate / sound on new message).
  void Function(ChatMessage)? onIncoming;

  Future<void> clearHistory() async {
    messages.clear();
    _byId.clear();
    await store.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    stopLink();
    super.dispose();
  }
}

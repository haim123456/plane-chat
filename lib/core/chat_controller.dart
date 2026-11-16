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

/// Snapshot of this phone's battery, supplied by the UI layer (battery_plus).
class DeviceStatus {
  const DeviceStatus({this.battery, this.charging});
  final int? battery;
  final bool? charging;
}

class ChatController extends ChangeNotifier {
  ChatController(this.store, {this.typingTimeout = const Duration(seconds: 6)});

  final ChatStore store;
  final Duration typingTimeout;
  final List<ChatMessage> messages = [];
  final Map<String, ChatMessage> _byId = {};
  final Set<String> _deleted = {};
  final Set<String> _seenEvents = {};
  ChatLink? link;
  LinkState linkState = LinkState.stopped;
  String? peerName;
  Map<String, dynamic> settings = {};
  final List<StreamSubscription> _subs = [];

  // Peer presence
  bool peerTyping = false;
  Timer? _peerTypingTimer;
  int? peerBattery;
  bool? peerCharging;
  String? peerSeat;
  int? peerLastSeen; // ms since epoch, persisted

  // Our typing state (throttled)
  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);
  bool _typingOn = false;

  Timer? _statusTimer;
  DateTime _lastStatusSent = DateTime.fromMillisecondsSinceEpoch(0);

  /// Battery saver: no typing indicator, status at most every 5 minutes.
  /// Set by the UI when this phone's battery is low and not charging.
  bool lowPower = false;

  /// Supplies our battery for the status frame (null in tests).
  Future<DeviceStatus> Function()? statusProvider;

  /// UI hooks.
  void Function(ChatMessage)? onIncoming;
  void Function()? onNudge;
  void Function(ChatMessage target, String emoji)? onReaction;

  String get deviceId => settings['deviceId'] as String;
  String get deviceName => (settings['name'] as String?) ?? 'טלפון';
  String? get mySeat => settings['seat'] as String?;
  int get pendingCount =>
      messages.where((m) => m.fromMe && m.status == MsgStatus.pending).length;

  Future<void> init() async {
    settings = await store.loadSettings();
    if (settings['deviceId'] == null) {
      settings['deviceId'] = newMessageId();
      await store.saveSettings(settings);
    }
    _deleted
      ..clear()
      ..addAll(((settings['deleted'] as List?) ?? const []).cast<String>());
    peerName = settings['peerName'] as String?;
    peerLastSeen = (settings['peerLastSeen'] as num?)?.toInt();
    peerSeat = settings['peerSeat'] as String?;
    messages
      ..clear()
      ..addAll((await store.load()).where((m) => !_deleted.contains(m.id)));
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
      final was = linkState;
      linkState = s;
      if (s == LinkState.connected) {
        _markQueuedAsSent();
        sendStatus(force: true);
      } else if (was == LinkState.connected) {
        _setPeerTyping(false);
        _touchLastSeen();
      }
      notifyListeners();
    }));
    _subs.add(l.peerNames.listen((n) {
      peerName = n;
      if (settings['peerName'] != n) updateSettings({'peerName': n});
      notifyListeners();
    }));
    _subs.add(l.acks.listen(_onAck));
    _subs.add(l.messages.listen((f) {
      if (f['t'] == 'evt') {
        _onEvent(f);
      } else {
        _onIncoming(f);
      }
    }));
    _subs.add(l.others.listen(_onEphemeral));
    // Re-queue our messages that were never confirmed (app restarted mid-flight).
    for (final m in messages.where((m) => m.fromMe && m.status != MsgStatus.delivered)) {
      final f = await _frameFor(m);
      if (f != null) l.send(f);
    }
    await l.start();
    linkState = l.state;
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 60), (_) => sendStatus());
    notifyListeners();
  }

  Future<void> stopLink() async {
    _statusTimer?.cancel();
    _statusTimer = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await link?.dispose();
    link = null;
    linkState = LinkState.stopped;
    _setPeerTyping(false);
    await store.flush();
  }

  void _touchLastSeen() {
    peerLastSeen = DateTime.now().millisecondsSinceEpoch;
    settings['peerLastSeen'] = peerLastSeen;
    store.saveSettings(settings);
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
      replyTo: m.replyTo,
      replyPreview: m.replyPreview,
      replyKind: m.replyKind,
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

  ChatMessage _mk(MsgKind kind,
          {String? text, String? path, int? dur, ChatMessage? replyTo, String? id}) =>
      ChatMessage(
        id: id ?? newMessageId(),
        kind: kind,
        fromMe: true,
        ts: DateTime.now().millisecondsSinceEpoch,
        text: text,
        mediaPath: path,
        durationMs: dur,
        replyTo: replyTo?.id,
        replyPreview: replyTo == null ? null : _clip(replyTo.preview, 120),
        replyKind: replyTo?.kind.name,
      );

  static String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  Future<ChatMessage?> sendText(String text, {ChatMessage? replyTo}) async {
    final t = text.trim();
    if (t.isEmpty) return null;
    setTyping(false);
    return _sendNew(_mk(MsgKind.text, text: t, replyTo: replyTo));
  }

  Future<ChatMessage> sendImage(List<int> jpegBytes, {String? caption, ChatMessage? replyTo}) async {
    final id = newMessageId();
    final path = await store.writeMedia(id, 'jpg', jpegBytes);
    final cap = (caption?.trim().isEmpty ?? true) ? null : caption!.trim();
    return _sendNew(_mk(MsgKind.image, text: cap, path: path, replyTo: replyTo, id: id));
  }

  Future<ChatMessage> sendVoice(List<int> m4aBytes, int durationMs, {ChatMessage? replyTo}) async {
    final id = newMessageId();
    final path = await store.writeMedia(id, 'm4a', m4aBytes);
    return _sendNew(_mk(MsgKind.voice, path: path, dur: durationMs, replyTo: replyTo, id: id));
  }

  // ---------- reactions, nudge, delete ----------

  /// Set or clear (emoji == null) my reaction on a message, and tell the peer.
  Future<void> react(ChatMessage m, String? emoji) async {
    m.myReaction = (emoji == null || emoji.isEmpty || m.myReaction == emoji) ? null : emoji;
    link?.send(evtFrame(id: newMessageId(), ev: 'react', target: m.id, emoji: m.myReaction ?? ''));
    await store.save(messages);
    notifyListeners();
  }

  DateTime _lastNudge = DateTime.fromMillisecondsSinceEpoch(0);

  /// Buzz the other phone. Rate-limited to one per 5 s. Returns false if skipped.
  bool nudge() {
    if (DateTime.now().difference(_lastNudge) < const Duration(seconds: 5)) return false;
    _lastNudge = DateTime.now();
    link?.send(evtFrame(id: newMessageId(), ev: 'nudge', ts: DateTime.now().millisecondsSinceEpoch));
    return true;
  }

  /// Removes a message from this phone only. Media file is deleted too.
  Future<void> deleteForMe(ChatMessage m) async {
    messages.remove(m);
    _byId.remove(m.id);
    _deleted.add(m.id);
    final list = _deleted.toList();
    settings['deleted'] = list.length > 3000 ? list.sublist(list.length - 3000) : list;
    await store.saveSettings(settings);
    if (m.mediaPath != null) {
      final f = File(m.mediaPath!);
      if (await f.exists()) await f.delete();
    }
    await store.save(messages);
    notifyListeners();
  }

  ChatMessage? byId(String? id) => id == null ? null : _byId[id];

  // ---------- typing & status ----------

  /// Call on every text change. Sends at most one 'typing on' per 3 s.
  void setTyping(bool on) {
    final l = link;
    if (l == null) return;
    if (on && lowPower) return;
    if (on) {
      if (!_typingOn || DateTime.now().difference(_lastTypingSent) > const Duration(seconds: 3)) {
        _typingOn = true;
        _lastTypingSent = DateTime.now();
        l.sendEphemeral(typingFrame(true));
      }
    } else if (_typingOn) {
      _typingOn = false;
      l.sendEphemeral(typingFrame(false));
    }
  }

  Future<void> sendStatus({bool force = false}) async {
    final l = link;
    if (l == null || l.state != LinkState.connected) return;
    if (lowPower && !force && DateTime.now().difference(_lastStatusSent) < const Duration(minutes: 5)) return;
    _lastStatusSent = DateTime.now();
    DeviceStatus st = const DeviceStatus();
    try {
      if (statusProvider != null) st = await statusProvider!();
    } catch (_) {}
    l.sendEphemeral(statusFrame(battery: st.battery, charging: st.charging, seat: mySeat ?? ''));
  }

  Future<void> setSeat(String? seat) async {
    final s = seat?.trim().toUpperCase();
    await updateSettings({'seat': (s == null || s.isEmpty) ? null : s});
    await sendStatus(force: true);
  }

  void _setPeerTyping(bool on) {
    _peerTypingTimer?.cancel();
    if (peerTyping != on) {
      peerTyping = on;
      notifyListeners();
    }
    if (on) {
      _peerTypingTimer = Timer(typingTimeout, () => _setPeerTyping(false));
    }
  }

  void _onEphemeral(Map<String, dynamic> f) {
    switch (f['t']) {
      case 'typing':
        _setPeerTyping(f['on'] == true);
        break;
      case 'status':
        peerBattery = (f['battery'] as num?)?.toInt();
        peerCharging = f['charging'] as bool?;
        final seat = f['seat'] as String?;
        peerSeat = (seat == null || seat.isEmpty) ? null : seat;
        if (settings['peerSeat'] != peerSeat) {
          settings['peerSeat'] = peerSeat;
          store.saveSettings(settings);
        }
        notifyListeners();
        break;
    }
  }

  void _onEvent(Map<String, dynamic> f) {
    final id = f['id'] as String;
    if (!_seenEvents.add(id)) return;
    switch (f['ev']) {
      case 'react':
        final m = _byId[f['target']];
        if (m == null) return;
        final e = f['emoji'] as String?;
        m.peerReaction = (e == null || e.isEmpty) ? null : e;
        store.save(messages);
        if (m.peerReaction != null) onReaction?.call(m, m.peerReaction!);
        notifyListeners();
        break;
      case 'nudge':
        final ts = (f['ts'] as num?)?.toInt();
        // Ignore stale nudges delivered long after a reconnect.
        if (ts == null || DateTime.now().millisecondsSinceEpoch - ts < 120000) onNudge?.call();
        break;
    }
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
    if (_byId.containsKey(id) || _deleted.contains(id)) return; // duplicate after a resend
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
      replyTo: f['reply'] as String?,
      replyPreview: f['replyText'] as String?,
      replyKind: f['replyKind'] as String?,
    );
    _setPeerTyping(false);
    messages.add(m);
    messages.sort((a, b) => a.ts.compareTo(b.ts));
    _byId[id] = m;
    await store.save(messages);
    onIncoming?.call(m);
    notifyListeners();
  }

  // ---------- search & export ----------

  List<ChatMessage> search(String q) {
    final s = q.trim().toLowerCase();
    if (s.isEmpty) return const [];
    return messages.where((m) => (m.text ?? '').toLowerCase().contains(s)).toList();
  }

  /// Plain-text transcript (UTF-8, RTL-friendly) for sharing.
  String exportText() {
    final me = deviceName;
    final other = peerName ?? 'הצד השני';
    final b = StringBuffer("צ'אט טיסה\n");
    String? day;
    for (final m in messages) {
      final d = DateTime.fromMillisecondsSinceEpoch(m.ts);
      final dd = '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
      if (dd != day) {
        b.writeln('\n— $dd —');
        day = dd;
      }
      final t = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
      final quote = m.replyPreview == null ? '' : ' [בתגובה ל: ${m.replyPreview}]';
      b.writeln('$t ${m.fromMe ? me : other}: ${m.preview}$quote');
    }
    return b.toString();
  }

  Future<void> clearHistory() async {
    messages.clear();
    _byId.clear();
    await store.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _peerTypingTimer?.cancel();
    stopLink();
    super.dispose();
  }
}

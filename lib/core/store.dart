// Local history: a JSON file plus a media folder in the app documents dir.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';

enum MsgStatus { pending, sent, delivered, received }

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.kind,
    required this.fromMe,
    required this.ts,
    this.text,
    this.mediaPath,
    this.durationMs,
    this.status = MsgStatus.pending,
    this.replyTo,
    this.replyPreview,
    this.replyKind,
    this.myReaction,
    this.peerReaction,
  });

  final String id;
  final MsgKind kind;
  final bool fromMe;
  final int ts;
  final String? text;
  final String? mediaPath;
  final int? durationMs;
  MsgStatus status;
  final String? replyTo;
  final String? replyPreview;
  final String? replyKind;
  String? myReaction;
  String? peerReaction;

  /// Short one-line description used for quotes, notifications and export.
  String get preview => switch (kind) {
        MsgKind.text => text ?? '',
        MsgKind.image => text == null ? '📷 תמונה' : '📷 $text',
        MsgKind.voice => '🎤 הודעה קולית',
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'me': fromMe,
        'ts': ts,
        if (text != null) 'text': text,
        if (mediaPath != null) 'media': mediaPath,
        if (durationMs != null) 'dur': durationMs,
        'st': status.name,
        if (replyTo != null) 'reply': replyTo,
        if (replyPreview != null) 'replyText': replyPreview,
        if (replyKind != null) 'replyKind': replyKind,
        if (myReaction != null) 'myR': myReaction,
        if (peerReaction != null) 'peerR': peerReaction,
      };

  static ChatMessage fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        kind: parseKind(j['kind'] as String?),
        fromMe: j['me'] == true,
        ts: (j['ts'] as num).toInt(),
        text: j['text'] as String?,
        mediaPath: j['media'] as String?,
        durationMs: (j['dur'] as num?)?.toInt(),
        status: MsgStatus.values.firstWhere((s) => s.name == j['st'],
            orElse: () => MsgStatus.pending),
        replyTo: j['reply'] as String?,
        replyPreview: j['replyText'] as String?,
        replyKind: j['replyKind'] as String?,
        myReaction: j['myR'] as String?,
        peerReaction: j['peerR'] as String?,
      );
}

class ChatStore {
  ChatStore(this.dir);
  final Directory dir;

  File get _file => File('${dir.path}/history.json');
  File get _settingsFile => File('${dir.path}/settings.json');
  Directory get mediaDir => Directory('${dir.path}/media');

  Future<void> _chain = Future.value();

  Future<List<ChatMessage>> load() async {
    await mediaDir.create(recursive: true);
    if (!await _file.exists()) return [];
    try {
      final list = jsonDecode(await _file.readAsString()) as List;
      return list
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Atomic write (temp file + rename), serialized.
  Future<void> save(List<ChatMessage> msgs) {
    final data = jsonEncode(msgs.map((m) => m.toJson()).toList());
    _chain = _chain.then((_) async {
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(data, flush: true);
      await tmp.rename(_file.path);
    }).catchError((Object e) {
      // Keep the chain alive; the next save rewrites the full history.
    });
    return _chain;
  }

  /// Wait for queued writes.
  Future<void> flush() => _chain;

  Future<String> writeMedia(String id, String ext, List<int> bytes) async {
    await mediaDir.create(recursive: true);
    final f = File('${mediaDir.path}/$id.$ext');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  Future<Map<String, dynamic>> loadSettings() async {
    try {
      if (await _settingsFile.exists()) {
        return jsonDecode(await _settingsFile.readAsString())
            as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  /// Serialized with history writes; errors are swallowed so a failed write
  /// never blocks later ones.
  Future<void> saveSettings(Map<String, dynamic> s) {
    final data = jsonEncode(s);
    _chain = _chain.then((_) async {
      await dir.create(recursive: true);
      final tmp = File('${_settingsFile.path}.tmp');
      await tmp.writeAsString(data, flush: true);
      await tmp.rename(_settingsFile.path);
    }).catchError((Object e) {});
    return _chain;
  }

  Future<void> clear() async {
    if (await _file.exists()) await _file.delete();
    if (await mediaDir.exists()) await mediaDir.delete(recursive: true);
    await mediaDir.create(recursive: true);
  }
}

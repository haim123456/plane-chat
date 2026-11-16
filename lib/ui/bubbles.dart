import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:material_ui/material_ui.dart';

import '../core/protocol.dart';
import '../core/store.dart';
import 'theme.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.m});
  final ChatMessage m;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mine = m.fromMe;
    final bg = mine ? cs.primary : cs.surface;
    final fg = mine ? cs.onPrimary : cs.onSurface;
    const r = Radius.circular(20);
    // In RTL, "start" is the right side: my messages sit on the right.
    final radius = BorderRadiusDirectional.only(
      topStart: r, topEnd: r,
      bottomStart: mine ? const Radius.circular(6) : r,
      bottomEnd: mine ? r : const Radius.circular(6),
    );
    Widget content;
    switch (m.kind) {
      case MsgKind.image:
        content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          _ImageThumb(path: m.mediaPath),
          if (m.text != null)
            Padding(padding: const EdgeInsets.fromLTRB(10, 8, 10, 0), child: Text(m.text!, style: TextStyle(color: fg, fontSize: 16))),
        ]);
        break;
      case MsgKind.voice:
        content = VoiceBubbleBody(m: m, fg: fg);
        break;
      case MsgKind.text:
        content = Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
          child: SelectableText(m.text ?? '', style: TextStyle(color: fg, fontSize: 16.5, height: 1.35)),
        );
    }
    return Align(
      alignment: mine ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          padding: EdgeInsets.all(m.kind == MsgKind.image ? 4 : 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: radius,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4, offset: const Offset(0, 1))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
            content,
            Padding(
              padding: EdgeInsets.fromLTRB(6, 4, 6, m.kind == MsgKind.image ? 4 : 0),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(hhmm(m.ts), style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12)),
                if (mine) ...[const SizedBox(width: 4), StatusTick(status: m.status, color: fg)],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class StatusTick extends StatelessWidget {
  const StatusTick({super.key, required this.status, required this.color});
  final MsgStatus status;
  final Color color;
  @override
  Widget build(BuildContext context) {
    switch (status) {
      case MsgStatus.pending:
        return Icon(Icons.schedule_rounded, size: 15, color: color.withValues(alpha: 0.7), semanticLabel: 'ממתין');
      case MsgStatus.sent:
        return Icon(Icons.done_rounded, size: 16, color: color.withValues(alpha: 0.8), semanticLabel: 'נשלח');
      case MsgStatus.delivered:
        return const Icon(Icons.done_all_rounded, size: 16, color: Color(0xFF8BE0FF), semanticLabel: 'נמסר');
      case MsgStatus.received:
        return const SizedBox.shrink();
    }
  }
}

class _ImageThumb extends StatelessWidget {
  const _ImageThumb({required this.path});
  final String? path;
  @override
  Widget build(BuildContext context) {
    if (path == null || !File(path!).existsSync()) {
      return const SizedBox(height: 120, child: Center(child: Icon(Icons.broken_image_outlined)));
    }
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _FullImage(path: path!))),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.file(File(path!), cacheWidth: 720, fit: BoxFit.cover),
      ),
    );
  }
}

class _FullImage extends StatelessWidget {
  const _FullImage({required this.path});
  final String path;
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: Center(child: InteractiveViewer(maxScale: 5, child: Image.file(File(path)))),
      );
}

/// One shared player for all voice notes.
class VoicePlayback {
  static final AudioPlayer player = AudioPlayer();
  static final ValueNotifier<String?> playing = ValueNotifier(null);
  static final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  static bool _wired = false;

  static void _wire() {
    if (_wired) return;
    _wired = true;
    player.onPositionChanged.listen((p) => position.value = p);
    player.onPlayerComplete.listen((_) {
      playing.value = null;
      position.value = Duration.zero;
    });
  }

  static Future<void> toggle(ChatMessage m) async {
    _wire();
    if (playing.value == m.id) {
      await player.stop();
      playing.value = null;
      position.value = Duration.zero;
      return;
    }
    await player.stop();
    position.value = Duration.zero;
    playing.value = m.id;
    await player.play(DeviceFileSource(m.mediaPath!));
  }
}

class VoiceBubbleBody extends StatelessWidget {
  const VoiceBubbleBody({super.key, required this.m, required this.fg});
  final ChatMessage m;
  final Color fg;
  @override
  Widget build(BuildContext context) {
    final total = m.durationMs ?? 0;
    return ValueListenableBuilder<String?>(
      valueListenable: VoicePlayback.playing,
      builder: (context, playingId, _) {
        final isMe = playingId == m.id;
        return SizedBox(
          width: 220,
          child: Row(children: [
            IconButton(
              onPressed: m.mediaPath == null ? null : () => VoicePlayback.toggle(m),
              icon: Icon(isMe ? Icons.stop_rounded : Icons.play_arrow_rounded, color: fg, size: 32),
            ),
            Expanded(
              child: ValueListenableBuilder<Duration>(
                valueListenable: VoicePlayback.position,
                builder: (context, pos, _) {
                  final v = (isMe && total > 0) ? (pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: LinearProgressIndicator(
                        value: v,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(4),
                        color: fg,
                        backgroundColor: fg.withValues(alpha: 0.25),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(isMe ? mmss(pos.inMilliseconds) : mmss(total),
                        style: TextStyle(color: fg.withValues(alpha: 0.85), fontSize: 13)),
                  ]);
                },
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.mic_rounded, color: fg.withValues(alpha: 0.7), size: 18),
          ]),
        );
      },
    );
  }
}

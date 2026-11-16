import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/protocol.dart';
import '../core/store.dart';
import 'theme.dart';

/// One chat row: swipe to reply, long-press for actions, reactions chip,
/// grouped corners, entrance animation for new messages.
class MessageRow extends StatefulWidget {
  const MessageRow({
    super.key,
    required this.m,
    required this.groupedWithPrev,
    required this.groupedWithNext,
    required this.animateIn,
    required this.onReply,
    required this.onLongPress,
    this.highlight,
  });
  final ChatMessage m;
  final bool groupedWithPrev; // previous (older) message is same sender
  final bool groupedWithNext;
  final bool animateIn;
  final VoidCallback onReply;
  final VoidCallback onLongPress;
  final String? highlight;

  @override
  State<MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<MessageRow> with SingleTickerProviderStateMixin {
  double _drag = 0;
  bool _fired = false;
  late final AnimationController _in = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 280), value: widget.animateIn ? 0 : 1);

  @override
  void initState() {
    super.initState();
    if (widget.animateIn) _in.forward();
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // Swipe toward the screen centre to reply (like WhatsApp).
    final onRight = m.fromMe == rtl; // my bubbles sit at "start" (right in RTL)
    final sign = onRight ? -1.0 : 1.0;
    final curved = CurvedAnimation(parent: _in, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(curved),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (d) {
            final v = (_drag + d.delta.dx * sign).clamp(0.0, 90.0);
            setState(() => _drag = v);
            if (_drag > 60 && !_fired) {
              _fired = true;
              HapticFeedback.selectionClick();
            }
          },
          onHorizontalDragEnd: (_) {
            if (_fired) widget.onReply();
            setState(() {
              _drag = 0;
              _fired = false;
            });
          },
          onLongPress: () {
            HapticFeedback.mediumImpact();
            widget.onLongPress();
          },
          child: Stack(alignment: Alignment.center, children: [
            if (_drag > 4)
              Positioned(
                right: onRight ? 8 : null,
                left: onRight ? null : 8,
                child: Opacity(
                  opacity: (_drag / 60).clamp(0, 1),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                    child: Icon(Icons.reply_rounded, size: 18, color: Theme.of(context).colorScheme.onPrimaryContainer),
                  ),
                ),
              ),
            AnimatedContainer(
              duration: _drag == 0 ? const Duration(milliseconds: 180) : Duration.zero,
              transform: Matrix4.translationValues(_drag * sign, 0, 0),
              child: MessageBubble(
                m: m,
                groupedWithPrev: widget.groupedWithPrev,
                groupedWithNext: widget.groupedWithNext,
                highlight: widget.highlight,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.m, this.groupedWithPrev = false, this.groupedWithNext = false, this.highlight});
  final ChatMessage m;
  final bool groupedWithPrev;
  final bool groupedWithNext;
  final String? highlight;

  @override
  Widget build(BuildContext context) {
    final p = ChatPalette(context);
    final mine = m.fromMe;
    final fg = mine ? p.onMine : p.onTheirs;
    const big = Radius.circular(22);
    const small = Radius.circular(6);
    // RTL: "start" is the right edge, where my messages sit.
    final radius = BorderRadiusDirectional.only(
      topStart: mine && groupedWithPrev ? small : big,
      bottomStart: mine && groupedWithNext ? small : (mine ? const Radius.circular(8) : big),
      topEnd: !mine && groupedWithPrev ? small : big,
      bottomEnd: !mine && groupedWithNext ? small : (!mine ? const Radius.circular(8) : big),
    );
    final isImage = m.kind == MsgKind.image;
    final hasReactions = m.myReaction != null || m.peerReaction != null;

    Widget content;
    switch (m.kind) {
      case MsgKind.image:
        content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          _ImageThumb(path: m.mediaPath),
          if (m.text != null)
            Padding(padding: const EdgeInsets.fromLTRB(10, 8, 10, 0), child: _text(m.text!, fg)),
        ]);
        break;
      case MsgKind.voice:
        content = VoiceBubbleBody(m: m, fg: fg);
        break;
      case MsgKind.text:
        final onlyEmoji = _isOnlyEmoji(m.text ?? '');
        content = Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
          child: onlyEmoji
              ? Text(m.text!, style: const TextStyle(fontSize: 40, height: 1.1))
              : _text(m.text ?? '', fg),
        );
    }

    final bubble = Container(
      margin: EdgeInsetsDirectional.only(
        start: mine ? 10 : 56,
        end: mine ? 56 : 10,
        top: groupedWithPrev ? 1.5 : 7,
        bottom: hasReactions ? 14 : 1.5,
      ),
      padding: EdgeInsets.all(isImage ? 4 : 9),
      decoration: BoxDecoration(
        gradient: mine ? LinearGradient(colors: p.mine, begin: AlignmentDirectional.topStart, end: AlignmentDirectional.bottomEnd) : null,
        color: mine ? null : p.theirs,
        borderRadius: radius,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: p.dark ? 0.25 : 0.07), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        if (m.replyPreview != null) _QuoteBlock(text: m.replyPreview!, kind: m.replyKind, fg: fg, mine: mine),
        content,
        Padding(
          padding: EdgeInsets.fromLTRB(6, 3, 6, isImage ? 4 : 0),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(hhmm(m.ts), style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 11.5)),
            if (mine) ...[const SizedBox(width: 4), StatusTick(status: m.status, color: fg, delivered: p.delivered)],
          ]),
        ),
      ]),
    );

    return Align(
      alignment: mine ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.86),
        child: Stack(clipBehavior: Clip.none, children: [
          bubble,
          if (hasReactions)
            PositionedDirectional(
              bottom: 0,
              start: mine ? 22 : null,
              end: mine ? null : 22,
              child: _ReactionChip(mine: m.myReaction, theirs: m.peerReaction),
            ),
        ]),
      ),
    );
  }

  Widget _text(String t, Color fg) {
    final style = TextStyle(color: fg, fontSize: 16.5, height: 1.35);
    final h = highlight?.trim();
    if (h == null || h.isEmpty) return Text(t, style: style);
    final spans = <TextSpan>[];
    final lower = t.toLowerCase(), q = h.toLowerCase();
    var i = 0;
    while (true) {
      final j = lower.indexOf(q, i);
      if (j < 0) {
        spans.add(TextSpan(text: t.substring(i)));
        break;
      }
      spans.add(TextSpan(text: t.substring(i, j)));
      spans.add(TextSpan(text: t.substring(j, j + q.length),
          style: const TextStyle(backgroundColor: Color(0x99FDE047), color: Colors.black)));
      i = j + q.length;
    }
    return Text.rich(TextSpan(style: style, children: spans));
  }

  static bool _isOnlyEmoji(String s) {
    final t = s.trim();
    if (t.isEmpty || t.runes.length > 8) return false;
    return !RegExp(r'[A-Za-z0-9\u0590-\u05FF]').hasMatch(t) && t.runes.any((r) => r > 0x2000);
  }
}

class _QuoteBlock extends StatelessWidget {
  const _QuoteBlock({required this.text, required this.kind, required this.fg, required this.mine});
  final String text;
  final String? kind;
  final Color fg;
  final bool mine;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minWidth: 120),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: mine ? Colors.white.withValues(alpha: 0.18) : cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: BorderDirectional(start: BorderSide(color: mine ? Colors.white : cs.primary, width: 3)),
      ),
      child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: TextStyle(color: fg.withValues(alpha: 0.85), fontSize: 13.5)),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({this.mine, this.theirs});
  final String? mine;
  final String? theirs;
  @override
  Widget build(BuildContext context) {
    final p = ChatPalette(context);
    final items = <String>[if (theirs != null) theirs!, if (mine != null && mine != theirs) mine!];
    final count = (mine != null ? 1 : 0) + (theirs != null ? 1 : 0);
    return TweenAnimationBuilder<double>(
      key: ValueKey('$mine|$theirs'),
      tween: Tween(begin: 0.4, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.elasticOut,
      builder: (_, s, child) => Transform.scale(scale: s, child: child),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: p.theirs,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 4)],
        ),
        child: Text('${items.join()}${count == 2 && items.length == 1 ? ' 2' : ''}', style: const TextStyle(fontSize: 14)),
      ),
    );
  }
}

class StatusTick extends StatelessWidget {
  const StatusTick({super.key, required this.status, required this.color, required this.delivered});
  final MsgStatus status;
  final Color color;
  final Color delivered;
  @override
  Widget build(BuildContext context) {
    final Widget icon = switch (status) {
      MsgStatus.pending => Icon(Icons.schedule_rounded, key: const ValueKey('p'), size: 14, color: color.withValues(alpha: 0.7), semanticLabel: 'ממתין'),
      MsgStatus.sent => Icon(Icons.done_rounded, key: const ValueKey('s'), size: 16, color: color.withValues(alpha: 0.8), semanticLabel: 'נשלח'),
      MsgStatus.delivered => Icon(Icons.done_all_rounded, key: const ValueKey('d'), size: 16, color: delivered, semanticLabel: 'נמסר'),
      MsgStatus.received => const SizedBox.shrink(),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
      child: icon,
    );
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
      onTap: () => Navigator.of(context).push(PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, a, __) => FadeTransition(opacity: a, child: _FullImage(path: path!)),
      )),
      child: Hero(
        tag: path!,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: Image.file(File(path!), cacheWidth: 720, fit: BoxFit.cover),
          ),
        ),
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
        body: GestureDetector(
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0).abs() > 600) Navigator.pop(context);
          },
          child: Center(child: Hero(tag: path, child: InteractiveViewer(maxScale: 5, child: Image.file(File(path))))),
        ),
      );
}

/// One shared player for all voice notes, with 1x / 1.5x / 2x speed.
class VoicePlayback {
  static final AudioPlayer player = AudioPlayer();
  static final ValueNotifier<String?> playing = ValueNotifier(null);
  static final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  static final ValueNotifier<double> speed = ValueNotifier(1.0);
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
    if (speed.value != 1.0) await player.setPlaybackRate(speed.value);
  }

  static Future<void> cycleSpeed() async {
    speed.value = speed.value == 1.0 ? 1.5 : (speed.value == 1.5 ? 2.0 : 1.0);
    if (playing.value != null) await player.setPlaybackRate(speed.value);
  }
}

class VoiceBubbleBody extends StatelessWidget {
  const VoiceBubbleBody({super.key, required this.m, required this.fg});
  final ChatMessage m;
  final Color fg;

  // Deterministic pseudo-waveform from the message id.
  List<double> _bars() {
    var h = m.id.hashCode;
    return List.generate(28, (i) {
      h = (h * 1103515245 + 12345) & 0x7fffffff;
      return 0.25 + (h % 1000) / 1000 * 0.75;
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = m.durationMs ?? 0;
    final bars = _bars();
    return ValueListenableBuilder<String?>(
      valueListenable: VoicePlayback.playing,
      builder: (context, playingId, _) {
        final isMe = playingId == m.id;
        return SizedBox(
          width: 236,
          child: Row(children: [
            Material(
              color: fg.withValues(alpha: 0.15),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: m.mediaPath == null ? null : () => VoicePlayback.toggle(m),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(isMe ? Icons.pause_rounded : Icons.play_arrow_rounded, color: fg, size: 30),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ValueListenableBuilder<Duration>(
                valueListenable: VoicePlayback.position,
                builder: (context, pos, _) {
                  final v = (isMe && total > 0) ? (pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: SizedBox(
                        height: 26,
                        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                          for (var i = 0; i < bars.length; i++)
                            Expanded(
                              child: Container(
                                margin: const EdgeInsets.symmetric(horizontal: 1),
                                height: 26 * bars[i],
                                decoration: BoxDecoration(
                                  color: (i / bars.length) <= v && v > 0 ? fg : fg.withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(children: [
                      Text(isMe ? mmss(pos.inMilliseconds) : mmss(total),
                          style: TextStyle(color: fg.withValues(alpha: 0.85), fontSize: 12.5)),
                      const Spacer(),
                      if (isMe)
                        ValueListenableBuilder<double>(
                          valueListenable: VoicePlayback.speed,
                          builder: (_, sp, __) => GestureDetector(
                            onTap: VoicePlayback.cycleSpeed,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(color: fg.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(8)),
                              child: Text('${sp == sp.roundToDouble() ? sp.toInt() : sp}x',
                                  style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ),
                    ]),
                  ]);
                },
              ),
            ),
          ]),
        );
      },
    );
  }
}

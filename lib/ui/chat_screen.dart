import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../core/chat_controller.dart';
import '../core/link.dart';
import '../core/protocol.dart';
import '../core/store.dart';
import '../platform/native.dart';
import 'bubbles.dart';
import 'network_sheet.dart';
import 'setup_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.controller});
  final ChatController controller;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  ChatController get c => widget.controller;
  final _text = TextEditingController();
  final _scroll = ScrollController();
  final _picker = ImagePicker();
  final _recorder = AudioRecorder();
  StreamSubscription? _shareSub;

  bool get _isHost => c.settings['role'] == 'host';
  GroupInfo? _group;
  String? _hostError;
  bool _starting = false;
  bool _foreground = true;

  // recording state
  bool _recording = false;
  bool _cancelRecording = false;
  DateTime? _recStart;
  Timer? _recTimer;
  Duration _recElapsed = Duration.zero;
  double _dragDx = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _text.addListener(() => setState(() {}));
    c.onIncoming = _onIncoming;
    _shareSub = NativeBridge.shares.listen(_handleShare);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _startSession();
      final s = await NativeBridge.takeInitialShare();
      if (s != null) _handleShare(s);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
  }

  void _onIncoming(ChatMessage m) {
    if (_foreground) {
      HapticFeedback.mediumImpact();
    } else {
      final body = switch (m.kind) {
        MsgKind.text => m.text ?? '',
        MsgKind.image => '📷 תמונה',
        MsgKind.voice => '🎤 הודעה קולית',
      };
      NativeBridge.notify(c.peerName ?? "צ'אט טיסה", body);
    }
  }

  Future<void> _startSession() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _hostError = null;
    });
    try {
      if (_isHost) {
        final err = await NativeBridge.ensureHostPermissions();
        if (err != null) {
          setState(() => _hostError = err);
          return;
        }
        var ssid = c.settings['ssid'] as String?;
        var pass = c.settings['pass'] as String?;
        if (ssid == null || pass == null) {
          ssid = NativeBridge.generateSsid();
          pass = NativeBridge.generatePassphrase();
          await c.updateSettings({'ssid': ssid, 'pass': pass});
        }
        try {
          _group = await NativeBridge.startGroup(ssid, pass);
        } on WifiDirectError catch (e) {
          setState(() => _hostError = _explain(e));
          return;
        }
        await NativeBridge.startKeepAlive();
        await c.startLink(role: LinkRole.host);
        if (mounted && c.linkState != LinkState.connected && _group != null) {
          showNetworkSheet(context, _group!);
        }
      } else {
        await c.startLink(
            role: LinkRole.client, host: (c.settings['hostIp'] as String?) ?? kDefaultHostIp);
      }
    } catch (e) {
      setState(() => _hostError = 'שגיאה בהפעלה: $e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  String _explain(WifiDirectError e) => switch (e.code) {
        'WIFI_OFF' => 'ה־Wi-Fi כבוי. מדליקים Wi-Fi (גם במצב טיסה) ומנסים שוב.',
        'P2P_UNSUPPORTED' || 'UNSUPPORTED' => 'הטלפון הזה לא תומך ב־Wi-Fi Direct.',
        'BUSY' => 'ה־Wi-Fi עסוק כרגע. מנסים שוב בעוד כמה שניות.',
        'PERMISSION' => 'חסרה הרשאה. פותחים את הגדרות האפליקציה ומאשרים "מכשירים בקרבת מקום" או מיקום.',
        _ => 'לא הצלחתי ליצור את הרשת (${e.code}). מכבים ומדליקים Wi-Fi ומנסים שוב.',
      };

  Future<void> _stopSession() async {
    await c.stopLink();
    if (_isHost) {
      await NativeBridge.stopKeepAlive();
      await NativeBridge.stopGroup();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shareSub?.cancel();
    _recTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  // ---------- sending ----------

  Future<void> _sendText() async {
    final t = _text.text;
    if (t.trim().isEmpty) return;
    _text.clear();
    await c.sendText(t);
    _toBottom();
  }

  Future<void> _pickImage(ImageSource src) async {
    try {
      final x = await _picker.pickImage(source: src, maxWidth: 1280, maxHeight: 1280, imageQuality: 72);
      if (x == null) return;
      await c.sendImage(await x.readAsBytes());
      _toBottom();
    } catch (e) {
      _snack('לא הצלחתי לצרף את התמונה');
    }
  }

  Future<void> _handleShare(SharedPayload p) async {
    if (!mounted) return;
    final n = p.imagePaths.length;
    final what = [
      if (n == 1) 'תמונה אחת',
      if (n > 1) '$n תמונות',
      if (p.text != null && p.text!.trim().isNotEmpty) 'טקסט',
    ].join(' ו');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('לשלוח לצ׳אט?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('קיבלתי $what מאפליקציה אחרת.'),
          if (p.text != null) ...[
            const SizedBox(height: 8),
            Text(p.text!, maxLines: 4, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          ],
          if (n > 0) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 72,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final path in p.imagePaths)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: ClipRRect(borderRadius: BorderRadius.circular(10),
                        child: Image.file(File(path), width: 72, height: 72, fit: BoxFit.cover, cacheWidth: 200)),
                  ),
              ]),
            ),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('שליחה')),
        ],
      ),
    );
    if (ok != true) return;
    for (final path in p.imagePaths) {
      final f = File(path);
      if (await f.exists()) {
        await c.sendImage(await f.readAsBytes());
        await f.delete().catchError((_) => f);
      }
    }
    if (p.text != null && p.text!.trim().isNotEmpty) await c.sendText(p.text!);
    _toBottom();
  }

  // ---------- voice ----------

  Future<void> _startRecording() async {
    if (_recording) return;
    if (!await _recorder.hasPermission()) {
      _snack('צריך לאשר גישה למיקרופון כדי להקליט');
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 32000, sampleRate: 22050, numChannels: 1),
      path: path,
    );
    HapticFeedback.heavyImpact();
    setState(() {
      _recording = true;
      _cancelRecording = false;
      _dragDx = 0;
      _recStart = DateTime.now();
      _recElapsed = Duration.zero;
    });
    _recTimer?.cancel();
    _recTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      setState(() => _recElapsed = DateTime.now().difference(_recStart!));
      if (_recElapsed.inSeconds >= 120) _stopRecording(); // 2-minute cap
    });
  }

  Future<void> _stopRecording() async {
    if (!_recording) return;
    _recTimer?.cancel();
    final elapsed = DateTime.now().difference(_recStart!);
    final cancel = _cancelRecording;
    setState(() => _recording = false);
    final path = await _recorder.stop();
    if (path == null) return;
    final f = File(path);
    if (cancel || elapsed.inMilliseconds < 700) {
      if (!cancel) _snack('מחזיקים את המיקרופון לחוץ בזמן ההקלטה');
      await f.delete().catchError((_) => f);
      return;
    }
    await c.sendVoice(await f.readAsBytes(), elapsed.inMilliseconds);
    await f.delete().catchError((_) => f);
    _toBottom();
  }

  // ---------- helpers ----------

  void _toBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _openSettings() async {
    final changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => SetupScreen(controller: c, editing: true)));
    if (changed == true) {
      await _stopSession();
      await _startSession();
    }
  }

  Future<void> _menu(String v) async {
    switch (v) {
      case 'network':
        if (_group != null) await showNetworkSheet(context, _group!);
        break;
      case 'settings':
        await _openSettings();
        break;
      case 'newnet':
        await c.updateSettings({'ssid': null, 'pass': null});
        await _stopSession();
        await _startSession();
        break;
      case 'clear':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('למחוק את כל ההיסטוריה בטלפון הזה?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('מחיקה')),
            ],
          ),
        );
        if (ok == true) await c.clearHistory();
        break;
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final msgs = c.messages.reversed.toList();
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 12,
            title: Row(children: [
              CircleAvatar(
                backgroundColor: cs.primaryContainer,
                child: Icon(Icons.flight_rounded, color: cs.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.peerName ?? "צ'אט טיסה", style: const TextStyle(fontWeight: FontWeight.w700)),
                  _StatusLine(state: c.linkState, isHost: _isHost, error: _hostError, starting: _starting),
                ]),
              ),
            ]),
            actions: [
              if (_isHost && _group != null)
                IconButton(
                  tooltip: 'פרטי הרשת',
                  icon: const Icon(Icons.wifi_password_rounded),
                  onPressed: () => showNetworkSheet(context, _group!),
                ),
              PopupMenuButton<String>(
                onSelected: _menu,
                itemBuilder: (_) => [
                  if (_isHost && _group != null) const PopupMenuItem(value: 'network', child: Text('שם הרשת והסיסמה')),
                  if (_isHost) const PopupMenuItem(value: 'newnet', child: Text('ליצור רשת עם סיסמה חדשה')),
                  const PopupMenuItem(value: 'settings', child: Text('הגדרות')),
                  const PopupMenuItem(value: 'clear', child: Text('מחיקת היסטוריה')),
                ],
              ),
            ],
          ),
          body: Column(children: [
            if (_hostError != null)
              MaterialBanner(
                content: Text(_hostError!),
                leading: const Icon(Icons.error_outline_rounded),
                actions: [TextButton(onPressed: _startSession, child: const Text('לנסות שוב'))],
              ),
            if (!_isHost && c.linkState != LinkState.connected)
              _JoinHint(onOpenSettings: _openSettings),
            Expanded(
              child: msgs.isEmpty
                  ? _EmptyState(isHost: _isHost, group: _group, connected: c.linkState == LinkState.connected)
                  : ListView.builder(
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      itemCount: msgs.length,
                      itemBuilder: (_, i) => MessageBubble(key: ValueKey(msgs[i].id), m: msgs[i]),
                    ),
            ),
            _composer(cs),
          ]),
        );
      },
    );
  }

  Widget _composer(ColorScheme cs) {
    final hasText = _text.text.trim().isNotEmpty;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: _recording
                ? Container(
                    height: 50,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: _cancelRecording ? cs.errorContainer : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(25),
                    ),
                    child: Row(children: [
                      Icon(Icons.fiber_manual_record, color: cs.error, size: 14),
                      const SizedBox(width: 8),
                      Text('${_recElapsed.inMinutes}:${(_recElapsed.inSeconds % 60).toString().padLeft(2, '0')}',
                          style: const TextStyle(fontSize: 16, fontFeatures: [FontFeature.tabularFigures()])),
                      const Spacer(),
                      Text(_cancelRecording ? 'משחררים לביטול' : 'החליקו הצידה לביטול',
                          style: TextStyle(color: cs.onSurfaceVariant)),
                    ]),
                  )
                : Container(
                    decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(25)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Expanded(
                        child: TextField(
                          controller: _text,
                          minLines: 1,
                          maxLines: 5,
                          textInputAction: TextInputAction.newline,
                          decoration: const InputDecoration(
                            hintText: 'הודעה',
                            filled: false,
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'תמונה מהגלריה',
                        icon: Icon(Icons.photo_outlined, color: cs.onSurfaceVariant),
                        onPressed: () => _pickImage(ImageSource.gallery),
                      ),
                      if (!hasText)
                        IconButton(
                          tooltip: 'מצלמה',
                          icon: Icon(Icons.photo_camera_outlined, color: cs.onSurfaceVariant),
                          onPressed: () => _pickImage(ImageSource.camera),
                        ),
                    ]),
                  ),
          ),
          const SizedBox(width: 6),
          hasText
              ? _RoundButton(icon: Icons.send_rounded, onTap: _sendText)
              : Listener(
                  onPointerDown: (_) => _startRecording(),
                  onPointerMove: (e) {
                    _dragDx += e.delta.dx;
                    final cancel = _dragDx.abs() > 90;
                    if (cancel != _cancelRecording) setState(() => _cancelRecording = cancel);
                  },
                  onPointerUp: (_) => _stopRecording(),
                  onPointerCancel: (_) {
                    _cancelRecording = true;
                    _stopRecording();
                  },
                  child: AnimatedScale(
                    scale: _recording ? 1.35 : 1,
                    duration: const Duration(milliseconds: 150),
                    child: _RoundButton(icon: Icons.mic_rounded, onTap: null, active: _recording),
                  ),
                ),
        ]),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap, this.active = false});
  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: active ? cs.error : cs.primary,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 50, height: 50, child: Icon(icon, color: cs.onPrimary)),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.state, required this.isHost, this.error, required this.starting});
  final LinkState state;
  final bool isHost;
  final String? error;
  final bool starting;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (String label, Color color) = error != null
        ? ('יש בעיה, ראו למטה', cs.error)
        : starting
            ? ('מפעיל...', cs.onSurfaceVariant)
            : switch (state) {
                LinkState.connected => ('מחובר', const Color(0xFF2E7D32)),
                LinkState.waiting => (isHost ? 'הרשת פתוחה, מחכה לטלפון השני' : 'מחפש את הטלפון השני...', cs.onSurfaceVariant),
                LinkState.connecting => ('מתחבר...', cs.onSurfaceVariant),
                LinkState.stopped => ('לא פעיל', cs.onSurfaceVariant),
              };
    return Row(children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: color))),
    ]);
  }
}

class _JoinHint extends StatelessWidget {
  const _JoinHint({required this.onOpenSettings});
  final VoidCallback onOpenSettings;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(16)),
      child: Text(
        'כדי להתחבר: בהגדרות ה־Wi-Fi של הטלפון הזה בוחרים את הרשת שמתחילה ב־DIRECT ומופיעה בטלפון השני, '
        'מקלידים את הסיסמה שמוצגת שם, וחוזרים לכאן. החיבור יקרה לבד.',
        style: TextStyle(color: cs.onSecondaryContainer),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.isHost, required this.group, required this.connected});
  final bool isHost;
  final GroupInfo? group;
  final bool connected;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (isHost && group != null && !connected) {
      return ListView(padding: const EdgeInsets.all(16), children: [NetworkCard(info: group!, compact: true)]);
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.forum_outlined, size: 64, color: cs.outline),
          const SizedBox(height: 12),
          Text(connected ? 'מחוברים. אפשר לכתוב.' : 'עוד אין הודעות',
              style: TextStyle(fontSize: 17, color: cs.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

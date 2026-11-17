import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';

import '../core/chat_controller.dart';
import '../core/discovery.dart';
import '../core/link.dart';
import '../core/protocol.dart';
import '../core/store.dart';
import '../platform/native.dart';
import '../platform/nearby.dart';
import 'bubbles.dart';
import 'connect_help.dart';
import 'network_sheet.dart';
import 'setup_screen.dart';
import 'theme.dart';

const kDefaultQuickReplies = [
  'אני בשירותים 🚻',
  'רוצה לאכול? 🍽️',
  'ער/ה? 👀',
  'הכול בסדר? 🙂',
  'תביא/י לי מים 💧',
  'בוא/י אליי',
  'נוחתים בקרוב ✈️',
  '❤️',
];

const kReactions = ['❤️', '👍', '😂', '😮', '🙏', '😢'];

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.controller});
  final ChatController controller;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver, TickerProviderStateMixin {
  ChatController get c => widget.controller;
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _picker = ImagePicker();
  final _recorder = AudioRecorder();
  StreamSubscription? _shareSub;

  bool get _isHost => c.settings['role'] == 'host';
  GroupInfo? _group;
  String? _hostError;
  NetCheck? _check;
  final _checkLive = ValueNotifier<NetCheck?>(null);
  Timer? _checkTimer;
  DateTime _lastGroupRestart = DateTime.fromMillisecondsSinceEpoch(0);
  String get _mode => (c.settings['netMode'] as String?) ?? kModeHotspot;
  bool _starting = false;
  bool _foreground = true;

  ChatMessage? _replyTo;
  bool _searching = false;
  bool _showQuick = false;
  bool _awayFromBottom = false;
  int _unseen = 0;
  late final Set<String> _initialIds = c.messages.map((m) => m.id).toSet();

  late final AnimationController _shake =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  // recording state
  bool _recording = false;
  bool _cancelRecording = false;
  DateTime? _recStart;
  Timer? _recTimer;
  Duration _recElapsed = Duration.zero;
  double _dragDx = 0;

  List<String> get _quickReplies =>
      ((c.settings['quick'] as List?)?.cast<String>()) ?? kDefaultQuickReplies;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _text.addListener(() {
      setState(() {});
      c.setTyping(_text.text.trim().isNotEmpty);
    });
    _search.addListener(() => setState(() {}));
    _scroll.addListener(() {
      final away = _scroll.hasClients && _scroll.offset > 300;
      if (away != _awayFromBottom) {
        setState(() {
          _awayFromBottom = away;
          if (!away) _unseen = 0;
        });
      }
    });
    c.onIncoming = _onIncoming;
    c.onNudge = _onNudge;
    c.onReaction = (_, __) => HapticFeedback.lightImpact();
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
    if (!_foreground) c.setTyping(false);
  }

  void _onIncoming(ChatMessage m) {
    if (_foreground) {
      HapticFeedback.mediumImpact();
      if (_awayFromBottom) setState(() => _unseen++);
    } else {
      NativeBridge.notify(c.peerName ?? "צ'אט טיסה", m.preview);
    }
  }

  void _onNudge() {
    NativeBridge.buzz();
    _shake.forward(from: 0);
    final who = c.peerName ?? 'הצד השני';
    if (_foreground) {
      _snack('📳 $who מנסה להשיג אותך');
    } else {
      NativeBridge.notify('📳 $who', 'מנסה להשיג אותך', id: 1002);
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
        if (_mode == kModeDirect) {
          final err = await NativeBridge.ensureHostPermissions();
          if (err != null) {
            setState(() => _hostError = err);
            return;
          }
          var ssid = c.settings['ssid'] as String?;
          var pass = c.settings['pass'] as String?;
          if (ssid == null || !NativeBridge.isSimplePassphrase(pass)) {
            ssid = NativeBridge.generateSsid();
            pass = NativeBridge.generatePassphrase();
            await c.updateSettings({'ssid': ssid, 'pass': pass});
          }
          try {
            _group = await NativeBridge.startGroup(ssid, pass!);
          } on WifiDirectError catch (e) {
            // Keep the TCP server running anyway: it still works if both
            // phones share another network (hotspot, plane Wi‑Fi).
            setState(() => _hostError = _explain(e));
          }
        } else {
          // Hotspot / shared network: no Wi‑Fi Direct group at all.
          await NativeBridge.ensureNotificationPermission();
          try {
            await NativeBridge.stopGroup();
          } catch (_) {}
          _group = null;
        }
        await NativeBridge.startKeepAlive();
        // Listens on all interfaces (hotspot, Wi‑Fi, Wi‑Fi Direct) + beacon.
        await c.startLink(role: LinkRole.host, discover: true);
        if (mounted && _mode == kModeDirect && c.linkState != LinkState.connected && _group != null) {
          showNetworkSheet(context, _group!);
        }
      } else {
        await c.startLink(
            role: LinkRole.client,
            host: (c.settings['hostIp'] as String?) ?? kDefaultHostIp,
            discover: true);
      }
      try {
        await _startNearby();
      } catch (_) {}
    } catch (e) {
      setState(() => _hostError = 'שגיאה בהפעלה: $e');
    } finally {
      if (mounted) setState(() => _starting = false);
      _checkTimer?.cancel();
      _checkTimer = Timer.periodic(const Duration(seconds: 5), (_) => _selfCheck());
      unawaited(_selfCheck());
    }
  }

  /// Honest status of the network, refreshed every 5 s until connected.
  Future<void> _selfCheck() async {
    if (!mounted || _starting) return;
    if (c.linkState == LinkState.connected) {
      if (_check != null) setState(() => _check = null);
      return;
    }
    final ips = await localPrivateIPv4();
    NetCheck chk;
    if (_isHost && _mode == kModeDirect) {
      GroupInfo? g;
      try {
        g = await NativeBridge.groupInfo();
      } catch (_) {}
      if (g == null) {
        chk = NetCheck(false,
            'הרשת הישירה לא פעילה כרגע (לא נוצרה או נפלה).${_hostError == null ? ' מנסה להקים אותה שוב.' : ''} נקודה חמה עובדת טוב יותר עם אייפון.',
            suggestHotspot: true);
        if (DateTime.now().difference(_lastGroupRestart).inSeconds > 45 && _hostError == null) {
          _lastGroupRestart = DateTime.now();
          final ssid = c.settings['ssid'] as String?;
          final pass = c.settings['pass'] as String?;
          if (ssid != null && pass != null) {
            NativeBridge.startGroup(ssid, pass).then((v) {
              if (mounted) setState(() => _group = v);
            }, onError: (_) {});
          }
        }
      } else {
        _group = g;
        final ch = g.channel;
        final where = ch == null ? '' : ', ערוץ $ch (${g.on5GHz ? '5GHz' : '2.4GHz'})';
        if (g.on5GHz) {
          chk = NetCheck(false, 'הרשת ${g.ssid} פעילה, אבל ב־5GHz$where. ייתכן שהאייפון לא יראה אותה. מומלץ לעבור לנקודה חמה.',
              suggestHotspot: true);
        } else if (g.clients > 0) {
          chk = NetCheck(true, 'טלפון הצטרף לרשת ${g.ssid}$where. עכשיו פותחים בו את צ\'אט טיסה.');
        } else {
          chk = NetCheck(true,
              'הרשת ${g.ssid} פעילה$where, ועוד אף טלפון לא הצטרף. אם היא לא מופיעה באייפון תוך דקה, עוברים לנקודה חמה. יש אייפונים שלא מציגים רשת כזאת.',
              suggestHotspot: true);
        }
      }
    } else if (_isHost) {
      Map st = const {};
      try {
        st = await NativeBridge.status();
      } catch (_) {}
      final addr = ips.isEmpty ? '' : '\nכתובת: \u2066${ips.join('  ')}\u2069';
      if (st['hotspotOn'] == true) {
        chk = NetCheck(true, 'הנקודה החמה דלוקה. מחכה שהאייפון יצטרף אליה ויפתח את צ\'אט טיסה.$addr');
      } else if (ips.isNotEmpty) {
        chk = NetCheck(true, 'הטלפון מחובר לרשת. אם הטלפון השני באותה רשת, הם יתחברו לבד. אחרת מדליקים נקודה חמה.$addr');
      } else {
        chk = const NetCheck(false, 'הנקודה החמה עוד לא דלוקה. מדליקים אותה (אחרי מצב טיסה, אם צריך), ואז האייפון מצטרף.');
      }
    } else {
      if (ips.isEmpty) {
        chk = const NetCheck(false,
            'הטלפון הזה לא מחובר לשום רשת Wi‑Fi. מצטרפים בהגדרות ה־Wi‑Fi לנקודה החמה של הטלפון השני, וחוזרים לכאן.');
      } else {
        final more = c.failedAttempts >= 3
            ? ' עדיין לא נמצא: בודקים שצ\'אט טיסה פתוח בטלפון השני ושמדובר באותה רשת. באייפון: הגדרות ← צ\'אט טיסה ← "רשת מקומית" צריך להיות דלוק.'
            : '';
        chk = NetCheck(true, 'מחובר לרשת (\u2066${ips.first}\u2069). מחפש את הטלפון השני…$more');
      }
    }
    final bt = _nearbyLine();
    if (bt != null) chk = NetCheck(chk.ok || _nearby?.phase == NearbyPhase.searching, '$bt\n${chk.text}',
        suggestHotspot: chk.suggestHotspot);
    _checkLive.value = chk;
    if (mounted) setState(() => _check = chk);
  }

  Future<void> _setMode(String m) async {
    await c.updateSettings({'netMode': m});
    await _stopSession();
    _group = null;
    _hostError = null;
    await _startSession();
  }

  void _help() => showHostHelp(context, mode: _mode, group: _group, check: _check, live: _checkLive);

  String _explain(WifiDirectError e) => switch (e.code) {
        'WIFI_OFF' => 'ה־Wi‑Fi כבוי. מדליקים Wi‑Fi (גם במצב טיסה) ומנסים שוב.',
        'P2P_UNSUPPORTED' || 'UNSUPPORTED' => 'הטלפון הזה לא תומך ב־Wi‑Fi Direct.',
        'BUSY' => 'ה־Wi‑Fi עסוק כרגע. מנסים שוב בעוד כמה שניות.',
        'PERMISSION' => 'חסרה הרשאה. פותחים את הגדרות האפליקציה ומאשרים "מכשירים בקרבת מקום" או מיקום.',
        _ => 'לא הצלחתי ליצור את הרשת (${e.code}). מכבים ומדליקים Wi‑Fi ומנסים שוב.',
      };

  // v4: automatic Bluetooth link (Nearby Connections), runs next to Wi‑Fi.
  NearbyService? _nearby;
  StreamSubscription? _nearbySub;
  bool get _nearbyOn => c.settings['nearby'] != false;

  Future<void> _startNearby() async {
    await _stopNearby();
    if (!_nearbyOn || !NearbyService.supported) return;
    await NativeBridge.ensureNearbyPermissions();
    final n = NearbyService(deviceName: c.deviceName, deviceId: c.deviceId);
    n.onPipe = c.adoptPipe;
    n.onPipeClosed = c.pipeClosed;
    _nearby = n;
    _nearbySub = n.phases.listen((_) {
      if (mounted) setState(() {});
      unawaited(_selfCheck());
    });
    await n.start();
  }

  Future<void> _stopNearby() async {
    await _nearbySub?.cancel();
    _nearbySub = null;
    final n = _nearby;
    _nearby = null;
    await n?.stop();
  }

  /// One Hebrew line about the Bluetooth path, for the status card.
  String? _nearbyLine() {
    final n = _nearby;
    if (!_nearbyOn) return null;
    if (n == null) return null;
    final err = n.lastError ?? '';
    return switch (n.phase) {
      NearbyPhase.searching => 'Bluetooth: מחפש את הטלפון השני לבד (צריך שצ\'אט טיסה יהיה פתוח בשניהם ו־Bluetooth דלוק).',
      NearbyPhase.connecting => 'Bluetooth: נמצא טלפון, מתחבר…',
      NearbyPhase.connected => 'Bluetooth: מחובר.',
      NearbyPhase.noPermission => 'Bluetooth: חסרה הרשאת "מכשירים בקרבת מקום". מאשרים אותה בהגדרות של צ\'אט טיסה. אם כבר אישרתם: הגדרות, אפליקציות, Google Play services, הרשאות, "מכשירים בקרבת מקום", לאשר.',
      NearbyPhase.error => err.contains('8038') || err.contains('8029') || err.contains('8034')
          ? 'Bluetooth: שירותי Google Play חסרים הרשאה. בהגדרות: אפליקציות, Google Play services, הרשאות, "מכשירים בקרבת מקום": לאשר.'
          : 'Bluetooth: לא הצליח להתחיל ($err). בודקים ש־Bluetooth דלוק.',
      NearbyPhase.unsupported => null,
      NearbyPhase.off => null,
    };
  }

  Future<void> _stopSession() async {
    await _stopNearby();
    await c.stopLink();
    if (_isHost) {
      await NativeBridge.stopKeepAlive();
      await NativeBridge.stopGroup();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _checkTimer?.cancel();
    unawaited(_stopNearby());
    _checkLive.dispose();
    _shareSub?.cancel();
    _recTimer?.cancel();
    _recorder.dispose();
    _shake.dispose();
    super.dispose();
  }

  // ---------- sending ----------

  Future<void> _sendText([String? override]) async {
    final t = override ?? _text.text;
    if (t.trim().isEmpty) return;
    if (override == null) _text.clear();
    final r = _replyTo;
    setState(() => _replyTo = null);
    HapticFeedback.lightImpact();
    await c.sendText(t, replyTo: r);
    _toBottom();
  }

  Future<void> _pickImage(ImageSource src) async {
    try {
      // 1280 px / q70: a phone photo becomes ~150-250 KB, sent in under a second.
      final x = await _picker.pickImage(source: src, maxWidth: 1280, maxHeight: 1280, imageQuality: 70);
      if (x == null) return;
      final r = _replyTo;
      setState(() => _replyTo = null);
      await c.sendImage(await x.readAsBytes(), caption: _text.text, replyTo: r);
      _text.clear();
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
    final r = _replyTo;
    setState(() => _replyTo = null);
    await c.sendVoice(await f.readAsBytes(), elapsed.inMilliseconds, replyTo: r);
    await f.delete().catchError((_) => f);
    _toBottom();
  }

  // ---------- message actions ----------

  void _startReply(ChatMessage m) {
    setState(() => _replyTo = m);
    _focus.requestFocus();
  }

  Future<void> _messageActions(ChatMessage m) async {
    final cs = Theme.of(context).colorScheme;
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              for (final e in kReactions)
                InkResponse(
                  radius: 28,
                  onTap: () {
                    Navigator.pop(ctx);
                    HapticFeedback.selectionClick();
                    c.react(m, e);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: m.myReaction == e ? cs.primaryContainer : Colors.transparent,
                    ),
                    child: Text(e, style: const TextStyle(fontSize: 30)),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.reply_rounded),
            title: const Text('תגובה'),
            onTap: () {
              Navigator.pop(ctx);
              _startReply(m);
            },
          ),
          if (m.text != null)
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('העתקה'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: m.text!));
                _snack('הועתק');
              },
            ),
          if (m.mediaPath != null)
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: Text(m.kind == MsgKind.image ? 'שיתוף התמונה' : 'שיתוף ההקלטה'),
              onTap: () {
                Navigator.pop(ctx);
                SharePlus.instance.share(ShareParams(files: [XFile(m.mediaPath!)]));
              },
            ),
          ListTile(
            leading: Icon(Icons.delete_outline_rounded, color: cs.error),
            title: Text('מחיקה אצלי', style: TextStyle(color: cs.error)),
            subtitle: const Text('נמחק רק בטלפון הזה'),
            onTap: () {
              Navigator.pop(ctx);
              c.deleteForMe(m);
              if (_replyTo?.id == m.id) setState(() => _replyTo = null);
            },
          ),
        ]),
      ),
    );
  }

  // ---------- helpers ----------

  void _toBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
    }
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));
  }

  Future<void> _openSettings() async {
    final changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => SetupScreen(controller: c, editing: true)));
    if (changed == true) {
      await _stopSession();
      await _startSession();
    }
  }

  Future<String?> _ask(String title, {String? initial, String? hint, int maxLines = 1, TextDirection? dir}) {
    final t = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: t,
          autofocus: true,
          maxLines: maxLines,
          textDirection: dir,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ביטול')),
          FilledButton(onPressed: () => Navigator.pop(ctx, t.text), child: const Text('שמירה')),
        ],
      ),
    );
  }

  Future<void> _editSeat() async {
    final s = await _ask('המושב שלי', initial: c.mySeat, hint: 'למשל 23C', dir: TextDirection.ltr);
    if (s != null) await c.setSeat(s);
  }

  Future<void> _sendSeat() async {
    if (c.mySeat == null) await _editSeat();
    final seat = c.mySeat;
    if (seat != null) await _sendText('📍 אני במושב $seat');
  }

  Future<void> _editQuick() async {
    final s = await _ask('תשובות מהירות (אחת בכל שורה)', initial: _quickReplies.join('\n'), maxLines: 8);
    if (s == null) return;
    final list = s.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    await c.updateSettings({'quick': list.isEmpty ? null : list});
  }

  Future<void> _export() async {
    final dir = await getTemporaryDirectory();
    final d = DateTime.now();
    final f = File('${dir.path}/plane-chat-${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}.txt');
    await f.writeAsString(c.exportText());
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'text/plain')], subject: "צ'אט טיסה"));
  }

  Future<void> _cycleTheme() async {
    const order = ['system', 'light', 'dark'];
    final cur = (c.settings['theme'] as String?) ?? 'system';
    final next = order[(order.indexOf(cur) + 1) % order.length];
    await c.updateSettings({'theme': next});
    _snack(switch (next) { 'light' => 'מצב בהיר', 'dark' => 'מצב כהה', _ => 'לפי הגדרות הטלפון' });
  }

  Future<void> _menu(String v) async {
    switch (v) {
      case 'network':
        _help();
        break;
      case 'bt':
        await c.updateSettings({'nearby': !_nearbyOn});
        if (_nearbyOn) {
          await _startNearby();
        } else {
          await _stopNearby();
        }
        _snack(_nearbyOn ? 'חיבור אוטומטי ב־Bluetooth דלוק' : 'חיבור אוטומטי ב־Bluetooth כבוי');
        unawaited(_selfCheck());
        break;
      case 'mode':
        await _setMode(_mode == kModeDirect ? kModeHotspot : kModeDirect);
        _snack(_mode == kModeDirect ? 'עברנו לרשת ישירה' : 'עברנו לנקודה חמה');
        break;
      case 'seat':
        await _editSeat();
        break;
      case 'quick':
        await _editQuick();
        break;
      case 'export':
        await _export();
        break;
      case 'theme':
        await _cycleTheme();
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
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final all = c.messages.reversed.toList();
        final q = _search.text.trim();
        final msgs = _searching && q.isNotEmpty
            ? all.where((m) => (m.text ?? '').toLowerCase().contains(q.toLowerCase())).toList()
            : all;
        final connected = c.linkState == LinkState.connected;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_searching) {
              setState(() {
                _searching = false;
                _search.clear();
              });
            } else if (_replyTo != null) {
              setState(() => _replyTo = null);
            } else {
              NativeBridge.moveToBack();
            }
          },
          child: AnimatedBuilder(
            animation: _shake,
            builder: (context, child) {
              final t = _shake.value;
              final dx = t == 0 || t == 1 ? 0.0 : sin(t * pi * 8) * 10 * (1 - t);
              return Transform.translate(offset: Offset(dx, 0), child: child);
            },
            child: Scaffold(
              appBar: _searching ? _searchBar() : _appBar(connected),
              body: _Wallpaper(
                child: Column(children: [
                  if (_hostError != null && !connected)
                    MaterialBanner(
                      content: Text(_hostError!),
                      leading: const Icon(Icons.error_outline_rounded),
                      actions: [TextButton(onPressed: _startSession, child: const Text('לנסות שוב'))],
                    ),
                  _ConnectionBanner(
                    visible: !connected && !_starting && (c.pendingCount > 0 || (c.peerLastSeen != null && _check == null)),
                    pending: c.pendingCount,
                    isHost: _isHost,
                  ),
                  if (!connected && _check != null)
                    NetCheckBanner(
                      check: _check!,
                      onHelp: _isHost ? _help : null,
                      onRetry: _isHost ? () async {
                        await _stopSession();
                        await _startSession();
                      } : null,
                      onUseHotspot: _isHost && _mode == kModeDirect ? () => _setMode(kModeHotspot) : null,
                    ),
                  if (!_isHost && !connected && c.peerLastSeen == null) _JoinHint(),
                  Expanded(
                    child: Stack(children: [
                      msgs.isEmpty
                          ? _EmptyState(isHost: _isHost, group: _group, connected: connected, searching: _searching, mode: _mode, check: _check)
                          : ListView.builder(
                              controller: _scroll,
                              reverse: true,
                              padding: const EdgeInsets.only(top: 10, bottom: 8),
                              itemCount: msgs.length,
                              itemBuilder: (_, i) => _row(msgs, i),
                            ),
                      PositionedDirectional(
                        bottom: 10,
                        end: 12,
                        child: AnimatedScale(
                          scale: _awayFromBottom ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Badge(
                            isLabelVisible: _unseen > 0,
                            label: Text('$_unseen'),
                            child: FloatingActionButton.small(
                              heroTag: 'down',
                              onPressed: () {
                                setState(() => _unseen = 0);
                                _toBottom();
                              },
                              child: const Icon(Icons.keyboard_double_arrow_down_rounded),
                            ),
                          ),
                        ),
                      ),
                    ]),
                  ),
                  if (!_searching) _composer(),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _row(List<ChatMessage> msgs, int i) {
    final m = msgs[i];
    final older = i + 1 < msgs.length ? msgs[i + 1] : null;
    final newer = i > 0 ? msgs[i - 1] : null;
    bool grouped(ChatMessage? o) =>
        o != null && o.fromMe == m.fromMe && sameDay(o.ts, m.ts) && (o.ts - m.ts).abs() < 3 * 60 * 1000;
    final showDay = older == null || !sameDay(older.ts, m.ts);
    final row = MessageRow(
      key: ValueKey(m.id),
      m: m,
      groupedWithPrev: grouped(older) && !showDay,
      groupedWithNext: grouped(newer),
      animateIn: !_initialIds.contains(m.id),
      onReply: () => _startReply(m),
      onLongPress: () => _messageActions(m),
      highlight: _searching ? _search.text : null,
    );
    if (!showDay) return row;
    return Column(mainAxisSize: MainAxisSize.min, children: [_DayChip(label: dayLabel(m.ts)), row]);
  }

  PreferredSizeWidget _searchBar() => AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_forward_rounded),
          onPressed: () => setState(() {
            _searching = false;
            _search.clear();
          }),
        ),
        title: TextField(
          controller: _search,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'חיפוש בשיחה', filled: false, border: InputBorder.none),
        ),
        actions: [
          if (_search.text.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(end: 16),
                child: Text('${c.search(_search.text).length} תוצאות'),
              ),
            ),
        ],
      );

  PreferredSizeWidget _appBar(bool connected) {
    final cs = Theme.of(context).colorScheme;
    final name = c.peerName ?? "צ'אט טיסה";
    return AppBar(
      titleSpacing: 12,
      title: Row(children: [
        _Avatar(name: c.peerName, online: connected),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18), overflow: TextOverflow.ellipsis),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: KeyedSubtree(key: ValueKey(_subtitleKey(connected)), child: _subtitle(connected, cs)),
            ),
          ]),
        ),
      ]),
      actions: [
        IconButton(
          tooltip: 'לבזבז את הטלפון השני',
          icon: const Icon(Icons.vibration_rounded),
          onPressed: connected
              ? () {
                  if (c.nudge()) {
                    HapticFeedback.mediumImpact();
                    _snack('📳 נשלח רטט');
                  } else {
                    _snack('רגע, כבר נשלח');
                  }
                }
              : null,
        ),
        IconButton(
          tooltip: 'חיפוש',
          icon: const Icon(Icons.search_rounded),
          onPressed: () => setState(() => _searching = true),
        ),
        PopupMenuButton<String>(
          onSelected: _menu,
          itemBuilder: (_) => [
            if (_isHost) _mi('network', Icons.help_outline_rounded, _mode == kModeDirect ? 'הרשת (QR וסיסמה)' : 'איך מתחברים'),
            if (_isHost)
              _mi('mode', Icons.swap_horiz_rounded,
                  _mode == kModeDirect ? 'מעבר לנקודה חמה (מומלץ)' : 'מעבר לרשת ישירה'),
            _mi('seat', Icons.event_seat_rounded, c.mySeat == null ? 'המושב שלי' : 'המושב שלי: ${c.mySeat}'),
            _mi('quick', Icons.bolt_rounded, 'עריכת תשובות מהירות'),
            _mi('export', Icons.ios_share_rounded, 'ייצוא השיחה'),
            _mi('bt', Icons.bluetooth_rounded, _nearbyOn ? 'כיבוי חיבור אוטומטי ב־Bluetooth' : 'הדלקת חיבור אוטומטי ב־Bluetooth'),
            _mi('theme', Icons.dark_mode_outlined, 'בהיר / כהה'),
            _mi('settings', Icons.settings_outlined, 'הגדרות'),
            if (_isHost && _mode == kModeDirect) _mi('newnet', Icons.wifi_password_rounded, 'רשת עם סיסמה חדשה'),
            _mi('clear', Icons.delete_sweep_outlined, 'מחיקת היסטוריה'),
          ],
        ),
      ],
    );
  }

  PopupMenuItem<String> _mi(String v, IconData i, String t) =>
      PopupMenuItem(value: v, child: Row(children: [Icon(i, size: 20), const SizedBox(width: 12), Text(t)]));

  String _subtitleKey(bool connected) =>
      '${connected}_${c.linkVia}_${c.peerTyping}_${_hostError != null}_$_starting';

  Widget _subtitle(bool connected, ColorScheme cs) {
    TextStyle st(Color col) => TextStyle(fontSize: 13, color: col);
    if (connected && c.peerTyping) {
      return Row(children: [
        Text('מקליד/ה', style: st(cs.primary)),
        _TypingDots(color: cs.primary),
      ]);
    }
    if (connected) {
      final via = c.linkVia == 'nearby' ? ' · Bluetooth' : (c.linkVia == 'wifi' ? ' · Wi‑Fi' : '');
      final parts = <InlineSpan>[TextSpan(text: 'מחובר$via', style: st(const Color(0xFF16A34A)))];
      if (c.peerBattery != null) {
        final low = c.peerBattery! <= 20 && c.peerCharging != true;
        parts.add(TextSpan(
          text: '  ${c.peerCharging == true ? '⚡' : '🔋'}${c.peerBattery}%',
          style: st(low ? cs.error : cs.onSurfaceVariant),
        ));
      }
      if (c.peerSeat != null) parts.add(TextSpan(text: '  💺${c.peerSeat}', style: st(cs.onSurfaceVariant)));
      return Text.rich(TextSpan(children: parts), overflow: TextOverflow.ellipsis);
    }
    if (_starting) return Text('מפעיל…', style: st(cs.onSurfaceVariant));
    if (_hostError != null && _group == null && _isHost) return Text('יש בעיה ברשת, ראו למטה', style: st(cs.error));
    final waiting = _isHost
        ? (_check != null && !_check!.ok ? 'אין רשת פעילה, ראו למטה' : 'מחכה שהטלפון השני יתחבר')
        : 'מחפש את הטלפון השני…';
    final seen = c.peerLastSeen == null ? '' : ' · נראה לאחרונה ${hhmm(c.peerLastSeen!)}';
    return Text('$waiting$seen', style: st(cs.onSurfaceVariant), overflow: TextOverflow.ellipsis);
  }

  Widget _composer() {
    final cs = Theme.of(context).colorScheme;
    final p = ChatPalette(context);
    final hasText = _text.text.trim().isNotEmpty;
    return Material(
      color: p.dark ? const Color(0xFF111A2E) : Colors.white,
      elevation: 0,
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: _replyTo == null ? const SizedBox(width: double.infinity) : _replyBar(cs),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: !_showQuick ? const SizedBox(width: double.infinity) : _quickRow(cs),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: _recording
                    ? _recordingPill(cs)
                    : Container(
                        decoration: BoxDecoration(
                          color: p.dark ? const Color(0xFF1C2740) : const Color(0xFFF1F4FA),
                          borderRadius: BorderRadius.circular(26),
                        ),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          IconButton(
                            tooltip: 'תשובות מהירות',
                            icon: Icon(_showQuick ? Icons.keyboard_rounded : Icons.bolt_rounded,
                                color: _showQuick ? cs.primary : cs.onSurfaceVariant),
                            onPressed: () => setState(() => _showQuick = !_showQuick),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _text,
                              focusNode: _focus,
                              minLines: 1,
                              maxLines: 5,
                              textInputAction: TextInputAction.newline,
                              decoration: const InputDecoration(
                                hintText: 'הודעה',
                                filled: false,
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 13),
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
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                child: hasText
                    ? _RoundButton(key: const ValueKey('send'), icon: Icons.send_rounded, onTap: () => _sendText())
                    : Listener(
                        key: const ValueKey('mic'),
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
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _replyBar(ColorScheme cs) {
    final r = _replyTo!;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: BorderDirectional(start: BorderSide(color: cs.primary, width: 4)),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(r.fromMe ? 'תגובה להודעה שלי' : 'תגובה ל${c.peerName ?? 'הודעה'}',
                style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600, fontSize: 13)),
            Text(r.preview, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => setState(() => _replyTo = null)),
      ]),
    );
  }

  Widget _quickRow(ColorScheme cs) {
    return SizedBox(
      height: 50,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
        children: [
          ActionChip(
            avatar: const Icon(Icons.event_seat_rounded, size: 18),
            label: Text(c.mySeat == null ? 'המושב שלי' : 'מושב ${c.mySeat}'),
            onPressed: _sendSeat,
          ),
          for (final r in _quickReplies)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6),
              child: ActionChip(label: Text(r), onPressed: () => _sendText(r)),
            ),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 6),
            child: ActionChip(avatar: const Icon(Icons.edit_rounded, size: 16), label: const Text('עריכה'), onPressed: _editQuick),
          ),
        ],
      ),
    );
  }

  Widget _recordingPill(ColorScheme cs) {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: _cancelRecording ? cs.errorContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(25),
      ),
      child: Row(children: [
        _Pulse(color: cs.error),
        const SizedBox(width: 10),
        Text('${_recElapsed.inMinutes}:${(_recElapsed.inSeconds % 60).toString().padLeft(2, '0')}',
            style: const TextStyle(fontSize: 16, fontFeatures: [FontFeature.tabularFigures()])),
        const Spacer(),
        Text(_cancelRecording ? 'משחררים לביטול' : '‹ החליקו הצידה לביטול', style: TextStyle(color: cs.onSurfaceVariant)),
      ]),
    );
  }
}

// ---------------- small widgets ----------------

class _Wallpaper extends StatelessWidget {
  const _Wallpaper({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final p = ChatPalette(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [p.wallpaperA, p.wallpaperB]),
      ),
      child: CustomPaint(painter: _DotsPainter(p.dark), child: child),
    );
  }
}

class _DotsPainter extends CustomPainter {
  _DotsPainter(this.dark);
  final bool dark;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = (dark ? Colors.white : const Color(0xFF1E3A8A)).withValues(alpha: dark ? 0.035 : 0.045);
    const step = 26.0;
    for (var y = 8.0; y < size.height; y += step) {
      final off = ((y / step).floor().isEven) ? 0.0 : step / 2;
      for (var x = 8.0 + off; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 1.4, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.dark != dark;
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.online});
  final String? name;
  final bool online;
  @override
  Widget build(BuildContext context) {
    final letter = (name == null || name!.isEmpty) ? null : name!.characters.first;
    return Stack(clipBehavior: Clip.none, children: [
      Container(
        width: 42,
        height: 42,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: [Color(0xFF3B82F6), Color(0xFF8B5CF6)]),
        ),
        alignment: Alignment.center,
        child: letter == null
            ? const Icon(Icons.flight_rounded, color: Colors.white)
            : Text(letter, style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700)),
      ),
      PositionedDirectional(
        bottom: 0,
        start: 0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 13,
          height: 13,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: online ? const Color(0xFF22C55E) : const Color(0xFF9CA3AF),
            border: Border.all(color: Theme.of(context).appBarTheme.backgroundColor ?? Colors.white, width: 2),
          ),
        ),
      ),
    ]);
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color});
  final Color color;
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();
  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _a,
        builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < 3; i++)
            Container(
              margin: const EdgeInsets.only(left: 2, right: 1, top: 4),
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: 0.3 + 0.7 * ((sin((_a.value * 2 * pi) - i * 0.9) + 1) / 2)),
              ),
            ),
        ]),
      );
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.color});
  final Color color;
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.3, end: 1.0).animate(_a),
        child: Icon(Icons.fiber_manual_record, color: widget.color, size: 14),
      );
}

class _DayChip extends StatelessWidget {
  const _DayChip({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    final p = ChatPalette(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: p.theirs.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4)],
        ),
        child: Text(label, style: TextStyle(fontSize: 12.5, color: p.onTheirs.withValues(alpha: 0.75), fontWeight: FontWeight.w500)),
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.visible, required this.pending, required this.isHost});
  final bool visible;
  final int pending;
  final bool isHost;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = pending > 0
        ? 'אין חיבור כרגע. ${pending == 1 ? 'הודעה אחת ממתינה' : '$pending הודעות ממתינות'} ותישלח${pending == 1 ? '' : 'נה'} לבד כשהחיבור יחזור.'
        : (isHost ? 'הטלפון השני לא מחובר. החיבור יחזור לבד כשהוא יחזור לרשת.' : 'אין חיבור כרגע. מנסה להתחבר מחדש…');
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      child: !visible
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: cs.tertiaryContainer, borderRadius: BorderRadius.circular(16)),
              child: Row(children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onTertiaryContainer)),
                const SizedBox(width: 10),
                Expanded(child: Text(text, style: TextStyle(color: cs.onTertiaryContainer))),
              ]),
            ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.icon, required this.onTap, this.active = false});
  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: active ? const [Color(0xFFEF4444), Color(0xFFF97316)] : const [Color(0xFF3B82F6), Color(0xFF6366F1)]),
        boxShadow: [BoxShadow(color: const Color(0xFF3B82F6).withValues(alpha: 0.35), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 50, height: 50, child: Icon(icon, color: Colors.white)),
        ),
      ),
    );
  }
}

class _JoinHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(16)),
      child: Text(
        'כדי להתחבר: בהגדרות ה־Wi‑Fi מצטרפים לנקודה החמה של הטלפון השני (או לאותה רשת Wi‑Fi שהוא מחובר אליה), '
        'וחוזרים לכאן. האפליקציה מוצאת אותו לבד, בלי להקליד כתובת. אם נשאלים על גישה ל"רשת מקומית", מאשרים.',
        style: TextStyle(color: cs.onSecondaryContainer),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.isHost, required this.group, required this.connected, required this.searching,
      required this.mode, this.check});
  final String mode;
  final NetCheck? check;
  final bool isHost;
  final GroupInfo? group;
  final bool connected;
  final bool searching;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (searching) {
      return Center(child: Text('לא נמצאו הודעות', style: TextStyle(color: cs.onSurfaceVariant)));
    }
    if (isHost && !connected && mode != kModeDirect) {
      return ListView(padding: const EdgeInsets.all(16), children: [HotspotCard(check: check)]);
    }
    if (isHost && group != null && !connected) {
      return ListView(padding: const EdgeInsets.all(16), children: [NetworkCard(info: group!, compact: true)]);
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(shape: BoxShape.circle, color: cs.primaryContainer.withValues(alpha: 0.6)),
            child: Icon(Icons.flight_takeoff_rounded, size: 42, color: cs.primary),
          ),
          const SizedBox(height: 14),
          Text(connected ? 'מחוברים. אפשר לכתוב ✈️' : 'עוד אין הודעות',
              style: TextStyle(fontSize: 17, color: cs.onSurfaceVariant)),
          if (connected) ...[
            const SizedBox(height: 6),
            Text('טיפ: ⚡ לתשובות מהירות, לחיצה ארוכה על הודעה לתגובות', textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          ],
        ]),
      ),
    );
  }
}

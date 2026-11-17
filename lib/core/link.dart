// Transport: one TCP connection between host (Android, ServerSocket) and
// client (iPhone / second phone), with acks, resend of unacked messages after
// reconnect, heartbeat-based dead-link detection, and client auto-reconnect.
import 'dart:async';
import 'dart:io';

import 'protocol.dart';

/// A byte pipe to the peer: a TCP socket, or a Nearby Connections link
/// (Bluetooth / BLE, added in v4). Frames are the same on every pipe.
abstract class LinkPipe {
  /// Raw incoming bytes, in order. Completes when the pipe closes.
  Stream<List<int>> get input;
  void write(List<int> bytes);
  void close();

  /// Human label for the UI / logs ('wifi', 'nearby').
  String get kind;

  /// Peer address for TCP pipes (cached as lastHost), null otherwise.
  String? get remoteHost;

  /// Silence after which the link is considered dead. Slow pipes need more.
  Duration? get deadAfter => null;
}

class SocketPipe implements LinkPipe {
  SocketPipe(this.socket) {
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
  }
  final Socket socket;
  @override
  Stream<List<int>> get input => socket;
  @override
  void write(List<int> bytes) => socket.add(bytes);
  @override
  void close() => socket.destroy();
  @override
  String get kind => 'wifi';
  @override
  String? get remoteHost {
    try {
      return socket.remoteAddress.address;
    } catch (_) {
      return null;
    }
  }

  @override
  Duration? get deadAfter => null;
}

enum LinkRole { host, client }

enum LinkState { stopped, waiting, connecting, connected }

class ChatLink {
  ChatLink({
    required this.role,
    this.host = kDefaultHostIp,
    this.port = kDefaultPort,
    this.bindAddress,
    required this.deviceName,
    required this.deviceId,
    this.heartbeat = const Duration(seconds: 4),
    this.deadAfter = const Duration(seconds: 14),
    this.retryDelay = const Duration(seconds: 2),
    this.connectTimeout = const Duration(seconds: 5),
    this.finder,
  });

  /// Client: custom way to reach the host (discovery on any shared network).
  /// Returns a connected socket or null. When null is set, connects to [host].
  final Future<Socket?> Function()? finder;

  /// Address of the peer of the current/last TCP connection.
  String? connectedHost;

  /// Kind of the active pipe ('wifi' / 'nearby'), null when offline.
  String? get activeKind => _socket?.kind;
  int failedAttempts = 0;

  final LinkRole role;
  final String host;
  final int port;
  final InternetAddress? bindAddress;
  final String deviceName;
  final String deviceId;
  final Duration heartbeat;
  final Duration deadAfter;
  final Duration retryDelay;
  final Duration connectTimeout;

  final _state = StreamController<LinkState>.broadcast();
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _acks = StreamController<String>.broadcast();
  final _peers = StreamController<String>.broadcast();
  final _others = StreamController<Map<String, dynamic>>.broadcast();

  /// Ephemeral frames that are not acked or queued (typing, status).
  Stream<Map<String, dynamic>> get others => _others.stream;

  /// Connection state changes.
  Stream<LinkState> get states => _state.stream;

  /// Incoming 'msg' and 'evt' frames (already acked automatically).
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// Ids of our messages that the peer confirmed.
  Stream<String> get acks => _acks.stream;

  /// Peer device name from its hello frame.
  Stream<String> get peerNames => _peers.stream;

  LinkState state = LinkState.stopped;
  String? peerName;
  int? boundPort;

  ServerSocket? _server;
  LinkPipe? _socket; // active pipe: all writes go here
  /// Live pipes that are not active (e.g. Bluetooth while Wi‑Fi is up).
  /// Frames from them are still accepted; one is promoted if the active dies.
  final List<LinkPipe> _standby = [];
  final Map<LinkPipe, FrameDecoder> _decoders = {};
  Timer? _hbTimer;
  DateTime _lastRx = DateTime.now();
  bool _running = false;

  /// Unacked outgoing frames, in send order. Resent after every reconnect.
  final Map<String, Map<String, dynamic>> _outbox = {};

  int get pendingCount => _outbox.length;

  void _setState(LinkState s) {
    if (state == s) return;
    state = s;
    if (!_state.isClosed) _state.add(s);
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    if (role == LinkRole.host) {
      _server = await ServerSocket.bind(
          bindAddress ?? InternetAddress.anyIPv4, port,
          shared: true);
      boundPort = _server!.port;
      _setState(LinkState.waiting);
      _server!.listen((s) => _adopt(SocketPipe(s)), onError: (_) {});
    } else {
      unawaited(_clientLoop());
    }
  }

  Future<void> _clientLoop() async {
    while (_running) {
      if (_socket == null || (_socket!.kind != 'wifi' && wifiWhileOtherPipe)) {
        _setState(LinkState.connecting);
        try {
          final s = finder != null
              ? await finder!()
              : await Socket.connect(host, port, timeout: connectTimeout);
          if (s == null) throw const SocketException('host not found');
          if (!_running) {
            s.destroy();
            break;
          }
          failedAttempts = 0;
          _adopt(SocketPipe(s));
        } catch (_) {
          failedAttempts++;
          if (_socket == null) _setState(LinkState.waiting);
        }
      }
      await Future.delayed(_socket == null ? retryDelay : retryDelay * 4);
    }
  }

  /// Client: keep looking for a Wi‑Fi path while connected over another
  /// pipe (Bluetooth), since Wi‑Fi is much faster.
  bool wifiWhileOtherPipe = true;

  /// Adopt an externally established pipe (Nearby Connections).
  void adoptPipe(LinkPipe p) {
    if (!_running) {
      p.close();
      return;
    }
    if (_socket != null && _socket!.kind == 'wifi' && p.kind != 'wifi') {
      // Keep the faster Wi‑Fi active, hold Bluetooth as a standby path.
      _listenPipe(p);
      _standby.add(p);
      _writeTo(p, helloFrame(deviceName, deviceId));
      return;
    }
    _adopt(p);
  }

  /// The Nearby pipe [p] closed from the native side.
  void pipeClosed(LinkPipe p) => _onClosed(p);

  void _adopt(LinkPipe s) {
    final old = _socket;
    if (old != null) {
      if (old.kind != 'wifi' && s.kind == 'wifi') {
        // Faster path arrived: demote Bluetooth to standby, don't close it.
        _socket = null;
        _standby.add(old);
      } else {
        // Host: a new connection replaces the old one (phone rejoined Wi‑Fi).
        _dropSocket(notify: false);
      }
    }
    _standby.remove(s);
    _socket = s;
    if (s.remoteHost != null) connectedHost = s.remoteHost;
    _lastRx = DateTime.now();
    _setState(LinkState.connected);
    if (!_decoders.containsKey(s)) _listenPipe(s);
    _write(helloFrame(deviceName, deviceId));
    for (final f in _outbox.values.toList()) {
      _write(f);
    }
    _hbTimer?.cancel();
    _hbTimer = Timer.periodic(heartbeat, (_) {
      if (_socket != s) return;
      if (DateTime.now().difference(_lastRx) > (s.deadAfter ?? deadAfter)) {
        _onClosed(s);
        return;
      }
      _write(pingFrame());
    });
  }

  void _listenPipe(LinkPipe s) {
    _decoders[s] = FrameDecoder();
    s.input.listen(
      (chunk) => _onData(s, chunk),
      onError: (_) => _onClosed(s),
      onDone: () => _onClosed(s),
      cancelOnError: true,
    );
  }

  void _onData(LinkPipe s, List<int> chunk) {
    final dec = _decoders[s];
    if (dec == null) return;
    if (_socket == s) _lastRx = DateTime.now();
    List<Map<String, dynamic>> frames;
    try {
      frames = dec.add(chunk);
    } catch (_) {
      _onClosed(s);
      return;
    }
    for (final f in frames) {
      switch (f['t']) {
        case 'hello':
          peerName = f['name'] as String?;
          if (peerName != null) _peers.add(peerName!);
          break;
        case 'msg':
        case 'evt':
          final id = f['id'];
          if (id is String) {
            if (!_write(ackFrame(id))) _writeTo(s, ackFrame(id));
            _messages.add(f);
          }
          break;
        case 'ack':
          final id = f['id'];
          if (id is String && _outbox.remove(id) != null) _acks.add(id);
          break;
        case 'ping':
          _writeTo(s, pongFrame());
          break;
        case 'pong':
          break;
        default:
          // Ephemeral frames (typing, status) and future types.
          if (!_others.isClosed) _others.add(f);
          break;
      }
    }
  }

  void _onClosed(LinkPipe s) {
    if (_standby.remove(s)) {
      _decoders.remove(s);
      s.close();
      return;
    }
    if (_socket != s) return;
    _dropSocket(notify: true);
  }

  void _dropSocket({required bool notify}) {
    _hbTimer?.cancel();
    _hbTimer = null;
    final old = _socket;
    _socket = null;
    if (old != null) {
      _decoders.remove(old);
      old.close();
    }
    // Fall back to a standby pipe (Bluetooth) if one is still alive.
    if (notify && _running && _standby.isNotEmpty) {
      _adopt(_standby.removeLast());
      return;
    }
    if (notify && _running) {
      _setState(role == LinkRole.host ? LinkState.waiting : LinkState.connecting);
    }
  }

  bool _writeTo(LinkPipe p, Map<String, dynamic> f) {
    try {
      p.write(encodeFrame(f));
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _write(Map<String, dynamic> f) {
    final s = _socket;
    if (s == null) return false;
    return _writeTo(s, f);
  }

  /// Queue a 'msg' frame. Returns true if it was written to a live socket now.
  bool send(Map<String, dynamic> msg) {
    final id = msg['id'] as String;
    _outbox[id] = msg;
    return _write(msg);
  }

  /// Fire-and-forget frame (typing, status). Dropped when offline.
  bool sendEphemeral(Map<String, dynamic> f) => _write(f);

  /// Test hook: abruptly kill the current socket as if Wi‑Fi dropped.
  void debugKillSocket() {
    final s = _socket;
    if (s is SocketPipe) s.socket.destroy();
  }

  Future<void> stop() async {
    _running = false;
    _dropSocket(notify: false);
    for (final p in _standby) {
      p.close();
    }
    _standby.clear();
    _decoders.clear();
    await _server?.close();
    _server = null;
    _setState(LinkState.stopped);
  }

  Future<void> dispose() async {
    await stop();
    await _state.close();
    await _messages.close();
    await _acks.close();
    await _peers.close();
    await _others.close();
  }
}

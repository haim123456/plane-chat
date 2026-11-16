// Transport: one TCP connection between host (Android, ServerSocket) and
// client (iPhone / second phone), with acks, resend of unacked messages after
// reconnect, heartbeat-based dead-link detection, and client auto-reconnect.
import 'dart:async';
import 'dart:io';

import 'protocol.dart';

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
  });

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

  /// Connection state changes.
  Stream<LinkState> get states => _state.stream;

  /// Incoming 'msg' frames (already acked automatically).
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// Ids of our messages that the peer confirmed.
  Stream<String> get acks => _acks.stream;

  /// Peer device name from its hello frame.
  Stream<String> get peerNames => _peers.stream;

  LinkState state = LinkState.stopped;
  String? peerName;
  int? boundPort;

  ServerSocket? _server;
  Socket? _socket;
  FrameDecoder? _decoder;
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
      _server!.listen(_adopt, onError: (_) {});
    } else {
      unawaited(_clientLoop());
    }
  }

  Future<void> _clientLoop() async {
    while (_running) {
      if (_socket == null) {
        _setState(LinkState.connecting);
        try {
          final s = await Socket.connect(host, port, timeout: connectTimeout);
          if (!_running) {
            s.destroy();
            break;
          }
          _adopt(s);
        } catch (_) {
          _setState(LinkState.waiting);
        }
      }
      await Future.delayed(retryDelay);
    }
  }

  void _adopt(Socket s) {
    // Host: a new connection replaces the old one (e.g. phone rejoined Wi-Fi).
    _dropSocket(notify: false);
    s.setOption(SocketOption.tcpNoDelay, true);
    _socket = s;
    _decoder = FrameDecoder();
    _lastRx = DateTime.now();
    _setState(LinkState.connected);
    s.listen(
      (chunk) => _onData(s, chunk),
      onError: (_) => _onClosed(s),
      onDone: () => _onClosed(s),
      cancelOnError: true,
    );
    _write(helloFrame(deviceName, deviceId));
    for (final f in _outbox.values.toList()) {
      _write(f);
    }
    _hbTimer?.cancel();
    _hbTimer = Timer.periodic(heartbeat, (_) {
      if (_socket != s) return;
      if (DateTime.now().difference(_lastRx) > deadAfter) {
        _onClosed(s);
        return;
      }
      _write(pingFrame());
    });
  }

  void _onData(Socket s, List<int> chunk) {
    if (_socket != s) return;
    _lastRx = DateTime.now();
    List<Map<String, dynamic>> frames;
    try {
      frames = _decoder!.add(chunk);
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
          final id = f['id'];
          if (id is String) {
            _write(ackFrame(id));
            _messages.add(f);
          }
          break;
        case 'ack':
          final id = f['id'];
          if (id is String && _outbox.remove(id) != null) _acks.add(id);
          break;
        case 'ping':
          _write(pongFrame());
          break;
        default:
          break;
      }
    }
  }

  void _onClosed(Socket s) {
    if (_socket != s) return;
    _dropSocket(notify: true);
  }

  void _dropSocket({required bool notify}) {
    _hbTimer?.cancel();
    _hbTimer = null;
    final old = _socket;
    _socket = null;
    _decoder = null;
    old?.destroy();
    if (notify && _running) {
      _setState(role == LinkRole.host ? LinkState.waiting : LinkState.connecting);
    }
  }

  bool _write(Map<String, dynamic> f) {
    final s = _socket;
    if (s == null) return false;
    try {
      s.add(encodeFrame(f));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Queue a 'msg' frame. Returns true if it was written to a live socket now.
  bool send(Map<String, dynamic> msg) {
    final id = msg['id'] as String;
    _outbox[id] = msg;
    return _write(msg);
  }

  /// Test hook: abruptly kill the current socket as if Wi-Fi dropped.
  void debugKillSocket() => _socket?.destroy();

  Future<void> stop() async {
    _running = false;
    _dropSocket(notify: false);
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
  }
}

// v4: automatic Bluetooth link via Google Nearby Connections.
// Android: play-services-nearby (MainActivity.kt). iOS: Swift package
// google/nearby (NearbyBridge.swift). Both phones advertise AND discover the
// same service id; whoever has the smaller device id requests the connection
// (the other one too, after a grace period), both auto-accept, and the
// resulting link is handed to ChatLink as a LinkPipe. Nothing to set up.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../core/link.dart';

const String kNearbyServiceId = 'il.planechat.plane_chat';

/// Nearby BYTES payloads are limited to 32 KB; we use 30000 incl. header.
const int kNearbyChunk = 30000;

/// Splits a byte stream into numbered chunks and puts them back in order.
class ChunkSequencer {
  int _txSeq = 0;
  int _rxNext = 0;
  final Map<int, Uint8List> _held = {};

  List<Uint8List> split(List<int> bytes) {
    final out = <Uint8List>[];
    for (var off = 0; off < bytes.length; off += kNearbyChunk - 4) {
      final end = (off + kNearbyChunk - 4).clamp(0, bytes.length);
      final c = Uint8List(4 + end - off);
      ByteData.view(c.buffer).setUint32(0, _txSeq++, Endian.big);
      c.setRange(4, c.length, bytes, off);
      out.add(c);
    }
    return out;
  }

  /// Returns the payload bytes that are now in order (possibly several).
  List<Uint8List> receive(Uint8List chunk) {
    if (chunk.length < 4) return const [];
    final seq = ByteData.view(chunk.buffer, chunk.offsetInBytes, 4).getUint32(0, Endian.big);
    _held[seq] = Uint8List.sublistView(chunk, 4);
    final out = <Uint8List>[];
    while (_held.containsKey(_rxNext)) {
      out.add(_held.remove(_rxNext++)!);
    }
    return out;
  }
}

class NearbyPipe implements LinkPipe {
  NearbyPipe(this.endpointId, this._send, this._disconnect);
  final String endpointId;
  final Future<void> Function(String id, Uint8List bytes) _send;
  final Future<void> Function(String id) _disconnect;
  final _in = StreamController<List<int>>();
  final _seq = ChunkSequencer();
  bool closed = false;

  void deliver(Uint8List chunk) {
    if (closed) return;
    for (final b in _seq.receive(chunk)) {
      _in.add(b);
    }
  }

  void remoteClosed() {
    if (closed) return;
    closed = true;
    _in.close();
  }

  @override
  Stream<List<int>> get input => _in.stream;

  @override
  void write(List<int> bytes) {
    if (closed) throw const SocketException('nearby link closed');
    for (final c in _seq.split(bytes)) {
      _send(endpointId, c).catchError((_) {});
    }
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    _in.close();
    _disconnect(endpointId).catchError((_) {});
  }

  @override
  String get kind => 'nearby';
  @override
  String? get remoteHost => null;
  // Bluetooth is slow: a large photo can keep the pipe busy for a while.
  @override
  Duration? get deadAfter => const Duration(seconds: 45);
}

/// Status for the UI (Hebrew text is built in the UI layer).
enum NearbyPhase { off, unsupported, noPermission, error, searching, connecting, connected }

class NearbyService {
  NearbyService({required this.deviceName, required this.deviceId});
  final String deviceName;
  final String deviceId;

  static const _ch = MethodChannel('planechat/nearby');

  NearbyPhase phase = NearbyPhase.off;
  String? lastError;
  String? peerLabel;
  final _phases = StreamController<NearbyPhase>.broadcast();
  Stream<NearbyPhase> get phases => _phases.stream;

  void Function(NearbyPipe pipe)? onPipe;
  void Function(NearbyPipe pipe)? onPipeClosed;

  NearbyPipe? _pipe;
  final Map<String, String> _found = {}; // endpointId -> peer device id
  final Set<String> _requested = {};
  Timer? _graceTimer;
  bool _running = false;

  String get _info => 'PC1|$deviceId|${deviceName.replaceAll('|', ' ')}';

  void _set(NearbyPhase p) {
    phase = p;
    if (!_phases.isClosed) _phases.add(p);
  }

  static bool get supported => Platform.isAndroid || Platform.isIOS;

  Future<void> start() async {
    if (_running) return;
    if (!supported) {
      _set(NearbyPhase.unsupported);
      return;
    }
    _running = true;
    _ch.setMethodCallHandler(_onNative);
    await _begin();
  }

  Future<void> _begin() async {
    if (!_running) return;
    try {
      await _ch.invokeMethod('start', {'serviceId': kNearbyServiceId, 'info': _info});
      lastError = null;
      _set(NearbyPhase.searching);
    } on PlatformException catch (e) {
      lastError = '${e.code}: ${e.message ?? ''}';
      _set(e.code == 'permission' ? NearbyPhase.noPermission : NearbyPhase.error);
      // Retry later (Bluetooth may be turned on, permission granted).
      Future.delayed(const Duration(seconds: 15), () {
        if (_running && _pipe == null && phase != NearbyPhase.searching) _begin();
      });
    } on MissingPluginException {
      _set(NearbyPhase.unsupported);
    }
  }

  Future<void> stop() async {
    _running = false;
    _graceTimer?.cancel();
    final p = _pipe;
    _pipe = null;
    p?.remoteClosed();
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
    _found.clear();
    _requested.clear();
    _set(NearbyPhase.off);
  }

  Future<void> _send(String id, Uint8List b) =>
      _ch.invokeMethod('send', {'id': id, 'bytes': b});
  Future<void> _disconnect(String id) async {
    if (_pipe?.endpointId == id) {
      _pipe = null;
      _requested.remove(id);
      if (_running) _set(NearbyPhase.searching);
    }
    await _ch.invokeMethod('disconnect', {'id': id});
  }

  Future<void> _request(String endpointId) async {
    if (_requested.contains(endpointId) || _pipe != null) return;
    _requested.add(endpointId);
    _set(NearbyPhase.connecting);
    try {
      await _ch.invokeMethod('connect', {'id': endpointId, 'info': _info});
    } on PlatformException catch (e) {
      lastError = '${e.code}: ${e.message ?? ''}';
      _requested.remove(endpointId);
      if (_pipe == null) _set(NearbyPhase.searching);
    }
  }

  Future<dynamic> _onNative(MethodCall call) async {
    final a = (call.arguments as Map?) ?? const {};
    final id = a['id'] as String?;
    switch (call.method) {
      case 'found':
        final info = (a['info'] as String?) ?? '';
        final parts = info.split('|');
        if (id == null || parts.length < 2 || parts[0] != 'PC1') return null;
        final peer = parts[1];
        if (peer == deviceId) return null;
        _found[id] = peer;
        peerLabel = parts.length > 2 ? parts[2] : null;
        if (_pipe != null) return null;
        if (deviceId.compareTo(peer) < 0) {
          await _request(id);
        } else {
          // The other phone should call us; if it doesn't within a few
          // seconds (e.g. it can't scan), we call it ourselves.
          _graceTimer?.cancel();
          _graceTimer = Timer(const Duration(seconds: 6), () {
            if (_pipe == null && _found.containsKey(id)) _request(id);
          });
        }
        break;
      case 'lost':
        if (id != null) {
          _found.remove(id);
          _requested.remove(id);
        }
        break;
      case 'initiated':
        _set(NearbyPhase.connecting);
        break;
      case 'connected':
        if (id == null) return null;
        _graceTimer?.cancel();
        if (_pipe != null && _pipe!.endpointId != id) {
          // Two links to the same phone (both requested at once): keep one.
          _disconnect(id).catchError((_) {});
          return null;
        }
        final p = NearbyPipe(id, _send, _disconnect);
        _pipe = p;
        _set(NearbyPhase.connected);
        onPipe?.call(p);
        break;
      case 'rejected':
        if (id != null) _requested.remove(id);
        lastError = a['reason'] as String?;
        if (_pipe == null) _set(NearbyPhase.searching);
        break;
      case 'disconnected':
        if (id != null) _requested.remove(id);
        final p = _pipe;
        if (p != null && p.endpointId == id) {
          _pipe = null;
          p.remoteClosed();
          onPipeClosed?.call(p);
          _set(NearbyPhase.searching);
          // Native side restarts advertising/discovery on disconnect.
        }
        break;
      case 'data':
        final b = a['bytes'];
        final p = _pipe;
        if (p != null && p.endpointId == id && b is Uint8List) p.deliver(b);
        break;
      case 'error':
        lastError = a['message'] as String?;
        if (_pipe == null) _set(NearbyPhase.error);
        break;
    }
    return null;
  }
}

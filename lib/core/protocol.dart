// Wire protocol for צ'אט טיסה.
//
// Every frame is: 4-byte big-endian payload length, then a UTF-8 JSON object.
// Binary media travels base64-encoded inside the JSON ("data").
// Frame types ("t"): hello, msg, ack, ping, pong.
import 'dart:convert';
import 'dart:typed_data';

const int kProtocolVersion = 1;
const int kDefaultPort = 47474;
const String kDefaultHostIp = '192.168.49.1'; // Android Wi-Fi Direct group owner
const int kMaxFrameBytes = 16 * 1024 * 1024;

class ProtocolException implements Exception {
  final String message;
  ProtocolException(this.message);
  @override
  String toString() => 'ProtocolException: $message';
}

Uint8List encodeFrame(Map<String, dynamic> json) {
  final body = utf8.encode(jsonEncode(json));
  if (body.length > kMaxFrameBytes) {
    throw ProtocolException('frame too large: ${body.length}');
  }
  final out = Uint8List(4 + body.length);
  ByteData.view(out.buffer).setUint32(0, body.length, Endian.big);
  out.setRange(4, out.length, body);
  return out;
}

/// Incremental decoder: feed arbitrary chunks, get complete frames back.
class FrameDecoder {
  final BytesBuilder _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  List<Map<String, dynamic>> add(List<int> chunk) {
    if (_pending.isNotEmpty) _buf.add(_pending);
    _buf.add(chunk);
    var data = _buf.takeBytes();
    final frames = <Map<String, dynamic>>[];
    var off = 0;
    while (data.length - off >= 4) {
      final len = ByteData.view(data.buffer, data.offsetInBytes + off, 4)
          .getUint32(0, Endian.big);
      if (len > kMaxFrameBytes) {
        throw ProtocolException('declared frame too large: $len');
      }
      if (data.length - off - 4 < len) break;
      final body = Uint8List.sublistView(data, off + 4, off + 4 + len);
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is! Map<String, dynamic>) {
        throw ProtocolException('frame is not a JSON object');
      }
      frames.add(decoded);
      off += 4 + len;
    }
    _pending = Uint8List.fromList(Uint8List.sublistView(data, off));
    return frames;
  }

  int get bufferedBytes => _pending.length;
}

enum MsgKind { text, image, voice }

MsgKind parseKind(String? s) =>
    MsgKind.values.firstWhere((k) => k.name == s, orElse: () => MsgKind.text);

/// Builders for each frame type.
Map<String, dynamic> helloFrame(String deviceName, String deviceId) => {
      't': 'hello',
      'v': kProtocolVersion,
      'name': deviceName,
      'device': deviceId,
    };

Map<String, dynamic> msgFrame({
  required String id,
  required MsgKind kind,
  required int ts,
  String? text,
  List<int>? data,
  int? durationMs,
  String? sender,
}) =>
    {
      't': 'msg',
      'id': id,
      'kind': kind.name,
      'ts': ts,
      if (text != null) 'text': text,
      if (data != null) 'data': base64Encode(data),
      if (durationMs != null) 'dur': durationMs,
      if (sender != null) 'from': sender,
    };

Map<String, dynamic> ackFrame(String id) => {'t': 'ack', 'id': id};
Map<String, dynamic> pingFrame() => {'t': 'ping'};
Map<String, dynamic> pongFrame() => {'t': 'pong'};

Uint8List? frameData(Map<String, dynamic> f) {
  final d = f['data'];
  if (d is! String) return null;
  return base64Decode(d);
}

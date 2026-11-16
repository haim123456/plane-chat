// End-to-end check against a running app (e.g. emulator via `adb forward`).
// Usage: dart run tool/e2e_client.dart [host] [port]
import 'dart:async';
import 'dart:io';

import 'package:plane_chat/core/link.dart';
import 'package:plane_chat/core/protocol.dart';

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '127.0.0.1';
  final port = args.length > 1 ? int.parse(args[1]) : kDefaultPort;
  final link = ChatLink(role: LinkRole.client, host: host, port: port, deviceName: 'בודק', deviceId: 'e2e');
  final acked = <String>{};
  final got = <Map<String, dynamic>>[];
  link.acks.listen(acked.add);
  link.messages.listen(got.add);
  await link.start();
  final sw = Stopwatch()..start();
  while (link.state != LinkState.connected && sw.elapsed.inSeconds < 20) {
    await Future.delayed(const Duration(milliseconds: 100));
  }
  print('state=${link.state} after ${sw.elapsedMilliseconds}ms');
  final now = DateTime.now().millisecondsSinceEpoch;
  final img = File(args.length > 2 ? args[2] : '/tmp/planechat_icon.png').readAsBytesSync();
  link.send(msgFrame(id: 'e2e-text-$now', kind: MsgKind.text, ts: now, text: 'שלום מהבדיקה ✈️'));
  link.send(msgFrame(id: 'e2e-img-$now', kind: MsgKind.image, ts: now + 1, data: img, text: 'תמונה'));
  final voice = args.length > 3 ? File(args[3]).readAsBytesSync() : List.filled(1000, 0);
  link.send(msgFrame(id: 'e2e-voice-$now', kind: MsgKind.voice, ts: now + 2, data: voice, durationMs: 3000));
  sw.reset();
  while (acked.length < 3 && sw.elapsed.inSeconds < 15) {
    await Future.delayed(const Duration(milliseconds: 100));
  }
  print('acked=${acked.length}/3 in ${sw.elapsedMilliseconds}ms peer=${link.peerName}');
  print('waiting 25s for messages typed on the device...');
  await Future.delayed(Duration(seconds: args.length > 4 ? int.parse(args[4]) : 25));
  for (final m in got) {
    print('received kind=${m['kind']} text=${m['text']} bytes=${frameData(m)?.length}');
  }
  await link.dispose();
  exit(acked.length == 3 ? 0 : 1);
}

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
  final others = <Map<String, dynamic>>[];
  link.others.listen(others.add);
  // v2: status, typing, reply, reaction, nudge
  link.sendEphemeral(statusFrame(battery: 17, charging: false, seat: '31F'));
  link.sendEphemeral(typingFrame(true));
  await Future.delayed(const Duration(seconds: 2));
  link.send(msgFrame(id: 'e2e-reply-$now', kind: MsgKind.text, ts: now + 3, text: 'כן, פסטה',
      replyTo: 'e2e-text-$now', replyPreview: 'שלום מהבדיקה ✈️', replyKind: 'text'));
  link.send(evtFrame(id: 'e2e-react-$now', ev: 'react', target: 'e2e-text-$now', emoji: '❤️'));
  link.send(evtFrame(id: 'e2e-nudge-$now', ev: 'nudge', ts: DateTime.now().millisecondsSinceEpoch));
  sw.reset();
  while (acked.length < 6 && sw.elapsed.inSeconds < 10) {
    await Future.delayed(const Duration(milliseconds: 100));
  }
  print('v2 acked=${acked.length}/6');
  print('waiting 25s for messages typed on the device...');
  await Future.delayed(Duration(seconds: args.length > 4 ? int.parse(args[4]) : 25));
  for (final o in others) {
    print('ephemeral ${o['t']}: $o');
  }
  for (final m in got) {
    print('received ${m['t']} kind=${m['kind']} ev=${m['ev']} text=${m['text']} reply=${m['replyText']} emoji=${m['emoji']} bytes=${frameData(m)?.length}');
  }
  await link.dispose();
  exit(acked.length == 6 ? 0 : 1);
}

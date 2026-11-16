// Two full app cores (controller + link + store) talking over real TCP on
// 127.0.0.1: host plays the Android phone, client plays the iPhone.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plane_chat/core/chat_controller.dart';
import 'package:plane_chat/core/link.dart';
import 'package:plane_chat/core/store.dart';

Future<void> waitFor(bool Function() cond, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future.delayed(const Duration(milliseconds: 50));
  }
}

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('planechat'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<ChatController> mk(String name) async {
    final c = ChatController(ChatStore(Directory('${tmp.path}/$name')));
    await c.init();
    await c.updateSettings({'name': name});
    return c;
  }

  test('text, image, voice both ways with delivered ticks; history persists', () async {
    final port = await freePort();
    final host = await mk('android');
    final client = await mk('iphone');
    await host.startLink(role: LinkRole.host, port: port, bindAddress: InternetAddress.loopbackIPv4);
    await client.startLink(role: LinkRole.client, host: '127.0.0.1', port: port);
    await waitFor(() => host.linkState == LinkState.connected && client.linkState == LinkState.connected);
    await waitFor(() => host.peerName == 'iphone' && client.peerName == 'android');

    final t = (await client.sendText('שלום מהשורה 12'))!;
    final img = Uint8List.fromList(List.generate(250 * 1024, (i) => i % 251));
    final im = await host.sendImage(img, caption: 'נוף');
    final vc = await client.sendVoice(List.filled(90 * 1024, 7), 30000);

    await waitFor(() => host.messages.length == 3 && client.messages.length == 3);
    await waitFor(() => [t, im, vc].every((m) => m.status == MsgStatus.delivered));

    final gotImg = client.messages.firstWhere((m) => m.id == im.id);
    expect(gotImg.text, 'נוף');
    expect(await File(gotImg.mediaPath!).readAsBytes(), img);
    final gotVoice = host.messages.firstWhere((m) => m.id == vc.id);
    expect(gotVoice.durationMs, 30000);
    expect(host.messages.firstWhere((m) => m.id == t.id).text, 'שלום מהשורה 12');

    await host.stopLink();
    await client.stopLink();
    // reload from disk
    final again = ChatController(ChatStore(Directory('${tmp.path}/iphone')));
    await again.init();
    expect(again.messages.map((m) => m.id).toSet(), {t.id, im.id, vc.id});
    expect(again.messages.firstWhere((m) => m.id == t.id).status, MsgStatus.delivered);
  });

  test('client auto-reconnects after link drop and queued messages arrive once', () async {
    final port = await freePort();
    final host = await mk('android');
    final client = await mk('iphone');
    await host.startLink(role: LinkRole.host, port: port, bindAddress: InternetAddress.loopbackIPv4);
    await client.startLink(role: LinkRole.client, host: '127.0.0.1', port: port);
    await waitFor(() => client.linkState == LinkState.connected);

    // Host goes away entirely (e.g. Wi-Fi Direct group restarted).
    await host.stopLink();
    await waitFor(() => client.linkState != LinkState.connected);
    final queued = (await client.sendText('נשלח כשאין קשר'))!;
    expect(queued.status, MsgStatus.pending);

    await host.startLink(role: LinkRole.host, port: port, bindAddress: InternetAddress.loopbackIPv4);
    await waitFor(() => client.linkState == LinkState.connected, timeout: const Duration(seconds: 30));
    await waitFor(() => queued.status == MsgStatus.delivered);
    expect(host.messages.where((m) => m.id == queued.id), hasLength(1));

    // Abrupt socket kill: resend must not duplicate.
    final m2 = (await client.sendText('עוד אחת'))!;
    client.link!.debugKillSocket();
    await waitFor(() => client.linkState == LinkState.connected && m2.status == MsgStatus.delivered,
        timeout: const Duration(seconds: 30));
    expect(host.messages.where((m) => m.id == m2.id), hasLength(1));
    await host.stopLink();
    await client.stopLink();
  });

  test('messages unacked before an app restart are resent on next start', () async {
    final port = await freePort();
    final client = await mk('iphone');
    await client.startLink(role: LinkRole.client, host: '127.0.0.1', port: port);
    final m = (await client.sendText('נכתב לפני שהמארח עלה'))!;
    await client.stopLink();
    // "restart" the app
    final client2 = ChatController(ChatStore(Directory('${tmp.path}/iphone')));
    await client2.init();
    final host = await mk('android');
    await host.startLink(role: LinkRole.host, port: port, bindAddress: InternetAddress.loopbackIPv4);
    await client2.startLink(role: LinkRole.client, host: '127.0.0.1', port: port);
    await waitFor(() => host.messages.any((x) => x.id == m.id));
    await waitFor(() => client2.messages.single.status == MsgStatus.delivered);
    await host.stopLink();
    await client2.stopLink();
  });
}

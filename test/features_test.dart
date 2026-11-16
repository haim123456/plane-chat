// v2 features over a real TCP loopback: reply/quote, reactions, nudge,
// typing indicator, battery/seat status, delete-for-me, search, export.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plane_chat/core/chat_controller.dart';
import 'package:plane_chat/core/link.dart';
import 'package:plane_chat/core/protocol.dart';
import 'package:plane_chat/core/store.dart';

Future<void> waitFor(bool Function() cond, {Duration timeout = const Duration(seconds: 15)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future.delayed(const Duration(milliseconds: 30));
  }
}

void main() {
  late Directory tmp;
  late ChatController host, client;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('planechat2');
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    Future<ChatController> mk(String name) async {
      final c = ChatController(ChatStore(Directory('${tmp.path}/$name')),
          typingTimeout: const Duration(milliseconds: 600));
      await c.init();
      await c.updateSettings({'name': name});
      return c;
    }

    host = await mk('אנדרואיד');
    client = await mk('אייפון');
    host.statusProvider = () async => const DeviceStatus(battery: 64, charging: false);
    client.statusProvider = () async => const DeviceStatus(battery: 15, charging: true);
    await host.startLink(role: LinkRole.host, port: port, bindAddress: InternetAddress.loopbackIPv4);
    await client.startLink(role: LinkRole.client, host: '127.0.0.1', port: port);
    await waitFor(() => host.linkState == LinkState.connected && client.linkState == LinkState.connected);
  });

  tearDown(() async {
    await host.stopLink();
    await client.stopLink();
    await host.store.flush();
    await client.store.flush();
    await tmp.delete(recursive: true);
  });

  test('reply carries a quote of the original', () async {
    final q = (await host.sendText('רוצה לאכול?'))!;
    await waitFor(() => client.messages.any((m) => m.id == q.id));
    final orig = client.byId(q.id)!;
    final r = (await client.sendText('כן, פסטה', replyTo: orig))!;
    await waitFor(() => host.byId(r.id) != null);
    final got = host.byId(r.id)!;
    expect(got.replyTo, q.id);
    expect(got.replyPreview, 'רוצה לאכול?');
    expect(got.replyKind, 'text');
  });

  test('reactions sync both ways and can be removed', () async {
    final m = (await client.sendText('נחתנו?'))!;
    await waitFor(() => host.byId(m.id) != null);
    String? seen;
    client.onReaction = (_, e) => seen = e;
    await host.react(host.byId(m.id)!, '❤️');
    await waitFor(() => client.byId(m.id)!.peerReaction == '❤️');
    expect(seen, '❤️');
    expect(host.byId(m.id)!.myReaction, '❤️');
    // same emoji again toggles it off
    await host.react(host.byId(m.id)!, '❤️');
    await waitFor(() => client.byId(m.id)!.peerReaction == null);
  });

  test('nudge buzzes the other side once and is rate-limited', () async {
    var buzz = 0;
    host.onNudge = () => buzz++;
    expect(client.nudge(), isTrue);
    expect(client.nudge(), isFalse);
    await waitFor(() => buzz == 1);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(buzz, 1);
  });

  test('typing indicator turns on, then off on send or timeout', () async {
    client.setTyping(true);
    await waitFor(() => host.peerTyping);
    await client.sendText('הנה');
    await waitFor(() => !host.peerTyping);
    client.setTyping(true);
    await waitFor(() => host.peerTyping);
    await waitFor(() => !host.peerTyping); // 600 ms timeout in this test
  });

  test('status shares battery, charging and seat', () async {
    await waitFor(() => host.peerBattery == 15 && client.peerBattery == 64);
    expect(host.peerCharging, isTrue);
    await client.setSeat('23c');
    await waitFor(() => host.peerSeat == '23C');
    expect(client.mySeat, '23C');
  });

  test('delete-for-me removes locally only and a resend does not bring it back', () async {
    final m = (await host.sendText('למחוק אצלי'))!;
    await waitFor(() => client.byId(m.id) != null);
    await client.deleteForMe(client.byId(m.id)!);
    expect(client.byId(m.id), isNull);
    expect(host.byId(m.id), isNotNull);
    // simulate the same frame arriving again
    host.link!.send(msgFrame(id: m.id, kind: MsgKind.text, ts: m.ts, text: m.text));
    await Future.delayed(const Duration(milliseconds: 300));
    expect(client.byId(m.id), isNull);
    // survives restart
    await client.stopLink();
    final again = ChatController(ChatStore(Directory('${tmp.path}/אייפון')));
    await again.init();
    expect(again.byId(m.id), isNull);
  });

  test('search and export', () async {
    await host.sendText('המושב שלי 23C');
    final m = (await host.sendText('שתייה?'))!;
    await waitFor(() => client.byId(m.id) != null);
    expect(client.search('מושב').length, 1);
    expect(client.search('  '), isEmpty);
    final txt = client.exportText();
    expect(txt, contains('אנדרואיד: שתייה?'));
    expect(txt, contains("צ'אט טיסה"));
  });

  test('old history files without the new fields still load', () async {
    final m = ChatMessage.fromJson({'id': 'x', 'kind': 'text', 'me': true, 'ts': 1, 'text': 'a', 'st': 'sent'});
    expect(m.replyTo, isNull);
    expect(m.myReaction, isNull);
    expect(m.preview, 'a');
  });
}

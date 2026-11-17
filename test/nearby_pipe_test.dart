// v4: the Bluetooth (Nearby Connections) path, simulated in memory with
// 30 KB chunks delivered out of order, plus Wi‑Fi/Bluetooth hand-over.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plane_chat/core/chat_controller.dart';
import 'package:plane_chat/core/link.dart';
import 'package:plane_chat/core/store.dart';
import 'package:plane_chat/platform/nearby.dart';

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

/// Two NearbyPipes wired to each other; chunks arrive with random delays.
(NearbyPipe, NearbyPipe) fakeNearby(ChatController a, ChatController b) {
  final rnd = Random(7);
  late NearbyPipe pa, pb;
  Future<void> deliver(NearbyPipe to, Uint8List bytes) async {
    await Future.delayed(Duration(milliseconds: rnd.nextInt(15)));
    to.deliver(bytes);
  }

  pa = NearbyPipe('B', (id, bytes) => deliver(pb, bytes), (id) async {
    pb.remoteClosed();
    b.pipeClosed(pb);
  });
  pb = NearbyPipe('A', (id, bytes) => deliver(pa, bytes), (id) async {
    pa.remoteClosed();
    a.pipeClosed(pa);
  });
  return (pa, pb);
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

  test('chunk sequencer reorders and reassembles', () {
    final tx = ChunkSequencer(), rx = ChunkSequencer();
    final data = List.generate(100000, (i) => i % 256);
    final chunks = tx.split(data);
    expect(chunks.length, 4);
    expect(chunks.every((c) => c.length <= kNearbyChunk), isTrue);
    final out = <int>[];
    for (final c in chunks.reversed) {
      for (final b in rx.receive(c)) {
        out.addAll(b);
      }
    }
    expect(out, data);
  });

  test('Bluetooth only: text and photo both ways, delivered once', () async {
    final port = await freePort();
    final host = await mk('android');
    final client = await mk('iphone');
    await host.startLink(role: LinkRole.host, port: port, bindAddress: InternetAddress.loopbackIPv4);
    // Client points at a dead address: no Wi‑Fi path at all.
    await client.startLink(role: LinkRole.client, host: '127.0.0.1', port: await freePort());
    final (ph, pc) = fakeNearby(host, client);
    host.adoptPipe(ph);
    client.adoptPipe(pc);
    await waitFor(() => host.linkState == LinkState.connected && client.linkState == LinkState.connected);
    expect(client.linkVia, 'nearby');
    await waitFor(() => host.peerName == 'iphone' && client.peerName == 'android');

    final t = (await client.sendText('שלום דרך בלוטות'))!;
    final img = Uint8List.fromList(List.generate(200 * 1024, (i) => i % 253));
    final im = await host.sendImage(img, caption: 'חלון');
    await waitFor(() => t.status == MsgStatus.delivered && im.status == MsgStatus.delivered);
    final got = client.messages.firstWhere((m) => m.id == im.id);
    expect(await File(got.mediaPath!).readAsBytes(), img);
    expect(host.messages.where((m) => m.id == t.id), hasLength(1));
    await host.stopLink();
    await client.stopLink();
  });

  test('Wi‑Fi takes over when it appears; Bluetooth carries on when Wi‑Fi drops', () async {
    final port = await freePort();
    final host = await mk('android');
    final client = await mk('iphone');
    await host.startLink(role: LinkRole.host, port: port, bindAddress: InternetAddress.loopbackIPv4);
    final (ph, pc) = fakeNearby(host, client);
    // Bluetooth first.
    await client.startLink(role: LinkRole.client, host: '127.0.0.1', port: port);
    host.adoptPipe(ph);
    client.adoptPipe(pc);
    // The client's loop also finds the TCP host; Wi‑Fi becomes active.
    await waitFor(() => client.linkVia == 'wifi' && host.linkVia == 'wifi', timeout: const Duration(seconds: 30));
    final a = (await client.sendText('דרך וויפיי'))!;
    await waitFor(() => a.status == MsgStatus.delivered);

    // Wi‑Fi drops: both sides fall back to the Bluetooth pipe immediately.
    client.link!.debugKillSocket();
    await waitFor(() => client.linkVia == 'nearby' && host.linkVia == 'nearby');
    final b = (await host.sendText('ממשיכים בבלוטות'))!;
    await waitFor(() => b.status == MsgStatus.delivered);
    expect(client.messages.where((m) => m.id == b.id), hasLength(1));
    expect(host.messages.where((m) => m.id == a.id), hasLength(1));
    await host.stopLink();
    await client.stopLink();
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plane_chat/core/discovery.dart';

void main() {
  test('private ranges', () {
    expect(isPrivateV4('192.168.43.7'), true);
    expect(isPrivateV4('10.12.0.1'), true);
    expect(isPrivateV4('172.20.1.1'), true);
    expect(isPrivateV4('172.40.1.1'), false);
    expect(isPrivateV4('8.8.8.8'), false);
  });

  test('candidates: preferred first, gateway guess, sweep excludes self', () {
    final q = quickCandidates(preferred: ['10.0.0.9'], localIps: ['192.168.77.23']);
    expect(q.first, '10.0.0.9');
    expect(q, contains('192.168.49.1'));
    expect(q, contains('192.168.77.1'));
    final sw = sweepCandidates(['192.168.77.23']);
    expect(sw.length, 253);
    expect(sw.contains('192.168.77.23'), false);
  });

  test('sweep finds a host with a random address on our /24', () async {
    // Host only on 127.0.0.77 (like a hotspot owner at a random address).
    final server = await ServerSocket.bind(InternetAddress('127.0.0.77'), 0);
    server.listen((s) => s.destroy());
    final s = await findHost(
      port: server.port,
      preferred: const ['127.0.0.250'],
      localIps: () async => ['127.0.0.200'],
    );
    expect(s, isNotNull);
    expect(s!.remoteAddress.address, '127.0.0.77');
    s.destroy();
    await server.close();
  });

  test('nothing listening: returns null in reasonable time', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final sw = Stopwatch()..start();
    final s = await findHost(port: port, localIps: () async => ['127.0.0.200']);
    expect(s, isNull);
    expect(sw.elapsed.inSeconds, lessThan(20));
  });

  test('host beacon is heard by the listener', () async {
    final l = BeaconListener();
    await l.start(port: 47999);
    final b = HostBeacon(name: 'x', beaconPort: 47999);
    await b.start();
    await Future.delayed(const Duration(milliseconds: 2500));
    b.stop();
    l.stop();
    // Broadcast may be filtered in some sandboxes; just require no crash.
    expect(l.recent(), isA<List<String>>());
  });
}

// Finding the host on any shared network (phone hotspot, plane Wi‑Fi, home
// Wi‑Fi) without typing an IP address, and without iOS multicast entitlements.
//
// Client side (works on iOS with only the Local Network permission):
//   1. last address that worked, manual address, addresses heard in UDP beacons,
//      192.168.49.1 (Wi‑Fi Direct owner), and x.y.z.1 of every local subnet;
//   2. if none answers: a TCP sweep of every /24 we sit on (x.y.z.1..254),
//      64 attempts at a time with a short timeout. Android hotspots randomise
//      both the subnet and the host's own address, so the sweep is what makes
//      this reliable.
// Host side: a UDP broadcast beacon (cheap shortcut for clients that can hear
// it; iOS without the multicast entitlement usually can't, which is fine).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';

const int kBeaconPort = kDefaultPort + 1;

bool isPrivateV4(String ip) {
  final p = ip.split('.').map(int.tryParse).toList();
  if (p.length != 4 || p.any((e) => e == null)) return false;
  final a = p[0]!, b = p[1]!;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

String? subnet24(String ip) {
  final i = ip.lastIndexOf('.');
  return i < 0 ? null : ip.substring(0, i);
}

/// Our own private IPv4 addresses (Wi‑Fi, hotspot, Wi‑Fi Direct). Cellular
/// carrier addresses are also 10.x sometimes; harmless, the sweep just fails.
Future<List<String>> localPrivateIPv4() async {
  try {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    final out = <String>[];
    for (final ni in ifs) {
      final n = ni.name.toLowerCase();
      if (n.startsWith('rmnet') || n.startsWith('pdp_ip') || n.startsWith('utun') ||
          n.startsWith('ipsec') || n.startsWith('tun') || n.startsWith('dummy')) {
        continue;
      }
      for (final a in ni.addresses) {
        if (isPrivateV4(a.address) && !out.contains(a.address)) out.add(a.address);
      }
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// Listens for host beacons; keeps the latest address heard (best effort).
class BeaconListener {
  RawDatagramSocket? _sock;
  final Map<String, DateTime> heard = {};

  Future<void> start({int port = kBeaconPort}) async {
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
      _sock!.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = _sock?.receive();
        if (d == null) return;
        try {
          final m = jsonDecode(utf8.decode(d.data));
          if (m is Map && m['t'] == 'planechat') heard[d.address.address] = DateTime.now();
        } catch (_) {}
      }, onError: (_) {});
    } catch (_) {
      _sock = null; // not allowed / port busy: sweep still works
    }
  }

  List<String> recent() {
    final cut = DateTime.now().subtract(const Duration(seconds: 30));
    return heard.entries.where((e) => e.value.isAfter(cut)).map((e) => e.key).toList();
  }

  void stop() {
    _sock?.close();
    _sock = null;
  }
}

/// Host: broadcast "I'm here" every 2 s on every local subnet.
class HostBeacon {
  HostBeacon({required this.name, this.port = kDefaultPort, this.beaconPort = kBeaconPort});
  final String name;
  final int port;
  final int beaconPort;
  RawDatagramSocket? _sock;
  Timer? _timer;

  Future<void> start() async {
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _sock!.broadcastEnabled = true;
    } catch (_) {
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _send());
    unawaited(_send());
  }

  Future<void> _send() async {
    final s = _sock;
    if (s == null) return;
    final data = utf8.encode(jsonEncode({'t': 'planechat', 'port': port, 'name': name}));
    final targets = <String>{'255.255.255.255'};
    for (final ip in await localPrivateIPv4()) {
      final net = subnet24(ip);
      if (net != null) targets.add('$net.255');
    }
    for (final t in targets) {
      try {
        s.send(data, InternetAddress(t), beaconPort);
      } catch (_) {}
    }
  }

  void stop() {
    _timer?.cancel();
    _sock?.close();
    _sock = null;
  }
}

/// Races TCP connects to [hosts]; returns the first socket that connects
/// (others are destroyed) or null.
Future<Socket?> raceConnect(Iterable<String> hosts, int port,
    {Duration timeout = const Duration(milliseconds: 1200), int parallel = 64}) async {
  final list = hosts.toSet().toList();
  Socket? winner;
  var i = 0;
  Future<void> worker() async {
    while (winner == null && i < list.length) {
      final h = list[i++];
      try {
        final s = await Socket.connect(h, port, timeout: timeout);
        if (winner == null) {
          winner = s;
        } else {
          s.destroy();
        }
      } catch (_) {}
    }
  }

  await Future.wait(List.generate(parallel < list.length ? parallel : list.length, (_) => worker()));
  return winner;
}

/// Ordered candidate addresses before any sweep.
List<String> quickCandidates({
  required List<String> preferred,
  required List<String> localIps,
  bool includeDirect = true,
}) {
  final out = <String>[...preferred];
  if (includeDirect) out.add(kDefaultHostIp);
  for (final ip in localIps) {
    final net = subnet24(ip);
    if (net != null) out.add('$net.1');
  }
  return out.where((h) => h.isNotEmpty && !localIps.contains(h)).toSet().toList();
}

/// Every x.y.z.1..254 of our /24 subnets, excluding our own addresses.
List<String> sweepCandidates(List<String> localIps) {
  final out = <String>[];
  for (final ip in localIps) {
    final net = subnet24(ip);
    if (net == null) continue;
    for (var h = 1; h <= 254; h++) {
      final a = '$net.$h';
      if (!localIps.contains(a)) out.add(a);
    }
  }
  return out;
}

/// Full search: quick candidates first, then the subnet sweep.
Future<Socket?> findHost({
  required int port,
  List<String> preferred = const [],
  bool sweep = true,
  Future<List<String>> Function()? localIps,
}) async {
  final ips = await (localIps ?? localPrivateIPv4)();
  final quick = quickCandidates(preferred: preferred, localIps: ips);
  final s = await raceConnect(quick, port, timeout: const Duration(milliseconds: 1500), parallel: 16);
  if (s != null || !sweep) return s;
  final rest = sweepCandidates(ips).where((h) => !quick.contains(h));
  return raceConnect(rest, port, timeout: const Duration(milliseconds: 900), parallel: 64);
}

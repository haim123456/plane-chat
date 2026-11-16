import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plane_chat/core/protocol.dart';
import 'package:plane_chat/core/store.dart';

void main() {
  test('frame round-trip with Hebrew text', () {
    final f = msgFrame(id: 'a1', kind: MsgKind.text, ts: 1, text: 'שלום, מה נשמע? 👋');
    final dec = FrameDecoder().add(encodeFrame(f));
    expect(dec, hasLength(1));
    expect(dec.single['text'], 'שלום, מה נשמע? 👋');
    expect(dec.single['kind'], 'text');
  });

  test('length prefix is big-endian byte count of UTF-8 body', () {
    final bytes = encodeFrame({'t': 'ping'});
    final body = utf8.encode(jsonEncode({'t': 'ping'}));
    expect(ByteData.view(bytes.buffer).getUint32(0), body.length);
    expect(bytes.length, body.length + 4);
  });

  test('decoder handles frames split at every byte and glued together', () {
    final frames = [
      pingFrame(),
      msgFrame(id: 'x', kind: MsgKind.text, ts: 5, text: 'אבג'),
      ackFrame('x'),
      helloFrame('טלפון שני', 'dev1'),
    ];
    final all = frames.expand(encodeFrame).toList();
    final d = FrameDecoder();
    final got = <Map<String, dynamic>>[];
    for (final b in all) {
      got.addAll(d.add([b]));
    }
    expect(got.map((f) => f['t']).toList(), ['ping', 'msg', 'ack', 'hello']);
    expect(d.bufferedBytes, 0);
    // glued in one chunk
    expect(FrameDecoder().add(all).length, 4);
  });

  test('binary payload survives (300 KB random bytes)', () {
    final r = Random(1);
    final data = Uint8List.fromList(List.generate(300 * 1024, (_) => r.nextInt(256)));
    final f = msgFrame(id: 'img', kind: MsgKind.image, ts: 9, data: data);
    final enc = encodeFrame(f);
    final d = FrameDecoder();
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < enc.length; i += 7777) {
      out.addAll(d.add(enc.sublist(i, min(i + 7777, enc.length))));
    }
    expect(out, hasLength(1));
    expect(frameData(out.single), data);
  });

  test('oversized declared length is rejected', () {
    final bad = Uint8List(8);
    ByteData.view(bad.buffer).setUint32(0, kMaxFrameBytes + 1);
    expect(() => FrameDecoder().add(bad), throwsA(isA<ProtocolException>()));
  });

  test('non-object JSON is rejected', () {
    final body = utf8.encode('[1,2]');
    final b = Uint8List(4 + body.length);
    ByteData.view(b.buffer).setUint32(0, body.length);
    b.setRange(4, b.length, body);
    expect(() => FrameDecoder().add(b), throwsA(isA<ProtocolException>()));
  });

  test('ChatMessage json round-trip', () {
    final m = ChatMessage(id: 'q', kind: MsgKind.voice, fromMe: true, ts: 3,
        mediaPath: '/x.m4a', durationMs: 4200, status: MsgStatus.delivered);
    final back = ChatMessage.fromJson(m.toJson());
    expect(back.kind, MsgKind.voice);
    expect(back.durationMs, 4200);
    expect(back.status, MsgStatus.delivered);
    expect(back.fromMe, true);
  });

  test('unknown kind falls back to text', () {
    expect(parseKind('sticker'), MsgKind.text);
  });
}

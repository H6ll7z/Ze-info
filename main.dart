import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ZE Server Watch',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: 'monospace',
          scaffoldBackgroundColor: const Color(0xFF020A04),
        ),
        home: const HomePage(),
      );
}

// ---------- Source (A2S) query ----------

class ServerInfo {
  String name = '', map = '', game = '';
  int players = 0, maxPlayers = 0, bots = 0, pingMs = 0;
}

class PlayerInfo {
  final String name;
  final int score;
  final double seconds;
  PlayerInfo(this.name, this.score, this.seconds);
}

class _Reader {
  final Uint8List d;
  int p = 0;
  _Reader(this.d);
  int byte() => d[p++];
  int short() {
    final v = ByteData.sublistView(d, p, p + 2).getUint16(0, Endian.little);
    p += 2;
    return v;
  }

  int int32() {
    final v = ByteData.sublistView(d, p, p + 4).getInt32(0, Endian.little);
    p += 4;
    return v;
  }

  double float() {
    final v = ByteData.sublistView(d, p, p + 4).getFloat32(0, Endian.little);
    p += 4;
    return v;
  }

  String str() {
    final s = p;
    while (d[p] != 0) {
      p++;
    }
    final out = utf8.decode(d.sublist(s, p), allowMalformed: true);
    p++;
    return out;
  }
}

Future<Uint8List> _exchange(InternetAddress addr, int port, List<int> payload) async {
  final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final done = Completer<Uint8List>();
  final sub = sock.listen((e) {
    if (e == RawSocketEvent.read) {
      final dg = sock.receive();
      if (dg != null && !done.isCompleted) done.complete(dg.data);
    }
  });
  sock.send(payload, addr, port);
  try {
    return await done.future.timeout(const Duration(seconds: 3));
  } finally {
    await sub.cancel();
    sock.close();
  }
}

const _head = [0xFF, 0xFF, 0xFF, 0xFF];

Future<ServerInfo> queryInfo(String host, int port) async {
  final addr = (await InternetAddress.lookup(host, type: InternetAddressType.IPv4)).first;
  final req = [..._head, 0x54, ...utf8.encode('Source Engine Query'), 0];
  final sw = Stopwatch()..start();
  var res = await _exchange(addr, port, req);
  if (res.length > 4 && res[4] == 0x41) {
    res = await _exchange(addr, port, [...req, ...res.sublist(5, 9)]);
  }
  sw.stop();
  final r = _Reader(res)..p = 5; // skip header + type byte (0x49)
  r.byte(); // protocol
  final i = ServerInfo();
  i.name = r.str();
  i.map = r.str();
  r.str(); // folder
  i.game = r.str();
  r.short(); // app id
  i.players = r.byte();
  i.maxPlayers = r.byte();
  i.bots = r.byte();
  i.pingMs = sw.elapsedMilliseconds;
  return i;
}

Future<List<PlayerInfo>> queryPlayers(String host, int port) async {
  final addr = (await InternetAddress.lookup(host, type: InternetAddressType.IPv4)).first;
  var res = await _exchange(addr, port, [..._head, 0x55, 0xFF, 0xFF, 0xFF, 0xFF]);
  if (res.length > 4 && res[4] == 0x41) {
    res = await _exchange(addr, port, [..._head, 0x55, ...res.sublist(5, 9)]);
  }
  final r = _Reader(res)..p = 5;
  final count = r.b

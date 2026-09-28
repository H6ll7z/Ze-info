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
        title: 'ZE Server Info',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorSchemeSeed: Colors.green,
          useMaterial3: true,
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
  final count = r.byte();
  final list = <PlayerInfo>[];
  for (var n = 0; n < count; n++) {
    r.byte(); // index
    final name = r.str();
    final score = r.int32();
    final secs = r.float();
    list.add(PlayerInfo(name, score, secs));
  }
  list.sort((a, b) => b.score.compareTo(a.score));
  return list;
}

// ---------- UI ----------

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _ip = TextEditingController(text: '74.91.124.21');
  final _port = TextEditingController(text: '27015');
  final List<String> events = []; // newest first
  bool firstLoad = true;

  @override
  void initState() {
    super.initState();
    auto = true;
    refresh();
    timer = Timer.periodic(const Duration(seconds: 4), (_) => refresh());
  }

  String _now() {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  void _diff(ServerInfo newInfo, List<PlayerInfo> newPlayers) {
    if (firstLoad) {
      firstLoad = false;
      return;
    }
    final oldNames = players.map((p) => p.name).where((n) => n.isNotEmpty).toList();
    final newNames = newPlayers.map((p) => p.name).where((n) => n.isNotEmpty).toList();
    for (final n in newNames) {
      if (!oldNames.contains(n)) events.insert(0, '${_now()}  ➕ $n joined');
    }
    for (final n in oldNames) {
      if (!newNames.contains(n)) events.insert(0, '${_now()}  ➖ $n left');
    }
    if (info != null && info!.map != newInfo.map) {
      events.insert(0, '${_now()}  🗺️ Map changed: ${info!.map} → ${newInfo.map}');
    }
    if (events.length > 100) events.removeRange(100, events.length);
  }
  ServerInfo? info;
  List<PlayerInfo> players = [];
  String? error;
  bool loading = false, auto = false;
  Timer? timer;

  Future<void> refresh() async {
    if (loading) return; // skip if the previous query is still running
    final host = _ip.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty || port == null) {
      setState(() => error = 'Enter a valid IP and port');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final i = await queryInfo(host, port);
      List<PlayerInfo> p = [];
      try {
        p = await queryPlayers(host, port);
      } catch (_) {} // player list is optional
      setState(() {
        _diff(i, p);
        info = i;
        players = p;
      });
    } on TimeoutException {
      setState(() => error = 'Server did not respond (timeout)');
    } catch (e) {
      setState(() => error = 'Query failed: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  void toggleAuto(bool v) {
    setState(() => auto = v);
    timer?.cancel();
    if (v) timer = Timer.periodic(const Duration(seconds: 4), (_) => refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  String fmt(double s) {
    final m = s ~/ 60;
    return m >= 60 ? '${m ~/ 60}h ${m % 60}m' : '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final i = info;
    final isZe = i?.map.toLowerCase().startsWith('ze_') ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('ZE Server Info')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _ip,
                decoration: const InputDecoration(labelText: 'IP / Host', border: OutlineInputBorder()),
                keyboardType: TextInputType.url,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 1,
              child: TextField(
                controller: _port,
                decoration: const InputDecoration(labelText: 'Port', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: loading ? null : refresh,
            icon: loading
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search),
            label: const Text('Get server info'),
          ),
          SwitchListTile(
            title: const Text('Auto-refresh (4s)'),
            value: auto,
            onChanged: toggleAuto,
            contentPadding: EdgeInsets.zero,
          ),
          if (error != null)
            Card(
              color: Colors.red.shade900,
              child: Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
            ),
          if (i != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(i.name, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  _row(Icons.map, 'Map', i.map + (isZe ? '  🧟' : '')),
                  _row(Icons.people, 'Players', '${i.players}/${i.maxPlayers}'
                      '${i.bots > 0 ? ' (${i.bots} bots)' : ''}'),
                  _row(Icons.speed, 'Ping', '${i.pingMs} ms'),
                  _row(Icons.sports_esports, 'Game', i.game),
                ]),
              ),
            ),
            Card(
              child: Column(children: [
                const ListTile(title: Text('Activity (joins / leaves / map)')),
                if (events.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Watching… changes will appear here')),
                for (final e in events.take(30))
                  ListTile(dense: true, title: Text(e)),
              ]),
            ),
            Card(
              child: Column(children: [
                const ListTile(title: Text('Players online')),
                if (players.isEmpty)
                  const Padding(padding: EdgeInsets.all(16), child: Text('No player data')),
                for (final p in players)
                  ListTile(
                    dense: true,
                    title: Text(p.name.isEmpty ? '(connecting)' : p.name),
                    subtitle: Text('Time: ${fmt(p.seconds)}'),
                    trailing: Text('${p.score}'),
                  ),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(child: Text(value)),
        ]),
      );
}

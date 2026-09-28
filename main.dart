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

// ---------- UI (terminal / matrix style) ----------

const bg = Color(0xFF020A04);
const panel = Color(0xFF04140A);
const green = Color(0xFF2BFF7A);
const dim = Color(0xFF1E8F4A);
const border = Color(0xFF0E5A2A);
const red = Color(0xFFFF2E63);
const yellow = Color(0xFFD4E157);

class LogLine {
  final String text;
  final int kind; // 0 poll, 1 join, 2 leave, 3 map, 4 error
  LogLine(this.text, this.kind);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String host = '74.91.124.21';
  int port = 27015;
  ServerInfo? info;
  List<PlayerInfo> players = [];
  final List<LogLine> log = []; // newest first
  final List<int> pings = [];
  bool online = false, loading = false, firstLoad = true;
  final start = DateTime.now();
  Timer? poll, tick;

  @override
  void initState() {
    super.initState();
    refresh();
    poll = Timer.periodic(const Duration(seconds: 4), (_) => refresh());
    tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    poll?.cancel();
    tick?.cancel();
    super.dispose();
  }

  String _t([DateTime? d]) {
    final t = d ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  String _uptime() {
    final d = DateTime.now().difference(start);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }

  void _add(String text, int kind) {
    log.insert(0, LogLine('> [${_t()}] $text', kind));
    if (log.length > 200) log.removeRange(200, log.length);
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    try {
      final i = await queryInfo(host, port);
      List<PlayerInfo> p = [];
      try {
        p = await queryPlayers(host, port);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        if (!firstLoad) {
          final oldN = players.map((e) => e.name).where((n) => n.isNotEmpty).toList();
          final newN = p.map((e) => e.name).where((n) => n.isNotEmpty).toList();
          for (final n in newN) {
            if (!oldN.contains(n)) _add('+ $n joined', 1);
          }
          for (final n in oldN) {
            if (!newN.contains(n)) _add('- $n left', 2);
          }
          if (info != null && info!.map != i.map) {
            _add('MAP CHANGE ${info!.map} -> ${i.map}', 3);
          }
        }
        firstLoad = false;
        online = true;
        info = i;
        players = p;
        pings.add(i.pingMs);
        if (pings.length > 40) pings.removeAt(0);
        _add('${i.players}/${i.maxPlayers} on ${i.map} (${i.pingMs} ms)', 0);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        online = false;
        firstLoad = true;
        players = [];
        _add('QUERY FAILED: ${e is TimeoutException ? 'timed out' : e}', 4);
      });
    } finally {
      loading = false;
    }
  }

  Future<void> editTarget() async {
    final ip = TextEditingController(text: host);
    final pt = TextEditingController(text: '$port');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: panel,
        shape: RoundedRectangleBorder(side: const BorderSide(color: border)),
        title: const Text('> SET TARGET', style: TextStyle(color: green, fontSize: 14)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          _field(ip, 'IP / HOST'),
          const SizedBox(height: 8),
          _field(pt, 'PORT', number: true),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('CANCEL', style: TextStyle(color: dim))),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('SAVE', style: TextStyle(color: green))),
        ],
      ),
    );
    final newPort = int.tryParse(pt.text.trim());
    if (ok == true && ip.text.trim().isNotEmpty && newPort != null) {
      setState(() {
        host = ip.text.trim();
        port = newPort;
        info = null;
        players = [];
        pings.clear();
        firstLoad = true;
        online = false;
        _add('TARGET -> $host:$port', 3);
      });
      refresh();
    }
  }

  Widget _field(TextEditingController c, String label, {bool number = false}) =>
      TextField(
        controller: c,
        keyboardType: number ? TextInputType.number : TextInputType.url,
        style: const TextStyle(color: green),
        cursorColor: green,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: dim),
          enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: border)),
          focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: green)),
        ),
      );

  Color _logColor(int k) => switch (k) {
        1 => green,
        2 => const Color(0xFFFFB74D),
        3 => yellow,
        4 => red,
        _ => dim,
      };

  Widget _label(String t) => Text(t, style: const TextStyle(color: dim, fontSize: 11, letterSpacing: 1));

  Widget _box({required Widget child, double? height}) => Container(
        height: height,
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF020C06),
          border: Border.all(color: border),
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final i = info;
    final full = i != null && i.players >= i.maxPlayers && i.maxPlayers > 0;
    final frac = (i == null || i.maxPlayers == 0) ? 0.0 : (i.players / i.maxPlayers).clamp(0.0, 1.0);
    final accent = online ? green : red;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            const Center(
              child: Text('S E R V E R - W A T C H',
                  style: TextStyle(color: green, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 2)),
            ),
            const SizedBox(height: 10),
            Row(children: [
              const Expanded(
                child: Text('root@ze-watch:~\$ live server watch',
                    style: TextStyle(color: green, fontSize: 11)),
              ),
              Text('UPTIME ${_uptime()}', style: const TextStyle(color: dim, fontSize: 10)),
            ]),
            const Divider(color: border),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: panel,
                border: Border.all(color: accent.withOpacity(0.6)),
                borderRadius: BorderRadius.circular(6),
                boxShadow: [BoxShadow(color: accent.withOpacity(0.25), blurRadius: 14)],
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(online ? Icons.dns : Icons.portable_wifi_off, color: accent, size: 22),
                  const SizedBox(width: 8),
                  const Text('ZE SERVER',
                      style: TextStyle(color: green, fontSize: 20, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: editTarget,
                  child: Text('$host:$port  [edit]',
                      style: const TextStyle(color: dim, fontSize: 11)),
                ),
                const Divider(color: border, height: 22),
                if (!online)
                  const Text('OFFLINE / UNREACHABLE (timed out)',
                      style: TextStyle(color: red, fontSize: 13))
                else if (i != null) ...[
                  Text(i.name, style: const TextStyle(color: green, fontSize: 12)),
                  const SizedBox(height: 14),
                  Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        _label('MAP'),
                        const SizedBox(height: 4),
                        Text(i.map, style: const TextStyle(color: yellow, fontSize: 14)),
                      ]),
                    ),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _label('PING'),
                      const SizedBox(height: 4),
                      Row(children: [
                        Text('${i.pingMs} ms', style: const TextStyle(color: yellow, fontSize: 14)),
                        const SizedBox(width: 8),
                        SizedBox(width: 70, height: 22, child: CustomPaint(painter: Spark(pings))),
                      ]),
                    ]),
                  ]),
                ],
                const SizedBox(height: 16),
                _label('PLAYERS'),
                const SizedBox(height: 4),
                Text(online && i != null ? '${i.players}/${i.maxPlayers}' : '-/-',
                    style: TextStyle(
                        color: online ? Colors.white : red,
                        fontSize: 22,
                        fontWeight: FontWeight.bold)),
                if (online && i != null && i.bots > 0)
                  Text('(${i.bots} bots)', style: const TextStyle(color: dim, fontSize: 11)),
                const SizedBox(height: 6),
                Container(
                  height: 12,
                  decoration: BoxDecoration(border: Border.all(color: border)),
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: online ? frac : 0,
                    child: Container(color: full ? red : green),
                  ),
                ),
                const SizedBox(height: 18),
                const Text('> ACTIVITY LOG', style: TextStyle(color: dim, fontSize: 11)),
                const SizedBox(height: 6),
                _box(
                  height: 420,
                  child: ListView.builder(
                    itemCount: log.length,
                    itemBuilder: (c, n) => Text(log[n].text,
                        style: TextStyle(color: _logColor(log[n].kind), fontSize: 11, height: 1.5)),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 10),
            Text('[ SYSTEM ONLINE ] -> refreshing every 4s',
                style: TextStyle(color: dim.withOpacity(0.8), fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

class Spark extends CustomPainter {
  final List<int> v;
  Spark(this.v);
  @override
  void paint(Canvas canvas, Size size) {
    if (v.length < 2) return;
    final mx = v.reduce((a, b) => a > b ? a : b).toDouble();
    final mn = v.reduce((a, b) => a < b ? a : b).toDouble();
    final range = (mx - mn) == 0 ? 1.0 : (mx - mn);
    final path = Path();
    for (var k = 0; k < v.length; k++) {
      final x = size.width * k / (v.length - 1);
      final y = size.height - ((v[k] - mn) / range) * (size.height - 2) - 1;
      k == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = green
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(Spark old) => true;
}

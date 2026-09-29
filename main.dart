import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Color(0xFF020A04),
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const MyApp());
}

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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
          child: child!,
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

// ---------- UI (hacker terminal style) ----------

const bg = Color(0xFF020A04);
const panel = Color(0xFF04140A);
const green = Color(0xFF2BFF7A);
const dim = Color(0xFF1E8F4A);
const border = Color(0xFF0E5A2A);
const red = Color(0xFFFF2E63);
const yellow = Color(0xFFD4E157);

List<Shadow> glow(Color c, [double b = 8]) => [Shadow(color: c.withOpacity(0.7), blurRadius: b)];

// ---------- Shaded "realistic" eyeball logo (gradients, no pixel grid) ----------

class RealisticEyePainter extends CustomPainter {
  final Offset look; // pupil offset: dx in [-1,1], dy in [-0.35,0.35]
  final double pulse; // 0..1 glow pulse
  final double blink; // 0 (open) .. 1 (closed)
  final bool alert; // true when server is offline -> faster/brighter glow

  const RealisticEyePainter({
    required this.look,
    required this.pulse,
    required this.blink,
    required this.alert,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;

    // almond-shaped eye outline
    final eyePath = Path()
      ..moveTo(0, h * 0.52)
      ..quadraticBezierTo(w * 0.5, -h * 0.12, w, h * 0.52)
      ..quadraticBezierTo(w * 0.5, h * 1.14, 0, h * 0.52)
      ..close();

    canvas.save();
    canvas.clipPath(eyePath);

    // sclera: radial gradient gives it a curved, glossy sphere feel
    final scleraShader = const RadialGradient(
      center: Alignment(-0.35, -0.45),
      radius: 1.0,
      colors: [Colors.white, Color(0xFFE9DEDA), Color(0xFFC7B3AF)],
      stops: [0.0, 0.65, 1.0],
    ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..shader = scleraShader);

    // faint bloodshot veins
    final veinPaint = Paint()
      ..color = const Color(0xFFD23B3B).withOpacity(0.28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;
    canvas.drawPath(
        Path()
          ..moveTo(w * 0.02, h * 0.5)
          ..quadraticBezierTo(w * 0.18, h * 0.42, w * 0.34, h * 0.5),
        veinPaint);
    canvas.drawPath(
        Path()
          ..moveTo(w * 0.98, h * 0.55)
          ..quadraticBezierTo(w * 0.82, h * 0.62, w * 0.66, h * 0.55),
        veinPaint);

    // iris + pupil, snap-look position
    final irisCenter = Offset(w * 0.5 + look.dx * w * 0.16, h * 0.55 + look.dy * h * 0.12);
    final irisR = w * 0.27;
    final irisRect = Rect.fromCircle(center: irisCenter, radius: irisR);
    final irisShader = const RadialGradient(
      colors: [Color(0xFFB33A3A), Color(0xFF7A1414), Color(0xFF320707)],
      stops: [0.0, 0.65, 1.0],
    ).createShader(irisRect);
    canvas.drawCircle(irisCenter, irisR, Paint()..shader = irisShader);

    // fine iris fibers radiating from the pupil
    final fiber = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    for (var k = 0; k < 20; k++) {
      final a = (k / 20) * 2 * pi;
      final inner = Offset(irisCenter.dx + cos(a) * irisR * 0.32, irisCenter.dy + sin(a) * irisR * 0.32);
      final outer = Offset(irisCenter.dx + cos(a) * irisR * 0.92, irisCenter.dy + sin(a) * irisR * 0.92);
      fiber.color = (k.isEven ? Colors.black : const Color(0xFFFF6B6B)).withOpacity(0.18);
      canvas.drawLine(inner, outer, fiber);
    }

    // limbal ring (dark edge around iris) for definition
    canvas.drawCircle(
        irisCenter, irisR, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.4..color = Colors.black.withOpacity(0.55));

    // glow behind pupil, tied to server status
    final glowColor = alert ? const Color(0xFFFF5252) : const Color(0xFFFF1744);
    final glowOpacity = alert ? 0.45 + 0.35 * pulse : 0.25 + 0.2 * pulse;
    canvas.drawCircle(irisCenter, irisR * 0.95, Paint()
      ..color = glowColor.withOpacity(glowOpacity)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));

    // pupil
    final pupilR = irisR * 0.42;
    canvas.drawCircle(irisCenter, pupilR, Paint()..color = Colors.black);

    // glossy specular highlights
    canvas.drawCircle(Offset(irisCenter.dx - irisR * 0.32, irisCenter.dy - irisR * 0.32), irisR * 0.22,
        Paint()..color = Colors.white.withOpacity(0.9));
    canvas.drawCircle(Offset(irisCenter.dx + irisR * 0.28, irisCenter.dy + irisR * 0.34), irisR * 0.08,
        Paint()..color = Colors.white.withOpacity(0.35));

    // subtle inner shadow near the lids for depth
    canvas.drawRect(
        Rect.fromLTWH(0, 0, w, h * 0.1), Paint()..color = Colors.black.withOpacity(0.18));
    canvas.drawRect(
        Rect.fromLTWH(0, h * 0.9, w, h * 0.1), Paint()..color = Colors.black.withOpacity(0.18));

    canvas.restore(); // end clip to eye shape

    // eyelid outline
    canvas.drawPath(
        eyePath, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.4..color = const Color(0xFF2A1414));

    // blink: eyelids closing over the eye
    if (blink > 0) {
      canvas.save();
      canvas.clipPath(eyePath);
      const lidShader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF7A4A42), Color(0xFF5A342E)],
      );
      final lidPaint = Paint()..shader = lidShader.createShader(Rect.fromLTWH(0, 0, w, h));
      final closeH = h * 0.6 * blink;
      canvas.drawRect(Rect.fromLTWH(0, 0, w, closeH), lidPaint);
      canvas.drawRect(Rect.fromLTWH(0, h - closeH, w, closeH), lidPaint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant RealisticEyePainter old) =>
      old.look != look || old.pulse != pulse || old.blink != blink || old.alert != alert;
}

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

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  String host = '74.91.124.21';
  int port = 27015;
  ServerInfo? info;
  List<PlayerInfo> players = [];
  final List<LogLine> log = []; // newest first
  final List<int> pings = [];
  bool online = false, loading = false, firstLoad = true;
  final start = DateTime.now();
  Timer? poll, tick;
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: const Duration(seconds: 7))..repeat();

  // -- eye look/blink state --
  final Random _rng = Random();
  Offset _eyeFrom = Offset.zero;
  Offset _eyeTo = Offset.zero;
  late final AnimationController _eyeAnim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  late final AnimationController _blinkAnim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 90));
  Timer? _lookTimer, _blinkTimer;

  Offset _currentLook() {
    final k = Curves.easeOutBack.transform(_eyeAnim.value);
    return Offset.lerp(_eyeFrom, _eyeTo, k)!;
  }

  void _scheduleLook() {
    final holdMs = 1200 + _rng.nextInt(1800); // hold a glance for 1.2-3.0s
    _lookTimer = Timer(Duration(milliseconds: holdMs), () {
      if (!mounted) return;
      setState(() {
        _eyeFrom = _currentLook();
        _eyeTo = Offset(_rng.nextDouble() * 2 - 1, _rng.nextDouble() * 0.7 - 0.35);
      });
      _eyeAnim
        ..reset()
        ..forward();
      _scheduleLook();
    });
  }

  void _scheduleBlink() {
    final delayMs = 3000 + _rng.nextInt(3000); // blink every 3-6s
    _blinkTimer = Timer(Duration(milliseconds: delayMs), () async {
      if (!mounted) return;
      await _blinkAnim.forward(from: 0);
      if (!mounted) return;
      await _blinkAnim.reverse();
      _scheduleBlink();
    });
  }

  @override
  void initState() {
    super.initState();
    refresh();
    poll = Timer.periodic(const Duration(seconds: 4), (_) => refresh());
    tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _scheduleLook();
    _scheduleBlink();
  }

  @override
  void dispose() {
    poll?.cancel();
    tick?.cancel();
    _lookTimer?.cancel();
    _blinkTimer?.cancel();
    _anim.dispose();
    _eyeAnim.dispose();
    _blinkAnim.dispose();
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
        1 => dim,
        2 => const Color(0xFFFFB74D),
        3 => yellow,
        4 => red,
        _ => green,
      };

  Widget _label(String t) => Text(t, style: const TextStyle(color: dim, fontSize: 11, letterSpacing: 2));

  Widget _box({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF020C06),
          border: Border.all(color: border),
        ),
        child: child,
      );

  Widget _logRow(LogLine l, int n) {
    final c = _logColor(l.kind);
    final st = TextStyle(
        color: c, fontSize: 11, height: 1.5, shadows: l.kind == 0 ? null : glow(c, 4));
    final m = RegExp(r'^(.* on )(\S+)( \(.*)$').firstMatch(l.text);
    final Widget t = (l.kind != 0 || m == null)
        ? Text(l.text, style: st, maxLines: 1, overflow: TextOverflow.ellipsis)
        : Text.rich(
            TextSpan(style: st, children: [
              TextSpan(text: m.group(1)),
              TextSpan(text: m.group(2), style: st.copyWith(color: yellow)),
              TextSpan(text: m.group(3)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis);
    return SizedBox(
      height: 16.5,
      child: Opacity(opacity: (1 - n * 0.06).clamp(0.3, 1.0).toDouble(), child: t),
    );
  }

  @override
  Widget build(BuildContext context) {
    final i = info;
    final full = i != null && i.players >= i.maxPlayers && i.maxPlayers > 0;
    final accent = online ? green : red;
    final blink = DateTime.now().second.isEven;
    final total = (online && i != null && i.maxPlayers > 0) ? i.maxPlayers : 64;
    final filled = (online && i != null) ? i.players : 0;

    return Scaffold(
      backgroundColor: bg,
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.5),
            radius: 1.3,
            colors: [Color(0xFF052414), bg],
          ),
        ),
        child: Stack(children: [
          const Positioned.fill(child: CustomPaint(painter: GridPainter())),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  AnimatedBuilder(
                    animation: Listenable.merge([_anim, _eyeAnim, _blinkAnim]),
                    builder: (c, _) {
                      final freq = online ? 1.0 : 3.0;
                      final pulse = 0.5 + 0.5 * sin(_anim.value * 2 * pi * freq);
                      return Container(
                        width: 40,
                        height: 40,
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: (online ? const Color(0xFFFF1744) : const Color(0xFFFF5252))
                                  .withOpacity(0.7)),
                          color: const Color(0xFF020C06),
                          boxShadow: [
                            BoxShadow(
                                color: (online ? const Color(0xFFFF1744) : const Color(0xFFFF5252))
                                    .withOpacity(0.4 + 0.3 * pulse),
                                blurRadius: online ? 14 : 20),
                          ],
                        ),
                        child: CustomPaint(
                            painter: RealisticEyePainter(
                          look: _currentLook(),
                          pulse: pulse,
                          blink: _blinkAnim.value,
                          alert: !online,
                        )),
                      );
                    },
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text('S E R V E R - W A T C H',
                        overflow: TextOverflow.visible,
                        style: TextStyle(
                            color: green,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2,
                            shadows: glow(green, 12))),
                  ),
                ]),
                const SizedBox(height: 2),
                const Text('// A2S SOURCE QUERY MONITOR',
                    style: TextStyle(color: dim, fontSize: 9, letterSpacing: 2)),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: Text('root@ze-watch:~\$ live server watch${blink ? '█' : ' '}',
                        style: TextStyle(color: green, fontSize: 11, shadows: glow(green, 6))),
                  ),
                  Text('UPTIME ${_uptime()}', style: const TextStyle(color: dim, fontSize: 10)),
                ]),
                const Divider(color: border, height: 16),
                Expanded(
                  child: CustomPaint(
                    foregroundPainter: Brackets(accent),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: panel.withOpacity(0.85),
                        border: Border.all(color: accent.withOpacity(0.45)),
                        boxShadow: [BoxShadow(color: accent.withOpacity(0.22), blurRadius: 18)],
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Icon(online ? Icons.dns : Icons.portable_wifi_off, color: accent, size: 22),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('ZE SERVER',
                                style: TextStyle(
                                    color: green,
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    shadows: glow(green, 10))),
                          ),
                          Opacity(
                            opacity: blink ? 1 : 0.35,
                            child: Text(online ? '● LIVE' : '● DOWN',
                                style: TextStyle(color: accent, fontSize: 11, shadows: glow(accent, 6))),
                          ),
                        ]),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: editTarget,
                          child: Text('$host:$port  [edit]',
                              style: const TextStyle(color: dim, fontSize: 11)),
                        ),
                        const Divider(color: border, height: 22),
                        if (!online)
                          Text('OFFLINE / UNREACHABLE (timed out)',
                              style: TextStyle(color: red, fontSize: 13, shadows: glow(red, 6)))
                        else if (i != null) ...[
                          Text(i.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: green, fontSize: 12)),
                          const SizedBox(height: 14),
                          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                _label('MAP'),
                                const SizedBox(height: 4),
                                Text(i.map,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: yellow, fontSize: 15, shadows: glow(yellow, 6))),
                              ]),
                            ),
                            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              _label('PING'),
                              const SizedBox(height: 4),
                              Row(children: [
                                Text('${i.pingMs} ms',
                                    style: TextStyle(color: yellow, fontSize: 15, shadows: glow(yellow, 6))),
                                const SizedBox(width: 8),
                                SizedBox(width: 80, height: 24, child: CustomPaint(painter: Spark(pings))),
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
                                fontSize: 26,
                                fontWeight: FontWeight.bold,
                                shadows: glow(online ? green : red, 10))),
                        if (online && i != null && i.bots > 0)
                          Text('(${i.bots} bots)', style: const TextStyle(color: dim, fontSize: 11)),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 14,
                          width: double.infinity,
                          child: CustomPaint(painter: SegBar(filled, total, full ? red : green)),
                        ),
                        const SizedBox(height: 18),
                        const Text('> ACTIVITY LOG',
                            style: TextStyle(color: dim, fontSize: 11, letterSpacing: 2)),
                        const SizedBox(height: 6),
                        Expanded(
                          child: _box(
                            child: LayoutBuilder(builder: (c, cons) {
                              final maxLines = (cons.maxHeight / 16.5).floor();
                              return ClipRect(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (var n = 0; n < log.length && n < maxLines; n++)
                                      _logRow(log[n], n),
                                  ],
                                ),
                              );
                            }),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text('[ SYSTEM ONLINE ] -> refreshing every 4s',
                    style: TextStyle(color: dim.withOpacity(0.8), fontSize: 10)),
              ]),
            ),
          ),
          Positioned.fill(child: IgnorePointer(child: const CustomPaint(painter: ScanlinePainter()))),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _anim,
                builder: (c, _) => CustomPaint(painter: SweepPainter(_anim.value)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class GridPainter extends CustomPainter {
  const GridPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = green.withOpacity(0.045)
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 28) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = 0; y < size.height; y += 28) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(GridPainter old) => false;
}

class ScanlinePainter extends CustomPainter {
  const ScanlinePainter();
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.black.withOpacity(0.16);
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), p);
    }
  }

  @override
  bool shouldRepaint(ScanlinePainter old) => false;
}

class SweepPainter extends CustomPainter {
  final double t;
  SweepPainter(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    const h = 140.0;
    final y = (size.height + h) * t - h;
    final rect = Rect.fromLTWH(0, y, size.width, h);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, green.withOpacity(0.07), Colors.transparent],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(SweepPainter old) => old.t != t;
}

class Brackets extends CustomPainter {
  final Color c;
  Brackets(this.c);
  @override
  void paint(Canvas canvas, Size size) {
    const l = 18.0;
    final p = Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    final w = size.width, h = size.height;
    canvas.drawPath(Path()..moveTo(0, l)..lineTo(0, 0)..lineTo(l, 0), p);
    canvas.drawPath(Path()..moveTo(w - l, 0)..lineTo(w, 0)..lineTo(w, l), p);
    canvas.drawPath(Path()..moveTo(0, h - l)..lineTo(0, h)..lineTo(l, h), p);
    canvas.drawPath(Path()..moveTo(w - l, h)..lineTo(w, h)..lineTo(w, h - l), p);
  }

  @override
  bool shouldRepaint(Brackets old) => old.c != c;
}

class SegBar extends CustomPainter {
  final int filled, total;
  final Color color;
  SegBar(this.filled, this.total, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    const gap = 2.0;
    final w = (size.width - gap * (total - 1)) / total;
    final on = Paint()..color = color;
    final glowP = Paint()
      ..color = color.withOpacity(0.6)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    final off = Paint()..color = border.withOpacity(0.55);
    for (var k = 0; k < total; k++) {
      final r = Rect.fromLTWH(k * (w + gap), 0, w, size.height);
      if (k < filled) {
        canvas.drawRect(r, glowP);
        canvas.drawRect(r, on);
      } else {
        canvas.drawRect(r, off);
      }
    }
  }

  @override
  bool shouldRepaint(SegBar old) =>
      old.filled != filled || old.total != total || old.color != color;
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
          ..color = green.withOpacity(0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ====== CONFIG ======
const String kHost = '74.91.124.21';
const int kPort = 27015;
const Color kGreen = Color(0xFF7DEBFF); // sky-cyan accent
const Color kPink = Color(0xFFFF8FCB); // sakura
const Color kViolet = Color(0xFFB98BFF); // zombies
const Color kRose = Color(0xFFFF6B8B); // danger
const Color kYellow = Color(0xFFFFE27A);
const Color kBg = Color(0xFF1A1040);
const Color kPanel = Color(0xB31E1450);
const Color kFullRed = Color(0xFFFF3B3B);
const String kMapCollectionUrl = 'https://steamcommunity.com/sharedfiles/filedetails/?id=3070555563';
const List<Shadow> kRedGlow = [
  Shadow(color: Color(0xFFFF1F1F), blurRadius: 8),
  Shadow(color: Color(0xFFFF1F1F), blurRadius: 16),
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const ZeHub());
}

class ZeHub extends StatelessWidget {
  const ZeHub({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: kBg,
          textTheme: ThemeData.dark().textTheme,
        ),
        home: const Hub(),
      );
}

// ====== SERVER QUERY (Source A2S_INFO over UDP) ======
class ServerInfo {
  final String name, map;
  final int players, maxPlayers, pingMs;
  ServerInfo(this.name, this.map, this.players, this.maxPlayers, this.pingMs);
}

Future<ServerInfo?> queryServer() async {
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final addr = InternetAddress(kHost);
    final base = <int>[0xFF, 0xFF, 0xFF, 0xFF, 0x54, ...utf8.encode('Source Engine Query'), 0];
    final sw = Stopwatch()..start();
    sock.send(base, addr, kPort);
    final completer = Completer<ServerInfo?>();
    late StreamSubscription sub;
    sub = sock.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = sock!.receive();
      if (d == null) return;
      final b = d.data;
      if (b.length < 6) return;
      if (b[4] == 0x41 && b.length >= 9) {
        // challenge: resend with challenge bytes
        sock.send([...base, ...b.sublist(5, 9)], addr, kPort);
        return;
      }
      if (b[4] == 0x49) {
        sw.stop();
        int i = 6;
        String readStr() {
          final s = i;
          while (i < b.length && b[i] != 0) {
            i++;
          }
          final str = utf8.decode(b.sublist(s, i), allowMalformed: true);
          i++;
          return str;
        }

        final name = readStr();
        final map = readStr();
        readStr(); // folder
        readStr(); // game
        i += 2; // app id
        final players = b[i];
        final max = b[i + 1];
        if (!completer.isCompleted) {
          completer.complete(ServerInfo(name, map, players, max, sw.elapsedMilliseconds));
        }
        sub.cancel();
      }
    });
    return await completer.future.timeout(const Duration(seconds: 4), onTimeout: () => null);
  } catch (_) {
    return null;
  } finally {
    sock?.close();
  }
}

// ====== PLAYER LIST (Source A2S_PLAYER over UDP) ======
class PlayerInfo {
  final String name;
  final int score;
  final double secs;
  PlayerInfo(this.name, this.score, this.secs);
}

Future<List<PlayerInfo>?> queryPlayers() async {
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final addr = InternetAddress(kHost);
    final base = <int>[0xFF, 0xFF, 0xFF, 0xFF, 0x55];
    sock.send([...base, 0xFF, 0xFF, 0xFF, 0xFF], addr, kPort);
    final completer = Completer<List<PlayerInfo>?>();
    final parts = <int, List<int>>{};
    late StreamSubscription sub;

    void parse(List<int> b) {
      if (b.length < 6 || b[4] != 0x44 || completer.isCompleted) return;
      final bd = ByteData.sublistView(Uint8List.fromList(b));
      final count = b[5];
      int i = 6;
      final list = <PlayerInfo>[];
      for (var n = 0; n < count && i < b.length; n++) {
        i++; // index byte
        final s = i;
        while (i < b.length && b[i] != 0) {
          i++;
        }
        final name = utf8.decode(b.sublist(s, i), allowMalformed: true);
        i++;
        if (i + 8 > b.length) break;
        final score = bd.getInt32(i, Endian.little);
        final secs = bd.getFloat32(i + 4, Endian.little);
        i += 8;
        list.add(PlayerInfo(name, score, secs));
      }
      completer.complete(list);
    }

    sub = sock.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = sock!.receive();
      if (d == null) return;
      final b = d.data;
      if (b.length < 6) return;
      // multi-packet response (big player lists)
      if (b[0] == 0xFE && b[1] == 0xFF && b[2] == 0xFF && b[3] == 0xFF) {
        if (b.length < 13) return;
        final total = b[8];
        parts[b[9]] = b.sublist(12);
        if (parts.length == total) {
          final all = <int>[];
          for (var k = 0; k < total; k++) {
            all.addAll(parts[k] ?? []);
          }
          parse(all);
          sub.cancel();
        }
        return;
      }
      if (b[4] == 0x41 && b.length >= 9) {
        sock.send([...base, ...b.sublist(5, 9)], addr, kPort);
        return;
      }
      parse(b);
      sub.cancel();
    });
    return await completer.future.timeout(const Duration(seconds: 4), onTimeout: () => null);
  } catch (_) {
    return null;
  } finally {
    sock?.close();
  }
}

// ====== DATA ======
// Built-in fallback (A to L of GFL's workshop collection). The app loads the full live list at startup.
const List<String> kFallbackMaps = [
  'ze__hell_p',
  'ze_1_schizo',
  'ze_2012_p',
  'ze_2049',
  'ze_30_seconds_p',
  'ze_8bit',
  'ze_a_e_s_t_h_e_t_i_c_p',
  'ze_abandoned_industry_p',
  'ze_abandoned_project_p',
  'ze_aepp_nano_grid2_p',
  'ze_alien_mountain_escape_p',
  'ze_alien_shooter',
  'ze_ancient_wrath_p',
  'ze_antartika_p',
  'ze_apollo_p',
  'ze_aragami_p',
  'ze_arcana_heart',
  'ze_arctic_escape_p',
  'ze_artika_base_p',
  'ze_ashen_keep_p',
  'ze_asiangirl_mm11el4nu4cp2io1yv7_r_p',
  'ze_atix_apocalypse_p',
  'ze_atix_panic_2017_p',
  'ze_atos',
  'ze_avalanche_reboot',
  'ze_azathoth_p',
  'ze_aztecnoob_p',
  'ze_backrooms',
  'ze_backrooms_deathbed_v1',
  'ze_backrooms_insomnia',
  'ze_backrooms_lenny',
  'ze_barrage_p',
  'ze_bathroom',
  'ze_best_korea_p',
  'ze_bible_adventure_ot_p',
  'ze_bigboo_n64',
  'ze_biohazard_manor_004_p',
  'ze_biohazard2_rpd_004_p',
  'ze_bioluminescent',
  'ze_bisounours_party',
  'ze_black_lion_p',
  'ze_blackmesa_escape_p',
  'ze_blue_magic_castle',
  'ze_boacceho_p',
  'ze_boatescape101_p',
  'ze_bp-infested-prison_p',
  'ze_breakable_p',
  'ze_bunny_story',
  'ze_castle_bridge_p',
  'ze_castlevania',
  'ze_cat_girl_hentai',
  'ze_celestial_ops',
  'ze_chicago_bean_gassy_fart_life',
  'ze_chicken_lords_tower_p',
  'ze_christmas_infection_p',
  'ze_christmas_p',
  'ze_chronus_p',
  'ze_circle',
  'ze_colorlicouspilar_p',
  'ze_colors_p',
  'ze_cookie',
  'ze_crashbandicoot_p',
  'ze_crazy_christmas_p',
  'ze_crazy_escape_p',
  'ze_cursed_bear_tales',
  'ze_dangerous_waters_p',
  'ze_dark_souls',
  'ze_deadcore',
  'ze_death_star_escape_p',
  'ze_deathinvain_palace',
  'ze_deepice_p',
  'ze_defense3002_p',
  'ze_descent_into_cerberon_p',
  'ze_desperate_soul',
  'ze_diddle',
  'ze_djinn',
  'ze_dnb_realms_a1',
  'ze_doomglaven',
  'ze_downstairs',
  'ze_dragonball_snakeway_p',
  'ze_dreamin',
  'ze_dystopia_p',
  'ze_einstein_p',
  'ze_eizures_b1_1',
  'ze_elevator_escape_p',
  'ze_elmas',
  'ze_emerald',
  'ze_empirecity_p',
  'ze_enick_p',
  'ze_escape_the_eye_p',
  'ze_eternal_grove',
  'ze_evernight',
  'ze_evil_mansion_p',
  'ze_exchange_innovation_p',
  'ze_exit_this_earths_atomosphere_p',
  'ze_fapescape_p',
  'ze_fapescape_rote_p',
  'ze_farmhouse_p',
  'ze_fast_escape_p',
  'ze_ffvii_cosmo_canyon_v5_p',
  'ze_ffvii_fako_reactor',
  'ze_ffvii_mako_reactor_v5_p',
  'ze_ffvii_mako_reactor_v6_p',
  'ze_ffvii_temple_ancient',
  'ze_ffxii_bestersand_beta',
  'ze_ffxii_mt_bur_omisace_v6',
  'ze_ffxii_paramina_rift',
  'ze_ffxii_westersand_v8',
  'ze_ffxiv_wanderers_palace_v6_2',
  'ze_fireboy_watergirl',
  'ze_firewall_laboratory_part1_p',
  'ze_firewall_laboratory_part2_p',
  'ze_flex_p',
  'ze_forestbunkers_p',
  'ze_forius_just_run_p',
  'ze_forsaken_temple',
  'ze_frostdrake_tower_p',
  'ze_frozentemple_p',
  'ze_funny_runner',
  'ze_games_p',
  'ze_gods_wrath_p',
  'ze_goldeneye_64',
  'ze_golubenkaya_meow',
  'ze_grau_p',
  'ze_greece_escape_p',
  'ze_greencity_p',
  'ze_gris_p',
  'ze_halloween_house_p',
  'ze_haunted_lab_escape_p',
  'ze_hazard_escape_p',
  'ze_hidden_fortress_p',
  'ze_hold_em_p',
  'ze_hydroponic_garden',
  'ze_hypernova_p',
  'ze_iamlegend_p',
  'ze_ice_hold_p',
  'ze_icebreaker',
  'ze_icecap_escape_p',
  'ze_iceskate',
  'ze_idk_what_to_call_this',
  'ze_imperium',
  'ze_inboxed_p',
  'ze_indiana_jones_004_p',
  'ze_industrial_dejavu',
  'ze_infested-industry_p',
  'ze_infiltration_final_p',
  'ze_interception_p',
  'ze_isla_nublar_p',
  'ze_journey_p',
  'ze_jp_trip_k1ne2',
  'ze_jurassic_park_story_p',
  'ze_jurassicpark_escape_p',
  'ze_jurassicpark_p',
  'ze_kaffe_escape_p',
  'ze_kage_cs2',
  'ze_kebab_immigrant',
  'ze_kitchen',
  'ze_knife_stray_p',
  'ze_kraznov_poopata_p',
  'ze_kz',
  'ze_l0v0l_p',
  'ze_last_man_standing_p',
  'ze_lazers_p',
  'ze_lego',
  'ze_lemonade',
  'ze_lemonysnickets_p',
  'ze_lethal_company',
  'ze_licciana_escape_p',
  'ze_lila_panic_escape_p',
  'ze_lolxd_p_final',
  'ze_loom',
  'ze_lorem_ipsum_p',
  'ze_lotr_helms_deep_p',
  'ze_lotr_isengard',
  'ze_lotr_minas_tiret_p',
  'ze_lotr_minas_tirith_p',
];

class LogEntry {
  final String map, result, date;
  LogEntry(this.map, this.result, this.date);
  Map<String, String> toJson() => {'m': map, 'r': result, 'd': date};
  static LogEntry fromJson(Map<String, dynamic> j) => LogEntry(j['m'], j['r'], j['d']);
}

// ====== HUB ======
class Hub extends StatefulWidget {
  const Hub({super.key});
  @override
  State<Hub> createState() => _HubState();
}

class _HubState extends State<Hub> with SingleTickerProviderStateMixin {
  late TabController tabs;
  Timer? poll;
  ServerInfo? info;
  bool offline = false;
  String lastMap = '';
  final List<String> activity = [];

  // alerts
  int alertCount = 20;
  String favMap = 'ze_imperium';
  bool alertsOn = true;
  String banner = '';
  bool countAlerted = false;

  // log
  List<LogEntry> log = [];
  final mapCtl = TextEditingController();

  // scheduler
  DateTime? gameNight;

  // players
  List<PlayerInfo> players = [];
  Map<String, int> lastScores = {};
  final Map<String, String> marks = {}; // name -> 'ZOMBIE' (default is human)
  final Set<String> jumps = {};

  // admins (matched by name, since the server query can't tell who is admin)
  String adminNames = '';
  final adminCtl = TextEditingController();
  DateTime? mapStart;

  // maps
  List<String> allMaps = kFallbackMaps;
  bool mapsLive = false;
  bool mapsLoading = false;
  String mapQuery = '';
  final searchCtl = TextEditingController();

  SharedPreferences? prefs;

  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 6, vsync: this);
    _load().then((_) => _loadMaps());
    _refresh();
    poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    poll?.cancel();
    tabs.dispose();
    mapCtl.dispose();
    adminCtl.dispose();
    searchCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    prefs = await SharedPreferences.getInstance();
    setState(() {
      alertCount = prefs!.getInt('alertCount') ?? 20;
      favMap = prefs!.getString('favMap') ?? 'ze_imperium';
      alertsOn = prefs!.getBool('alertsOn') ?? true;
      final raw = prefs!.getString('log');
      if (raw != null) {
        log = (jsonDecode(raw) as List).map((e) => LogEntry.fromJson(e)).toList();
      }
      final gn = prefs!.getString('gameNight');
      if (gn != null) gameNight = DateTime.tryParse(gn);
      adminNames = prefs!.getString('admins') ?? '';
      adminCtl.text = adminNames;
      final mc = prefs!.getStringList('mapsCache');
      if (mc != null && mc.length > 50) allMaps = mc;
    });
  }

  void _saveLog() => prefs?.setString('log', jsonEncode(log.map((e) => e.toJson()).toList()));

  String _ts() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(n.hour)}:${p(n.minute)}:${p(n.second)}';
  }

  bool _isAdmin(String name) {
    final list = adminNames
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty);
    final n = name.toLowerCase();
    return list.any((a) => n.contains(a));
  }

  String _fmt(double secs) {
    final m = (secs / 60).floor();
    return m >= 60 ? '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m' : '${m}m';
  }

  String _mapTime() {
    if (mapStart == null) return '--';
    final m = DateTime.now().difference(mapStart!).inMinutes;
    return m >= 60 ? '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m' : '${m}m';
  }

  Future<void> _refreshPlayers() async {
    final list = await queryPlayers();
    if (!mounted || list == null) return;
    setState(() {
      final clean = list.where((p) => p.name.isNotEmpty).toList();
      final names = clean.map((p) => p.name).toSet();
      final prev = lastScores.keys.toSet();
      if (lastScores.isNotEmpty) {
        for (final n in names.difference(prev)) {
          _addActivity('[${_ts()}] join: $n');
          if (alertsOn && _isAdmin(n)) _fire('ADMIN JOINED: $n');
        }
        for (final n in prev.difference(names)) {
          _addActivity('[${_ts()}] left: $n');
        }
      }
      jumps.clear();
      for (final p in clean) {
        final old = lastScores[p.name];
        if (old != null && p.score - old >= 2) jumps.add(p.name);
      }
      lastScores = {for (final p in clean) p.name: p.score};
      marks.removeWhere((k, v) => !names.contains(k));
      clean.sort((a, b) => b.score.compareTo(a.score));
      players = clean;
    });
  }

  bool _busy = false;

  Future<void> _refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      await _doRefresh();
    } finally {
      _busy = false;
    }
  }

  Future<void> _doRefresh() async {
    final results = await Future.wait<Object?>([_refreshPlayers(), queryServer()]);
    final r = results[1] as ServerInfo?;
    if (!mounted) return;
    setState(() {
      if (r == null) {
        if (!offline) _addActivity('[${_ts()}] no response from server');
        offline = true;
      } else {
        offline = false;
        info = r;
        _addActivity('[${_ts()}] ${r.players}/${r.maxPlayers} | ${r.pingMs}ms | ${r.map}');
        if (r.map != lastMap) {
          _addActivity('[${_ts()}] map: ${r.map}');
          if (alertsOn && r.map.toLowerCase() == favMap.toLowerCase()) _fire('FAV MAP LIVE: ${r.map}');
          lastMap = r.map;
          mapStart = DateTime.now();
          marks.clear();
        }
        if (alertsOn && r.players >= alertCount) {
          if (!countAlerted) {
            _fire('${r.players} PLAYERS ONLINE');
            countAlerted = true;
          }
        } else {
          countAlerted = false;
        }
      }
    });
  }

  void _addActivity(String s) {
    activity.insert(0, s);
    if (activity.length > 200) activity.removeLast();
  }

  void _fire(String msg) {
    banner = msg;
    HapticFeedback.heavyImpact();
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) setState(() => banner = '');
    });
  }

  // ====== UI ======
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A1040), Color(0xFF3B1C6B), Color(0xFF0F3057)],
          ),
        ),
        child: Stack(children: [
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _SparklePainter()))),
        SafeArea(
        child: Column(
          children: [
            _header(),
            if (banner.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(color: kYellow, borderRadius: BorderRadius.circular(16)),
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('✧ $banner ✧',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
              ),
            Expanded(
              child: TabBarView(
                controller: tabs,
                physics: const NeverScrollableScrollPhysics(),
                children: [_statusTab(), _playersTab(), _alertsTab(), _mapsTab(), _logTab(), _schedTab()],
              ),
            ),
            Container(
              decoration: BoxDecoration(color: const Color(0x661E1450), border: Border(top: BorderSide(color: kPink.withOpacity(0.5), width: 1))),
              child: TabBar(
                controller: tabs,
                indicatorColor: kPink,
                labelColor: kPink,
                unselectedLabelColor: Colors.white38,
                labelPadding: EdgeInsets.zero,
                labelStyle: const TextStyle(fontSize: 10),
                unselectedLabelStyle: const TextStyle(fontSize: 10),
                tabs: const [
                  Tab(icon: Icon(Icons.radar, size: 20), text: 'STATUS'),
                  Tab(icon: Icon(Icons.groups, size: 20), text: 'PLAYERS'),
                  Tab(icon: Icon(Icons.notifications_active, size: 20), text: 'ALERTS'),
                  Tab(icon: Icon(Icons.map, size: 20), text: 'MAPS'),
                  Tab(icon: Icon(Icons.receipt_long, size: 20), text: 'LOG'),
                  Tab(icon: Icon(Icons.event, size: 20), text: 'NIGHT'),
                ],
              ),
            ),
          ],
        ),
      ),
        ]),
      ),
    );
  }

  Widget _header() => Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xDDFF8FCB), Color(0xDD8E7BFF)]),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [BoxShadow(color: kPink.withOpacity(0.35), blurRadius: 16)],
        ),
        child: Row(
          children: [
            const Icon(Icons.auto_awesome, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            const Text('ZE HUB ♡',
                style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: 1)),
            const Spacer(),
            Icon(Icons.circle, size: 10, color: offline ? Colors.black54 : Colors.white),
            const SizedBox(width: 6),
            Text(offline ? 'OFFLINE' : 'ONLINE',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget _panel({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kPanel,
          border: Border.all(color: kPink.withOpacity(0.45), width: 1.2),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: kPink.withOpacity(0.18), blurRadius: 14)],
        ),
        child: child,
      );

  Widget _stat(String label, String value, {Color color = kGreen}) => Expanded(
        child: _panel(
          child: Column(
            children: [
              Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
              const SizedBox(height: 4),
              FittedBox(
                child: Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      );

  // --- STATUS ---
  Widget _statusTab() {
    final i = info;
    final full = i != null && i.maxPlayers > 0 && i.players >= i.maxPlayers - 2;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          _panel(
            child: Text(i?.name ?? 'querying $kHost:$kPort ...',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kGreen, fontSize: 13)),
          ),
          const SizedBox(height: 8),
          Row(children: [
            _stat('PLAYERS', i == null ? '--' : '${i.players}/${i.maxPlayers}'),
            const SizedBox(width: 8),
            _stat('PING', i == null ? '--' : '${i.pingMs}ms'),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _stat('MAP TIME', _mapTime()),
            const SizedBox(width: 8),
            _stat('ADMINS', '${players.where((p) => _isAdmin(p.name)).length}',
                color: players.any((p) => _isAdmin(p.name)) ? kPink : Colors.white38),
          ]),
          const SizedBox(height: 8),
          _panel(
            child: Row(children: [
              const Text('MAP> ', style: TextStyle(color: Colors.white54)),
              Expanded(
                child: Text(i?.map ?? '--',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kYellow, fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ACTIVITY LOG',
                      style: TextStyle(
                          color: full ? kFullRed : Colors.white54,
                          fontSize: 11,
                          shadows: full ? kRedGlow : null)),
                  const SizedBox(height: 6),
                  Expanded(
                    child: LayoutBuilder(builder: (ctx, c) {
                      final n = (c.maxHeight / 17).floor().clamp(1, 60);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [for (final a in activity.take(n)) SizedBox(height: 17, child: _logLine(a, full))],
                      );
                    }),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          const SizedBox(height: 88, child: ChibiRow()),
        ],
      ),
    );
  }

  // colors only the map name yellow; whole log glows red when the server is nearly full
  Widget _logLine(String line, bool full) {
    final isStatus = line.contains(' | ');
    TextStyle st(Color c) => TextStyle(
          color: full ? kFullRed : (isStatus ? Colors.white60 : c),
          fontSize: 12,
          shadows: full ? kRedGlow : null,
        );
    final idx = line.indexOf('map: ');
    if (idx == -1) {
      return Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: st(kGreen));
    }
    return Text.rich(TextSpan(children: [
      TextSpan(text: line.substring(0, idx + 5), style: st(kGreen)),
      TextSpan(text: line.substring(idx + 5), style: st(kYellow)),
    ]), maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  // --- PLAYERS ---
  Widget _playersTab() {
    final zombies = players.where((p) => marks[p.name] == 'ZOMBIE').length;
    final humans = players.length - zombies;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(children: [
            _stat('HUMANS', '$humans'),
            const SizedBox(width: 8),
            _stat('ZOMBIES', '$zombies', color: kViolet),
          ]),
          const SizedBox(height: 8),
          Expanded(
            child: _panel(
              child: LayoutBuilder(builder: (ctx, c) {
                const rowH = 32.0;
                final fit = ((c.maxHeight - 4) / rowH).floor().clamp(1, 64);
                final overflow = players.length > fit;
                final shown = players.take(overflow ? fit - 1 : fit).toList();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (players.isEmpty)
                      const Text('no player data yet (・・?)', style: TextStyle(color: Colors.white38)),
                    for (final p in shown)
                      InkWell(
                        onTap: () => setState(() {
                          if (marks[p.name] == 'ZOMBIE') {
                            marks.remove(p.name);
                          } else {
                            marks[p.name] = 'ZOMBIE';
                          }
                        }),
                        child: SizedBox(
                          height: rowH,
                          child: Row(children: [
                            Icon(
                              marks[p.name] == 'ZOMBIE' ? Icons.coronavirus : Icons.person,
                              size: 16,
                              color: marks[p.name] == 'ZOMBIE' ? kViolet : kGreen,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(p.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: marks[p.name] == 'ZOMBIE' ? kViolet : kGreen,
                                    fontSize: 13,
                                  )),
                            ),
                            if (_isAdmin(p.name))
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(Icons.shield, size: 14, color: kPink),
                              ),
                            if (jumps.contains(p.name))
                              const Text('▲ ', style: TextStyle(color: kYellow, fontSize: 12)),
                            Text('${p.score}  ', style: const TextStyle(color: kYellow, fontSize: 12)),
                            Text(_fmt(p.secs),
                                style: const TextStyle(color: Colors.white38, fontSize: 11)),
                          ]),
                        ),
                      ),
                    if (overflow)
                      Text('+${players.length - shown.length} more',
                          style: const TextStyle(color: Colors.white38, fontSize: 12)),
                  ],
                );
              }),
            ),
          ),
          const SizedBox(height: 6),
          const Text('Tap a player to flip HUMAN / ZOMBIE.  ▲ = score jumped (maybe infected someone).',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 10)),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => setState(() => marks.clear()),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: kPink), foregroundColor: kPink, shape: const StadiumBorder()),
              child: const Text('NEW ROUND (ALL HUMAN)'),
            ),
          ),
        ],
      ),
    );
  }

  // --- ALERTS ---
  Widget _alertsTab() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          _panel(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeColor: kGreen,
              title: const Text('ALERTS ENABLED', style: TextStyle(color: kGreen)),
              value: alertsOn,
              onChanged: (v) {
                setState(() => alertsOn = v);
                prefs?.setBool('alertsOn', v);
              },
            ),
          ),
          const SizedBox(height: 8),
          _panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('PLAYER COUNT TRIGGER: $alertCount+', style: const TextStyle(color: kGreen)),
                Slider(
                  value: alertCount.toDouble(),
                  min: 1,
                  max: 64,
                  divisions: 63,
                  activeColor: kGreen,
                  onChanged: (v) => setState(() => alertCount = v.round()),
                  onChangeEnd: (v) => prefs?.setInt('alertCount', v.round()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('FAVORITE MAP TRIGGER', style: TextStyle(color: kGreen)),
                const SizedBox(height: 6),
                Text(favMap, style: const TextStyle(color: kYellow, fontSize: 16, fontWeight: FontWeight.bold)),
                const Text('Tap the star on a map in the MAPS tab to change it.',
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('ADMIN NAMES (comma separated)', style: TextStyle(color: kPink)),
                const SizedBox(height: 6),
                TextField(
                  controller: adminCtl,
                  style: const TextStyle(color: kYellow, fontSize: 13),
                  onChanged: (v) {
                    setState(() => adminNames = v);
                    prefs?.setString('admins', v);
                  },
                  decoration: InputDecoration(
                    hintText: 'name1, name2',
                    hintStyle: const TextStyle(color: Colors.white30),
                    isDense: true,
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: kPink.withOpacity(0.5))),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kPink)),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          const Text('Alerts fire while the app is open (banner + vibration).',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
    );
  }

  // --- MAPS ---
  Future<void> _loadMaps() async {
    if (!mounted || mapsLoading) return;
    setState(() => mapsLoading = true);
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final req = await client.getUrl(Uri.parse(kMapCollectionUrl));
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36');
      final res = await req.close().timeout(const Duration(seconds: 25));
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        final found = <String, String>{};
        for (final m in RegExp(r'\bze_[A-Za-z0-9_\-]+').allMatches(body)) {
          final n = m.group(0)!;
          if (n.length > 5) found.putIfAbsent(n.toLowerCase(), () => n);
        }
        if (found.length >= 50) {
          final list = found.values.toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          prefs?.setStringList('mapsCache', list);
          if (mounted) {
            setState(() {
              allMaps = list;
              mapsLive = true;
            });
          }
        }
      }
      client.close();
    } catch (_) {
      // keep the built-in or cached list
    } finally {
      if (mounted) setState(() => mapsLoading = false);
    }
  }

  Widget _mapsTab() {
    final q = mapQuery.trim().toLowerCase();
    final list = q.isEmpty ? allMaps : allMaps.where((m) => m.toLowerCase().contains(q)).toList();
    final now = (info?.map ?? '').toLowerCase();
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          TextField(
            controller: searchCtl,
            style: const TextStyle(color: kYellow, fontSize: 14),
            onChanged: (v) => setState(() => mapQuery = v),
            decoration: InputDecoration(
              hintText: 'search ${allMaps.length} maps',
              hintStyle: const TextStyle(color: Colors.white30),
              prefixIcon: const Icon(Icons.search, color: kPink, size: 20),
              isDense: true,
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: kPink.withOpacity(0.5))),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: kPink)),
            ),
          ),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: Text('${list.length} shown  •  ${mapsLive ? 'live GFL list' : 'built-in list (loading full list...)'}',
                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
            ),
            if (mapsLoading)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kPink))
            else
              InkWell(onTap: _loadMaps, child: const Icon(Icons.refresh, color: kPink, size: 20)),
          ]),
          const SizedBox(height: 6),
          Expanded(
            child: _panel(
              child: list.isEmpty
                  ? const Text('no maps match', style: TextStyle(color: Colors.white38))
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: list.length,
                      itemExtent: 36,
                      itemBuilder: (ctx, i) {
                        final m = list[i];
                        final isNow = m.toLowerCase() == now;
                        final isFav = m.toLowerCase() == favMap.toLowerCase();
                        return Row(children: [
                          InkWell(
                            onTap: () {
                              setState(() => favMap = m);
                              prefs?.setString('favMap', m);
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Icon(isFav ? Icons.star : Icons.star_border,
                                  color: isFav ? kPink : Colors.white38, size: 20),
                            ),
                          ),
                          Expanded(
                            child: Text(m,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: isNow ? kYellow : kGreen,
                                    fontSize: 13,
                                    fontWeight: isNow ? FontWeight.bold : FontWeight.normal)),
                          ),
                          if (isNow)
                            const Text('NOW', style: TextStyle(color: kYellow, fontSize: 11, fontWeight: FontWeight.bold)),
                        ]);
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  // --- LOG ---
  Widget _logTab() {
    final wins = log.where((e) => e.result == 'ESCAPED').length;
    final losses = log.where((e) => e.result == 'DIED').length;
    final infected = log.where((e) => e.result == 'INFECTED').length;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(children: [
            _stat('ESCAPES', '$wins'),
            const SizedBox(width: 8),
            _stat('DIED', '$losses', color: kRose),
            const SizedBox(width: 8),
            _stat('INFECTED', '$infected', color: kViolet),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: mapCtl,
            style: const TextStyle(color: kYellow),
            decoration: InputDecoration(
              hintText: info?.map ?? 'map name',
              hintStyle: const TextStyle(color: Colors.white30),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: kPink.withOpacity(0.5))),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: kPink)),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _logBtn('ESCAPED', kGreen)),
            const SizedBox(width: 8),
            Expanded(child: _logBtn('DIED', kRose)),
            const SizedBox(width: 8),
            Expanded(child: _logBtn('INFECTED', kViolet)),
          ]),
          const SizedBox(height: 8),
          Expanded(
            child: _panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('RECENT', style: TextStyle(color: Colors.white54, fontSize: 11)),
                  const SizedBox(height: 6),
                  for (final e in log.reversed.take(6))
                    Text.rich(TextSpan(children: [
                      TextSpan(text: '${e.date}  ', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                      TextSpan(text: e.map, style: const TextStyle(color: kYellow, fontSize: 12)),
                      TextSpan(
                        text: '  ${e.result}',
                        style: TextStyle(
                          color: e.result == 'ESCAPED'
                              ? kGreen
                              : (e.result == 'INFECTED' ? kViolet : kRose),
                          fontSize: 12,
                        ),
                      ),
                    ])),
                ],
              ),
            ),
          ),
          if (log.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() => log.removeLast());
                _saveLog();
              },
              child: const Text('UNDO LAST', style: TextStyle(color: Colors.white38)),
            ),
        ],
      ),
    );
  }

  Widget _logBtn(String result, Color c) => OutlinedButton(
        onPressed: () {
          final m = mapCtl.text.trim().isNotEmpty ? mapCtl.text.trim() : (info?.map ?? 'unknown');
          final n = DateTime.now();
          setState(() => log.add(LogEntry(m, result, '${n.month}/${n.day}')));
          _saveLog();
          mapCtl.clear();
          FocusScope.of(context).unfocus();
        },
        style: OutlinedButton.styleFrom(side: BorderSide(color: c), foregroundColor: c, shape: const StadiumBorder()),
        child: Text(result),
      );

  // --- SCHEDULER ---
  Widget _schedTab() {
    String countdown = 'NOT SET';
    if (gameNight != null) {
      final d = gameNight!.difference(DateTime.now());
      if (d.isNegative) {
        countdown = 'IT\'S GAME TIME';
      } else {
        countdown = '${d.inDays}d ${d.inHours % 24}h ${d.inMinutes % 60}m';
      }
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          _panel(
            child: Column(children: [
              const Text('NEXT GAME NIGHT', style: TextStyle(color: Colors.white54, fontSize: 11)),
              const SizedBox(height: 10),
              FittedBox(
                child: Text(countdown, style: const TextStyle(color: kGreen, fontSize: 32, fontWeight: FontWeight.bold)),
              ),
              if (gameNight != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(gameNight.toString().substring(0, 16), style: const TextStyle(color: kYellow)),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _pickDate,
              style: OutlinedButton.styleFrom(side: const BorderSide(color: kPink), foregroundColor: kPink, shape: const StadiumBorder()),
              child: const Text('SET DATE & TIME'),
            ),
          ),
          if (gameNight != null)
            TextButton(
              onPressed: () {
                setState(() => gameNight = null);
                prefs?.remove('gameNight');
              },
              child: const Text('CLEAR', style: TextStyle(color: Colors.white38)),
            ),
          const Spacer(),
          const Text('Countdown updates when you open this tab.',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 20, minute: 0));
    if (t == null) return;
    final dt = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    setState(() => gameNight = dt);
    prefs?.setString('gameNight', dt.toIso8601String());
  }
}


// ====== BACKGROUND SPARKLES ======
class _SparklePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(7);
    final paint = Paint();
    for (var i = 0; i < 40; i++) {
      final x = rnd.nextDouble() * size.width;
      final y = rnd.nextDouble() * size.height;
      final r = 0.8 + rnd.nextDouble() * 1.8;
      final base = i % 3 == 0 ? kPink : (i % 3 == 1 ? kGreen : Colors.white);
      paint.color = base.withOpacity(0.25 + rnd.nextDouble() * 0.4);
      final path = Path()
        ..moveTo(x, y - r * 2.2)
        ..quadraticBezierTo(x, y, x + r * 2.2, y)
        ..quadraticBezierTo(x, y, x, y + r * 2.2)
        ..quadraticBezierTo(x, y, x - r * 2.2, y)
        ..quadraticBezierTo(x, y, x, y - r * 2.2);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}


// ====== CHIBI GIRLS (5 different animations, drawn in code) ======
class ChibiRow extends StatefulWidget {
  const ChibiRow({super.key});
  @override
  State<ChibiRow> createState() => _ChibiRowState();
}

class _ChibiRowState extends State<ChibiRow> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 60))..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value * 60.0;
        return Row(
          children: [
            for (var i = 0; i < 5; i++)
              Expanded(child: CustomPaint(painter: _ChibiPainter(i, t), child: const SizedBox.expand())),
          ],
        );
      },
    );
  }
}

class _ChibiPainter extends CustomPainter {
  final int kind;
  final double t;
  _ChibiPainter(this.kind, this.t);

  static const _hair = [Color(0xFFFF8FCB), Color(0xFF7DEBFF), Color(0xFFB98BFF), Color(0xFFFFE27A), Color(0xFFFF6B8B)];
  static const _outfit = [Color(0xFF7DEBFF), Color(0xFFFF8FCB), Color(0xFFFFE27A), Color(0xFFB98BFF), Color(0xFFFFFFFF)];
  static const _skin = Color(0xFFFFE3D0);
  static const _ink = Color(0xFF2B1B4A);

  double _s(double hz) => math.sin(2 * math.pi * hz * t);

  @override
  void paint(Canvas canvas, Size size) {
    final u = math.min(size.width / 64, size.height / 92);
    canvas.save();
    canvas.translate(size.width / 2, size.height - 2);
    canvas.scale(u, u);
    _draw(canvas);
    canvas.restore();
  }

  void _draw(Canvas canvas) {
    final hairC = _hair[kind];
    final outfit = _outfit[kind];
    final p = (t * 0.5) % 1.0;
    double dy = 0, sx = 1, sy = 1, rot = 0, tilt = 0, armL = 0.3, armR = 0.3, j = 0;
    int eyes = 0; // 0 open, 1 closed, 2 happy
    bool mouthOpen = false, face = true;

    switch (kind) {
      case 0: // waving
        dy = _s(1) * 1.2;
        armR = 2.5 + _s(1.5) * 0.45;
        armL = 0.25;
        break;
      case 1: // jumping
        j = _s(0.75).abs();
        dy = -j * 13;
        sy = 1 - 0.1 * (1 - math.min(1.0, j * 4));
        sx = 1 + (1 - sy) * 0.6;
        armL = 2.2 + j * 0.5;
        armR = 2.2 + j * 0.5;
        eyes = 2;
        mouthOpen = true;
        break;
      case 2: // dancing sway
        rot = _s(0.75) * 0.14;
        tilt = -rot * 1.6;
        armL = 0.9 + _s(0.75) * 0.7;
        armR = 0.9 - _s(0.75) * 0.7;
        break;
      case 3: // head tilt + blink + sparkles
        tilt = _s(0.5) * 0.16;
        armL = 0.8 + _s(1.25) * 0.15;
        armR = 0.8 + _s(1.25) * 0.15;
        eyes = ((t % 2.0) > 1.8) ? 1 : 0;
        break;
      default: // spin, then peace sign with hearts
        if (p < 0.35) {
          sx = math.cos(p / 0.35 * 2 * math.pi);
          face = sx > 0;
          armL = 0.6;
          armR = 0.6;
        } else {
          armR = 2.6 + _s(1.5) * 0.12;
          armL = 0.6;
          dy = _s(1) * 1.0;
          eyes = 2;
          mouthOpen = true;
        }
    }

    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 26 * (1 - j * 0.3), height: 5),
      Paint()..color = const Color(0x40000000),
    );

    canvas.save();
    canvas.translate(0, dy);
    canvas.scale(sx, sy);
    canvas.rotate(rot);

    _hairBack(canvas, hairC);

    final fill = Paint()..style = PaintingStyle.fill;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // legs and shoes
    line
      ..color = _skin
      ..strokeWidth = 4.2;
    canvas.drawLine(const Offset(-4, -14), const Offset(-4, -3), line);
    canvas.drawLine(const Offset(4, -14), const Offset(4, -3), line);
    fill.color = _ink;
    canvas.drawOval(Rect.fromCenter(center: const Offset(-4.5, -1.5), width: 8, height: 4.5), fill);
    canvas.drawOval(Rect.fromCenter(center: const Offset(4.5, -1.5), width: 8, height: 4.5), fill);

    // dress
    final dress = Path()
      ..moveTo(-7, -36)
      ..lineTo(7, -36)
      ..lineTo(14, -14)
      ..quadraticBezierTo(0, -10, -14, -14)
      ..close();
    fill.color = outfit;
    canvas.drawPath(dress, fill);

    // neck bow
    fill.color = hairC;
    canvas.drawPath(
        Path()
          ..moveTo(0, -35)
          ..lineTo(-5, -39)
          ..lineTo(-5, -31)
          ..close(),
        fill);
    canvas.drawPath(
        Path()
          ..moveTo(0, -35)
          ..lineTo(5, -39)
          ..lineTo(5, -31)
          ..close(),
        fill);

    // arms
    _arm(canvas, -8, armL, true, outfit);
    _arm(canvas, 8, armR, false, outfit);

    // head
    canvas.save();
    canvas.translate(0, -32);
    canvas.rotate(tilt);
    canvas.translate(0, -20);

    if (kind == 3) {
      fill.color = hairC;
      canvas.drawCircle(const Offset(0, -26), 8.5, fill);
      fill.color = _outfit[3];
      canvas.drawRect(Rect.fromCenter(center: const Offset(0, -19), width: 9, height: 2.5), fill);
    }

    fill.color = _skin;
    canvas.drawCircle(Offset.zero, 19, fill);

    if (face) {
      fill.color = hairC;
      canvas.drawOval(Rect.fromCenter(center: const Offset(-18, 6), width: 7, height: 20), fill);
      canvas.drawOval(Rect.fromCenter(center: const Offset(18, 6), width: 7, height: 20), fill);

      final ink = Paint()
        ..color = _ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round;
      for (final sgn in [-1.0, 1.0]) {
        final c = Offset(sgn * 7.5, 5);
        if (eyes == 0) {
          canvas.drawOval(Rect.fromCenter(center: c, width: 7, height: 10), Paint()..color = _ink);
          canvas.drawOval(
              Rect.fromCenter(center: c + const Offset(0, 1.6), width: 5, height: 5), Paint()..color = hairC);
          canvas.drawCircle(c + const Offset(-1.3, -2.2), 1.7, Paint()..color = Colors.white);
          canvas.drawCircle(c + const Offset(1.2, 2.4), 0.9, Paint()..color = Colors.white70);
        } else if (eyes == 1) {
          canvas.drawPath(
              Path()
                ..moveTo(c.dx - 3.5, c.dy)
                ..quadraticBezierTo(c.dx, c.dy + 2.5, c.dx + 3.5, c.dy),
              ink);
        } else {
          canvas.drawPath(
              Path()
                ..moveTo(c.dx - 3.5, c.dy + 2)
                ..quadraticBezierTo(c.dx, c.dy - 4, c.dx + 3.5, c.dy + 2),
              ink);
        }
      }

      fill.color = const Color(0x80FF8FCB);
      canvas.drawOval(Rect.fromCenter(center: const Offset(-12, 10), width: 6, height: 3.5), fill);
      canvas.drawOval(Rect.fromCenter(center: const Offset(12, 10), width: 6, height: 3.5), fill);

      if (mouthOpen) {
        canvas.drawOval(
            Rect.fromCenter(center: const Offset(0, 12.5), width: 5, height: 4), Paint()..color = const Color(0xFF7A2B4E));
      } else {
        ink.strokeWidth = 1.3;
        canvas.drawPath(
            Path()
              ..moveTo(-3, 11.5)
              ..quadraticBezierTo(0, 14.5, 3, 11.5),
            ink);
      }

      // bangs
      final cap = Path()
        ..moveTo(-20, 2)
        ..quadraticBezierTo(-24, -28, 0, -25)
        ..quadraticBezierTo(24, -28, 20, 2)
        ..lineTo(15, -7)
        ..lineTo(10, -2)
        ..lineTo(5, -9)
        ..lineTo(0, -3)
        ..lineTo(-5, -9)
        ..lineTo(-10, -2)
        ..lineTo(-15, -7)
        ..close();
      fill.color = hairC;
      canvas.drawPath(cap, fill);
      fill.color = const Color(0x55FFFFFF);
      canvas.drawOval(Rect.fromCenter(center: const Offset(-8, -17), width: 10, height: 4), fill);

      if (kind == 1) _headBow(canvas, const Offset(13, -19), _outfit[1]);
      if (kind == 4) _headBow(canvas, const Offset(-13, -18), Colors.white);
    } else {
      fill.color = hairC;
      canvas.drawCircle(Offset.zero, 20, fill);
    }
    canvas.restore();

    if (kind == 3) {
      const pos = [Offset(-26, -66), Offset(27, -58), Offset(22, -80)];
      const cols = [Color(0xFFFFE27A), Colors.white, Color(0xFF7DEBFF)];
      for (var i = 0; i < 3; i++) {
        final k = 0.5 + 0.5 * math.sin(2 * math.pi * (0.5 + 0.25 * i) * t + i * 2.0);
        _star(canvas, pos[i], 4.5 * k, cols[i]);
      }
    }

    canvas.restore();

    if (kind == 4 && p >= 0.35) {
      final prog = (p - 0.35) / 0.65;
      final col = kRose.withOpacity((1 - prog).clamp(0.0, 1.0));
      _heart(canvas, Offset(-16, -78 - prog * 14), 5, col);
      _heart(canvas, Offset(17, -72 - prog * 16), 4, col);
    }
  }

  void _hairBack(Canvas canvas, Color hairC) {
    final f = Paint()..color = hairC;
    canvas.drawOval(Rect.fromCenter(center: const Offset(0, -52), width: 42, height: 42), f);
    switch (kind) {
      case 0:
        for (final side in [-1.0, 1.0]) {
          canvas.save();
          canvas.translate(side * 19, -56);
          canvas.rotate(-side * (0.3 + _s(1.5) * 0.15));
          canvas.drawOval(Rect.fromCenter(center: const Offset(0, 13), width: 11, height: 28), f);
          canvas.restore();
        }
        break;
      case 1:
        canvas.save();
        canvas.translate(17, -62);
        canvas.rotate(-(0.7 + _s(1.5) * 0.25));
        canvas.drawOval(Rect.fromCenter(center: const Offset(0, 13), width: 11, height: 30), f);
        canvas.restore();
        break;
      case 2:
        canvas.drawRRect(RRect.fromLTRBR(-21, -58, 21, -12, const Radius.circular(10)), f);
        break;
      default:
        break;
    }
  }

  void _arm(Canvas canvas, double x, double angle, bool left, Color sleeve) {
    canvas.save();
    canvas.translate(x, -33);
    canvas.rotate(left ? angle : -angle);
    final pnt = Paint()
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    pnt.color = _skin;
    pnt.strokeWidth = 4;
    canvas.drawLine(Offset.zero, const Offset(0, 14), pnt);
    pnt.color = sleeve;
    pnt.strokeWidth = 5;
    canvas.drawLine(Offset.zero, const Offset(0, 5), pnt);
    canvas.drawCircle(const Offset(0, 15), 2.8, Paint()..color = _skin);
    canvas.restore();
  }

  void _headBow(Canvas canvas, Offset c, Color col) {
    final f = Paint()..color = col;
    canvas.drawPath(
        Path()
          ..moveTo(c.dx, c.dy)
          ..lineTo(c.dx - 6, c.dy - 5)
          ..lineTo(c.dx - 6, c.dy + 5)
          ..close(),
        f);
    canvas.drawPath(
        Path()
          ..moveTo(c.dx, c.dy)
          ..lineTo(c.dx + 6, c.dy - 5)
          ..lineTo(c.dx + 6, c.dy + 5)
          ..close(),
        f);
    canvas.drawCircle(c, 2, Paint()..color = _ink.withOpacity(0.35));
  }

  void _star(Canvas canvas, Offset c, double r, Color col) {
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx, c.dy, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx, c.dy, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy - r);
    canvas.drawPath(path, Paint()..color = col);
  }

  void _heart(Canvas canvas, Offset c, double s, Color col) {
    final path = Path()
      ..moveTo(c.dx, c.dy + s * 0.9)
      ..cubicTo(c.dx - s * 1.8, c.dy - s * 0.2, c.dx - s * 0.9, c.dy - s * 1.6, c.dx, c.dy - s * 0.6)
      ..cubicTo(c.dx + s * 0.9, c.dy - s * 1.6, c.dx + s * 1.8, c.dy - s * 0.2, c.dx, c.dy + s * 0.9);
    canvas.drawPath(path, Paint()..color = col);
  }

  @override
  bool shouldRepaint(covariant _ChibiPainter oldDelegate) => oldDelegate.t != t || oldDelegate.kind != kind;
}

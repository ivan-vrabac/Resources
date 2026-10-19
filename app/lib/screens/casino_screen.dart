import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart';
import '../models/player_provider.dart';
import '../services/api_service.dart';
import '../widgets/top_banner.dart';

// ── Symbol definitions ─────────────────────────────────────────────────────────
// Indices 0-29 → res128-res157, index 30 → res163, index 31 → jackpot

const _kCasinoResIds = [
  128, 129, 130, 131, 132, 133, 134, 135, 136, 137,
  138, 139, 140, 141, 142, 143, 144, 145, 146, 147,
  148, 149, 150, 151, 152, 153, 154, 155, 156, 157,
  163,
];

Widget _symbolWidget(int idx, {double size = 52}) {
  if (idx < 0 || idx >= 32) return const SizedBox.shrink();
  if (idx == 31) {
    return Image.asset('assets/images/jackpot.png',
        width: size, height: size, fit: BoxFit.contain,
        errorBuilder: (_, __, ___) =>
            Icon(Icons.star, color: Colors.amber, size: size * 0.8));
  }
  return Image.asset('assets/images_res/res${_kCasinoResIds[idx]}.png',
      width: size, height: size, fit: BoxFit.contain,
      errorBuilder: (_, __, ___) =>
          Icon(Icons.casino, color: Colors.white54, size: size * 0.8));
}

// ── Single reel widget ─────────────────────────────────────────────────────────

class _Reel extends StatefulWidget {
  final bool spinning;
  final int finalSymbol;
  final int reelIndex;
  const _Reel({required this.spinning, required this.finalSymbol, required this.reelIndex});
  @override
  _ReelState createState() => _ReelState();
}

class _ReelState extends State<_Reel> {
  final _rng = math.Random();
  int _display = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _display = widget.finalSymbol;
  }

  @override
  void didUpdateWidget(_Reel old) {
    super.didUpdateWidget(old);
    if (widget.spinning && !old.spinning) {
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(milliseconds: 70), (_) {
        if (mounted) setState(() => _display = _rng.nextInt(32));
      });
    } else if (!widget.spinning && old.spinning) {
      _timer?.cancel();
      if (mounted) setState(() => _display = widget.finalSymbol);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isJackpot = _display == 31;
    return Container(
      width: 62,
      height: 78,
      decoration: BoxDecoration(
        color: isJackpot
            ? Colors.amber.withValues(alpha: 0.15)
            : const Color(0xFF1A1A2E),
        border: Border.all(
          color: isJackpot ? Colors.amber : Colors.white24,
          width: isJackpot ? 1.5 : 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 55),
          child: SizedBox(
            key: ValueKey(_display),
            width: 50,
            height: 50,
            child: _symbolWidget(_display, size: 50),
          ),
        ),
      ),
    );
  }
}

// ── Casino screen ──────────────────────────────────────────────────────────────

class CasinoScreen extends StatefulWidget {
  const CasinoScreen({super.key});
  @override
  State<CasinoScreen> createState() => _CasinoScreenState();
}

class _CasinoScreenState extends State<CasinoScreen> {
  // Data from server
  int _casinoLevel  = 0;
  int _maxBet       = 1000000;
  int _spinsLeft    = 0;
  int _gdPacksUsed  = 0;
  String? _resetAt;
  int? _timeLeftSecs;
  int _jackpot      = 100000000000;

  // Spin state
  List<bool> _reelSpinning = List.filled(5, false);
  List<int>  _reelSymbols  = List.filled(5, 0);
  bool _anySpinning = false;
  bool _loading = false;

  // Bet
  int _bet = 1000000;

  // Result display
  String? _lastHand;
  String? _lastHandDisplay;
  int _lastWin = 0;
  bool _jackpotWon = false;

  // Auto-spin state
  bool _autoSpin = false;
  Timer? _autoTimer;

  // Countdown timer
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _snack(String msg, {bool error = false}) =>
      AppNotify.show(context, msg, isError: error);

  Future<void> _loadData() async {
    setState(() => _loading = true);
    final sid = context.read<PlayerProvider>().sid;
    final res = await ApiService.casinoGetData(sid);
    if (!mounted) return;
    setState(() => _loading = false);
    if (res == null || res['err'] != 0) {
      _snack(res?['msg'] ?? 'Failed to load casino', error: true);
      return;
    }
    _applyState(res);
    _startCountdown();
  }

  void _applyState(Map<String, dynamic> r) {
    _casinoLevel  = (r['casino_level'] as num? ?? 0).toInt();
    _maxBet       = (r['max_bet']       as num? ?? 1000000).toInt();
    _spinsLeft    = (r['spins_left']    as num? ?? 0).toInt();
    _gdPacksUsed  = (r['gd_packs_used'] as num? ?? 0).toInt();
    _resetAt      = r['reset_at'] as String?;
    _timeLeftSecs = (r['time_left_secs'] as num?)?.toInt();
    _jackpot      = (r['jackpot']       as num? ?? 100000000000).toInt();
    if (_bet > _maxBet) _bet = _maxBet.clamp(1000000, _maxBet);
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    if (_timeLeftSecs == null || _timeLeftSecs! <= 0) return;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_timeLeftSecs != null && _timeLeftSecs! > 0) {
          _timeLeftSecs = _timeLeftSecs! - 1;
        } else {
          _countdownTimer?.cancel();
          // Timer expired — reload data
          _loadData();
        }
      });
    });
  }

  Future<void> _spin({int count = 1}) async {
    if (_anySpinning || _loading || _spinsLeft <= 0 || _casinoLevel < 1) return;
    final actualCount = count.clamp(1, _spinsLeft);

    setState(() {
      _anySpinning = true;
      _lastHand = null;
      _jackpotWon = false;
    });

    final sid = context.read<PlayerProvider>().sid;
    final res = await ApiService.casinoSpin(sid, _bet, count: actualCount);
    if (!mounted) return;

    if (res == null || res['err'] != 0) {
      setState(() => _anySpinning = false);
      _snack(res?['msg'] ?? 'Spin failed', error: true);
      return;
    }

    // Five of a kind of a luxury item pays a dividend to that item's holders (server-side)
    for (final d in (res['dividends'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final paid = (d['paid'] as num? ?? 0).toInt();
      _snack(paid > 0
          ? '${kItemNames[d['itemID']] ?? 'Luxury item'} dividend: ${d['holders']} holders received ꞓ${_fmtLarge(paid)} in total'
          : 'Five of a kind! Nobody holds ${kItemNames[d['itemID']] ?? 'this item'} — no dividend');
    }

    // Update jackpot and spins
    _jackpot   = (res['jackpot']    as num? ?? _jackpot).toInt();
    _spinsLeft = (res['spins_left'] as num? ?? 0).toInt();

    if (count == 1) {
      // Animate reels
      final reels = (res['reels'] as List? ?? [0,0,0,0,0]).cast<int>();
      final hand       = res['hand']        as String? ?? 'no_pair';
      final handDisplay = res['hand_display'] as String? ?? 'No Pair';
      final win        = (res['win'] as num? ?? 0).toInt();
      final jpWon      = res['jackpot_won'] == true;

      setState(() => _reelSpinning = List.filled(5, true));

      // Stop reels one by one
      for (int i = 0; i < 5; i++) {
        await Future.delayed(Duration(milliseconds: 350 + i * 220));
        if (!mounted) return;
        setState(() {
          _reelSymbols[i]  = reels[i];
          _reelSpinning[i] = false;
        });
      }

      setState(() {
        _anySpinning     = false;
        _lastHand        = hand;
        _lastHandDisplay = handDisplay;
        _lastWin         = win;
        _jackpotWon      = jpWon;
      });

      if (jpWon) {
        _showJackpotDialog(win);
      }

      context.read<PlayerProvider>().refresh();

      if (_autoSpin && _spinsLeft > 0 && !jpWon) {
        _autoTimer = Timer(const Duration(milliseconds: 600), () {
          if (mounted && _autoSpin) _spin();
        });
      } else if (_autoSpin && _spinsLeft == 0) {
        setState(() => _autoSpin = false);
      }
    } else {
      // Batch/instant spin
      setState(() => _anySpinning = false);
      final handCounts = (res['hand_counts'] as Map?)?.cast<String, dynamic>() ?? {};
      final totalBet   = (res['total_bet'] as num? ?? 0).toInt();
      final totalWin   = (res['total_win'] as num? ?? 0).toInt();
      final net        = (res['net']       as num? ?? 0).toInt();
      final jpWon      = res['jackpot_won'] == true;
      context.read<PlayerProvider>().refresh();
      _showBatchResult(handCounts, totalBet, totalWin, net, jpWon);
    }
  }

  void _showJackpotDialog(int amount) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A00),
        title: Row(children: [
          const Icon(Icons.star, color: Colors.amber, size: 28),
          const SizedBox(width: 8),
          const Text('JACKPOT!', style: TextStyle(color: Colors.amber, fontSize: 22,
              fontWeight: FontWeight.bold)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('You hit the jackpot!',
              style: TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 12),
          Text('ꞓ${_fmtLarge(amount)}',
              style: const TextStyle(color: Colors.amber, fontSize: 32,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('has been added to your account.',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
        ]),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            style: FilledButton.styleFrom(backgroundColor: Colors.amber.shade700),
            child: const Text('Collect'),
          ),
        ],
      ),
    );
  }

  void _showBatchResult(Map<String, dynamic> counts, int bet, int win, int net, bool jpWon) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Instant Spin Results'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            _batchRow('Jackpot!!!',       counts['jackpot']        ?? 0, Colors.amber),
            _batchRow('Five of a Kind',   counts['five_of_a_kind'] ?? 0, Colors.red),
            _batchRow('Four of a Kind',   counts['four_of_a_kind'] ?? 0, Colors.deepOrange),
            _batchRow('Full House',       counts['full_house']     ?? 0, Colors.orange),
            _batchRow('Three of a Kind',  counts['three_of_a_kind']?? 0, Colors.amberAccent),
            _batchRow('Two Pair',         counts['two_pair']       ?? 0, Colors.yellow),
            _batchRow('One Pair',         counts['one_pair']       ?? 0, Colors.lime),
            _batchRow('No Pair',          counts['no_pair']        ?? 0, Colors.white38),
            const Divider(height: 20),
            _statRow('Total bet',  'ꞓ${_fmtLarge(bet)}',  Colors.redAccent),
            _statRow('Total won',  'ꞓ${_fmtLarge(win)}',  Colors.greenAccent),
            _statRow('Net',
              '${net >= 0 ? '+' : ''}ꞓ${_fmtLarge(net.abs())}',
              net >= 0 ? Colors.greenAccent : Colors.redAccent),
            if (jpWon) ...[
              const SizedBox(height: 8),
              const Text('🎰 JACKPOT WON!',
                  style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
            ],
          ]),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _batchRow(String name, int count, Color col) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(children: [
      Expanded(child: Text(name, style: TextStyle(fontSize: 12, color: col))),
      Text('×$count', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
    ]),
  );

  Widget _statRow(String label, String val, Color col) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(children: [
      Expanded(child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.white54))),
      Text(val, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: col)),
    ]),
  );

  Future<void> _useDiamond() async {
    setState(() => _loading = true);
    final sid = context.read<PlayerProvider>().sid;
    final res = await ApiService.casinoUseDiamond(sid);
    if (!mounted) return;
    setState(() => _loading = false);
    if (res == null || res['err'] != 0) {
      _snack(res?['msg'] ?? 'Failed', error: true);
      return;
    }
    setState(() {
      _spinsLeft   = (res['spins_left']    as num).toInt();
      _gdPacksUsed = (res['gd_packs_used'] as num).toInt();
      _jackpot     = (res['jackpot']       as num? ?? _jackpot).toInt();
    });
    context.read<PlayerProvider>().refresh();
    _snack('+500 spins added! (${ 4 - _gdPacksUsed} GD packs remaining this cycle)');
  }

  static String _fmtLarge(int n) {
    if (n.abs() >= 1000000000) return '${(n / 1000000000).toStringAsFixed(1)}B';
    if (n.abs() >= 1000000)    return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n.abs() >= 1000)       return '${(n / 1000).toStringAsFixed(0)}K';
    return '$n';
  }

  static String _fmtTime(int secs) {
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    return '${h.toString().padLeft(2,'0')}:${m.toString().padLeft(2,'0')}:${s.toString().padLeft(2,'0')}';
  }

  @override
  Widget build(BuildContext context) {
    final player   = context.watch<PlayerProvider>().player;
    final hasDiamond = (player?.lager['42'] ?? 0.0) >= 1;
    final canUseDiamond = hasDiamond && _spinsLeft == 0 && _gdPacksUsed < 4;
    final canSpin = _casinoLevel >= 1 && _spinsLeft > 0 && !_anySpinning && !_loading;
    final betStep = 1000000;
    final maxBetSteps = (_maxBet / betStep).round();

    Color handColor = Colors.white54;
    if (_lastHand != null) {
      handColor = switch (_lastHand!) {
        'jackpot'         => Colors.amber,
        'five_of_a_kind'  => Colors.red,
        'four_of_a_kind'  => Colors.deepOrange,
        'full_house'      => Colors.orange,
        'three_of_a_kind' => Colors.amberAccent,
        'two_pair'        => Colors.yellow,
        'one_pair'        => Colors.lime,
        _                 => Colors.white38,
      };
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D1A),
        title: const Text('Casino', style: TextStyle(color: Colors.amber)),
        iconTheme: const IconThemeData(color: Colors.amber),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber)),
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16, right: 16, top: 12,
          bottom: MediaQuery.of(context).padding.bottom + 16,
        ),
        child: Column(children: [

          // ── Jackpot display ──────────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.amber.shade900.withValues(alpha: 0.6),
                         Colors.amber.shade700.withValues(alpha: 0.3)],
              ),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
            ),
            child: Column(children: [
              const Text('JACKPOT', style: TextStyle(
                  color: Colors.amber, fontSize: 11, letterSpacing: 3,
                  fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('ꞓ${_fmtLarge(_jackpot)}',
                  style: const TextStyle(color: Colors.amber, fontSize: 28,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text('Min 100B · grows 1M per spin',
                  style: TextStyle(color: Colors.amber.withValues(alpha: 0.6), fontSize: 10)),
            ]),
          ),
          const SizedBox(height: 16),

          // ── Reels ────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF111122),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(5, (i) => _Reel(
                  spinning:    _reelSpinning[i],
                  finalSymbol: _reelSymbols[i],
                  reelIndex:   i,
                )),
              ),
              // Win display
              const SizedBox(height: 10),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _lastHandDisplay != null
                    ? Text(
                        _lastWin > 0
                            ? '$_lastHandDisplay  +ꞓ${_fmtLarge(_lastWin)}'
                            : _lastHandDisplay!,
                        key: ValueKey(_lastHandDisplay),
                        style: TextStyle(color: handColor, fontSize: 14,
                            fontWeight: FontWeight.bold),
                      )
                    : const SizedBox(height: 20, key: ValueKey('empty')),
              ),
            ]),
          ),
          const SizedBox(height: 16),

          // ── Payout table ─────────────────────────────────────────────────
          ExpansionTile(
            dense: true,
            collapsedIconColor: Colors.white38,
            iconColor: Colors.amber,
            title: const Text('Payout Table', style: TextStyle(color: Colors.white54, fontSize: 12)),
            children: [
              _payRow('One Pair',        '×3',     Colors.lime),
              _payRow('Two Pair',        '×5',     Colors.yellow),
              _payRow('Three of a Kind', '×26',    Colors.amberAccent),
              _payRow('Full House',      '×100',   Colors.orange),
              _payRow('Four of a Kind',  '×300',   Colors.deepOrange),
              _payRow('Five of a Kind',  '×10,000',Colors.red),
              _payRow('Jackpot',         'Pool',   Colors.amber),
            ],
          ),
          const SizedBox(height: 12),

          // ── Spins + timer ────────────────────────────────────────────────
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('Spins left: ', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                Text('$_spinsLeft',
                    style: TextStyle(
                        color: _spinsLeft > 100 ? Colors.greenAccent
                            : _spinsLeft > 0 ? Colors.amber
                            : Colors.redAccent,
                        fontSize: 15, fontWeight: FontWeight.bold)),
                if (_gdPacksUsed > 0) ...[
                  const SizedBox(width: 8),
                  Text('(${4 - _gdPacksUsed} GD left)',
                      style: const TextStyle(color: Colors.white38, fontSize: 11)),
                ],
              ]),
              if (_timeLeftSecs != null && _timeLeftSecs! > 0)
                Text('Resets in ${_fmtTime(_timeLeftSecs!)}',
                    style: const TextStyle(color: Colors.white38, fontSize: 10)),
              if (_timeLeftSecs == null || _timeLeftSecs! <= 0)
                const Text('Timer starts on first spin',
                    style: TextStyle(color: Colors.white38, fontSize: 10)),
            ])),
            // GD button
            if (canUseDiamond)
              FilledButton.icon(
                onPressed: _loading ? null : _useDiamond,
                icon: Image.asset('assets/images_res/res42.png',
                    width: 18, height: 18,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.diamond, size: 16, color: Colors.cyan)),
                label: const Text('+500', style: TextStyle(fontSize: 12)),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.cyan.shade800,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
          ]),
          const SizedBox(height: 12),

          // ── Bet selector ─────────────────────────────────────────────────
          Row(children: [
            const Text('Bet: ', style: TextStyle(color: Colors.white54, fontSize: 13)),
            Expanded(
              child: Slider(
                value: (_bet / betStep).clamp(1, maxBetSteps.toDouble()),
                min: 1,
                max: maxBetSteps.clamp(1, 10).toDouble(),
                divisions: (maxBetSteps - 1).clamp(1, 9),
                activeColor: Colors.amber,
                inactiveColor: Colors.amber.withValues(alpha: 0.2),
                onChanged: _anySpinning ? null : (v) {
                  setState(() => _bet = (v.round() * betStep).clamp(betStep, _maxBet));
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
              ),
              child: Text('ꞓ${_fmtLarge(_bet)}',
                  style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold,
                      fontSize: 13)),
            ),
          ]),
          const SizedBox(height: 8),

          // ── Spin buttons ─────────────────────────────────────────────────
          Row(children: [
            // Spin button
            Expanded(
              flex: 3,
              child: FilledButton.icon(
                onPressed: canSpin ? () => _spin() : null,
                icon: _anySpinning
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.play_circle, size: 20),
                label: const Text('SPIN'),
                style: FilledButton.styleFrom(
                  backgroundColor: canSpin ? Colors.amber.shade700 : Colors.grey.shade800,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Auto-spin toggle
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: canSpin || _autoSpin
                    ? () {
                        setState(() => _autoSpin = !_autoSpin);
                        if (_autoSpin && !_anySpinning) _spin();
                      }
                    : null,
                icon: Icon(_autoSpin ? Icons.pause : Icons.autorenew, size: 18),
                label: Text(_autoSpin ? 'Stop' : 'Auto'),
                style: FilledButton.styleFrom(
                  backgroundColor: _autoSpin
                      ? Colors.red.shade700
                      : (canSpin ? Colors.blueGrey.shade700 : Colors.grey.shade800),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Instant spin all
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: (canSpin && _spinsLeft > 1 && !_autoSpin)
                    ? () => _spin(count: _spinsLeft)
                    : null,
                icon: const Icon(Icons.fast_forward, size: 18),
                label: Text('×$_spinsLeft'),
                style: FilledButton.styleFrom(
                  backgroundColor: (canSpin && _spinsLeft > 1)
                      ? Colors.deepPurple.shade700
                      : Colors.grey.shade800,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ]),

          if (_casinoLevel < 1) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
              ),
              child: const Text(
                'Build the Casino special building to start playing!',
                style: TextStyle(color: Colors.redAccent, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _payRow(String name, String multiplier, Color col) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
    child: Row(children: [
      Expanded(child: Text(name, style: TextStyle(fontSize: 12, color: col))),
      Text(multiplier, style: const TextStyle(
          fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70)),
    ]),
  );
}

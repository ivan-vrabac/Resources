import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/game_api.dart';
import '../services/notification_service.dart';
import '../services/storage_service.dart';

class PlayerProvider extends ChangeNotifier {
  Player? _player;
  String? _sid;
  LatLng? _chatNavigateTo;
  int _chatUnreadMentions = 0;

  Player? get player => _player;
  String get sid => _sid ?? '';
  LatLng? get chatNavigateTo => _chatNavigateTo;
  int get chatUnreadMentions => _chatUnreadMentions;

  void setChatNavigateTo(LatLng? pos) {
    _chatNavigateTo = pos;
    notifyListeners();
  }

  void addChatMention() {
    _chatUnreadMentions++;
    notifyListeners();
  }

  // ── Unread chat messages (server-counted, excludes blocked players) ──
  // Social badge (owner 2026-10-23): new private messages + chat messages that mention you
  int _chatUnread = 0;     // mentions of you in global chat since you last saw it
  int _dmUnread = 0;       // unread private messages
  int _chatSeenId = -1; // -1 = not loaded yet
  int get chatUnread => _chatUnread + _dmUnread;
  int get dmUnread => _dmUnread;

  Future<void> _loadChatSeen() async {
    if (_chatSeenId >= 0) return;
    final p = await SharedPreferences.getInstance();
    _chatSeenId = p.getInt('chat_seen_id') ?? 0;
  }

  Future<void> pollChatUnread() async {
    if (sid.isEmpty) return;
    await _loadChatSeen();
    final r = await GameApi.call('/api/v1/chat/unread', sid, {'seen': _chatSeenId});
    if (r.ok) {
      final n = (r.data['mentions'] as num? ?? 0).toInt();
      final dm = (r.data['dm'] as num? ?? 0).toInt();
      if (n != _chatUnread || dm != _dmUnread) {
        _chatUnread = n;
        _dmUnread = dm;
        notifyListeners();
      }
    }
  }

  /// Called by the chat screen with the newest message id it has shown.
  Future<void> markChatSeen(int id) async {
    await _loadChatSeen();
    if (id <= _chatSeenId && _chatUnread == 0) return;
    if (id > _chatSeenId) {
      _chatSeenId = id;
      final p = await SharedPreferences.getInstance();
      await p.setInt('chat_seen_id', id);
    }
    if (_chatUnread != 0) {
      _chatUnread = 0;
      notifyListeners();
    }
  }

  void clearChatMentions() {
    if (_chatUnreadMentions == 0) return;
    _chatUnreadMentions = 0;
    notifyListeners();
  }

  int? _creditsNow;   // balance right after a known spend, until the next full refresh arrives

  /// Credits to show (updated instantly after spending, then replaced by the server's value).
  int get credits => _creditsNow ?? _player?.credits ?? 0;

  /// Show a spend (or a gain, negative) immediately; the next refresh brings the exact balance.
  void adjustCredits(int spent) {
    if (_player == null) return;
    _creditsNow = credits - spent;
    notifyListeners();
  }

  void setPlayer(Player p, {String? sid}) {
    _player = p;
    _creditsNow = null;
    if (sid != null) _sid = sid;
    notifyListeners();
  }

  Future<void> refresh() async {
    final sid = _sid ?? await StorageService.getSid();
    if (sid == null) return;
    final p = await ApiService.getPlayerData(sid);
    if (p != null) {
      setPlayer(p, sid: sid);
      NotificationService.scheduleMineNotifications(p);
      // Player data no longer carries every mine; keep the Mines tab list current.
      if (_mines != null) await loadMines();
    }
  }

  // ── Full mine list (Mines tab) — loaded on demand, not with every player refresh ──

  List<Mine>? _mines;
  bool _minesLoading = false;

  /// The player's mines, or null until [loadMines] has completed once.
  /// Servers without lite support still send them in player data.
  List<Mine>? get mines =>
      _mines ?? ((_player?.mines.isNotEmpty ?? false) ? _player!.mines : null);
  bool get minesLoading => _minesLoading;

  Future<void> loadMines() async {
    if (_minesLoading || sid.isEmpty) return;
    _minesLoading = true;
    notifyListeners();
    final list = await ApiService.getMineList(sid);
    _minesLoading = false;
    if (list != null) _mines = list;
    notifyListeners();
  }

  void clear() {
    _player = null;
    _sid = null;
    _mines = null;
    notifyListeners();
  }
}

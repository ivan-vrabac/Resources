import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'player.dart';
import '../services/api_service.dart';
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

  void clearChatMentions() {
    if (_chatUnreadMentions == 0) return;
    _chatUnreadMentions = 0;
    notifyListeners();
  }

  void setPlayer(Player p, {String? sid}) {
    _player = p;
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

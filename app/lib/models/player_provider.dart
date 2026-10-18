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

  void setPlayer(Player p) {
    _player = p;
    _sid = ApiService.makeSid(p.hid);
    notifyListeners();
  }

  Future<void> refresh() async {
    final hid = await StorageService.getHid();
    if (hid == null) return;
    final p = await ApiService.getPlayerData(hid);
    if (p != null) {
      setPlayer(p);
      NotificationService.scheduleMineNotifications(p);
    }
  }

  void clear() {
    _player = null;
    _sid = null;
    notifyListeners();
  }
}

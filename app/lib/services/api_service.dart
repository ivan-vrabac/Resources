import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../models/player.dart';

class ApiService {
  static Future<String?> login(String companyName) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/playerLogin.php'),
          body: {'userEmail': companyName}).timeout(const Duration(seconds: 10));
      final list = jsonDecode(r.body) as List;
      if (list.isEmpty) return null;
      return (list[0] as Map<String, dynamic>)['hID'] as String?;
    } catch (_) { return null; }
  }

  static Future<String?> register(String companyName) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/playerNew.php'),
          body: {'userEmail': companyName}).timeout(const Duration(seconds: 10));
      final hid = r.body.trim();
      return hid.isEmpty ? null : hid;
    } catch (_) { return null; }
  }

  static Future<Player?> getPlayerData(String hid) async {
    try {
      final sid = makeSid(hid);
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/playerGetData.php'),
          body: {'sid': sid}).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final decoded = ZLibDecoder().convert(r.bodyBytes);
      final list = jsonDecode(utf8.decode(decoded)) as List;
      if (list.isEmpty) return null;
      return Player.fromJson(list[0] as Map<String, dynamic>);
    } catch (_) { return null; }
  }

  // ── Scanner ──────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> scan(
      String sid, double lat, double lng,
      {bool drone = false, double? playerLat, double? playerLng}) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/scannerPayscan.php'), body: {
        'sid': sid, 'lat': lat.toString(), 'lng': lng.toString(),
        if (drone) 'drone': '1',
        if (playerLat != null) 'player_lat': playerLat.toString(),
        if (playerLng != null) 'player_lng': playerLng.toString(),
      }).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  // ── Mines ────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> buildMine(
      String sid, double lat, double lng, int itemId, int quality,
      {String prospectToken = '',
       double? curLat, double? curLng}) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/mineNew.php'), body: {
        'sid': sid, 'lat': lat.toString(), 'lng': lng.toString(),
        'itemID': itemId.toString(), 'quality': quality.toString(),
        if (prospectToken.isNotEmpty) 'prospect_token': prospectToken,
        if (curLat != null) 'cur_lat': curLat.toString(),
        if (curLng != null) 'cur_lng': curLng.toString(),
      }).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<List<dynamic>?> getMapMarkers(
      String sid, double lat1, double lng1, double lat2, double lng2) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/mineLoadMarkers.php'), body: {
        'sid': sid,
        'lat1': lat1.toString(), 'lng1': lng1.toString(),
        'lat2': lat2.toString(), 'lng2': lng2.toString(),
      }).timeout(const Duration(seconds: 10));
      final decoded = ZLibDecoder().convert(r.bodyBytes);
      return jsonDecode(utf8.decode(decoded)) as List;
    } catch (_) { return null; }
  }

  static Future<List<dynamic>?> getHQMarkers(
      String sid, double lat1, double lng1, double lat2, double lng2,
      {int minLevel = 1}) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/HQGetMarkers.php'), body: {
        'sid': sid,
        'lat1': lat1.toString(), 'lng1': lng1.toString(),
        'lat2': lat2.toString(), 'lng2': lng2.toString(),
        'min_level': minLevel.toString(),
      }).timeout(const Duration(seconds: 10));
      final decoded = ZLibDecoder().convert(r.bodyBytes);
      return jsonDecode(utf8.decode(decoded)) as List;
    } catch (_) { return null; }
  }

  static Future<List<dynamic>?> getMineDensity(
      String sid, double lat1, double lng1, double lat2, double lng2, double zoom) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/mineDensity.php'), body: {
        'sid': sid,
        'lat1': lat1.toString(), 'lng1': lng1.toString(),
        'lat2': lat2.toString(), 'lng2': lng2.toString(),
        'z': zoom.toString(),
      }).timeout(const Duration(seconds: 10));
      final decoded = ZLibDecoder().convert(r.bodyBytes);
      return jsonDecode(utf8.decode(decoded)) as List;
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> repairMinePay(
      String sid, String mineId) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/mineMaintAPay.php'),
          body: {'sid': sid, 'mID': mineId}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> repairMineKit(
      String sid, String mineId) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/mineMaintAKit.php'),
          body: {'sid': sid, 'mID': mineId}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> demolishMine(
      String sid, String mineId) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/mineDelete.php'),
          body: {'sid': sid, 'mID': mineId}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> bulkDemolishMines(
      String sid, List<String> mineIds) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/mineBulkDelete.php'),
          body: {'sid': sid, 'mIDs': mineIds.join(',')}).timeout(const Duration(seconds: 15));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> techUpgradeMine(
      String sid, String mineId, int tuLevel, int amount) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/mineTechupgrade.php'),
          body: {'sid': sid, 'mID': mineId, 'tuLevel': tuLevel.toString(), 'amount': amount.toString()})
          .timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> upgradeMine(
      String sid, String mineId) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/mineUpgrade.php'),
          body: {'sid': sid, 'mID': mineId}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  // ── HQ ───────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> placeHQ(
      String sid, double lat, double lng) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/HQNewPosition.php'),
          body: {'sid': sid, 'lat': lat.toString(), 'lng': lng.toString()})
          .timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> upgradeHQ(String sid) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/hqUpgrade.php'),
          body: {'sid': sid}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> depositHQ(String sid, Map<int, double> amounts) async {
    try {
      final body = <String, String>{'sid': sid};
      amounts.forEach((id, qty) => body['amt_$id'] = qty.toStringAsFixed(0));
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/hqDeposit.php'),
          body: body).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  // ── Warehouse ────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> getWarehouse(String sid) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/lagerGetData.php'),
          body: {'sid': sid}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> upgradeWarehouse(String sid) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/lagerUpgrade.php'),
          body: {'sid': sid}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  // ── Factories ────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> getFactories(String sid) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/factoryGetData.php'),
          body: {'sid': sid}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> buyFactory(
      String sid, int itemId) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/factoryBuy.php'),
          body: {'sid': sid, 'itemID': itemId.toString()})
          .timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> startProduction(
      String sid, String fid, int batches) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/factoryNewOrder.php'),
          body: {'sid': sid, 'fID': fid, 'batches': batches.toString()})
          .timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> collectFactory(
      String sid, String fid) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/factoryCollect.php'),
          body: {'sid': sid, 'fID': fid}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> stopProduction(
      String sid, String fid) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/factoryStop.php'),
          body: {'sid': sid, 'fID': fid}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> upgradeFactory(
      String sid, String fid) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/factoryUpgrade.php'),
          body: {'sid': sid, 'fID': fid}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> useBooster(
      String sid, String fid, int itemId) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/factoryUseBooster.php'),
          body: {'sid': sid, 'fID': fid, 'itemID': itemId.toString()})
          .timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> boostFactory(
      String sid, String fid) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/factoryBoost.php'),
          body: {'sid': sid, 'fID': fid}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> upgradeWarehouseMulti(
      String sid, int levels) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/lagerUpgradeMulti.php'),
          body: {'sid': sid, 'levels': levels.toString()}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  // ── Market ───────────────────────────────────────────────────────────────

  static Future<List<dynamic>?> getMarket(String sid, {int itemId = 0}) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/marketGetData.php'),
          body: {'sid': sid, 'itemID': itemId.toString()})
          .timeout(const Duration(seconds: 10));
      final decoded = ZLibDecoder().convert(r.bodyBytes);
      return jsonDecode(utf8.decode(decoded)) as List;
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> sellItem(
      String sid, int itemId, double qty, double priceUnit) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/marketNewReq.php'), body: {
        'sid': sid, 'itemID': itemId.toString(),
        'qty': qty.toString(), 'priceUnit': priceUnit.toString(),
      }).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> buyFromMarket(
      String sid, String reqId, double qty) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/marketDealReq.php'),
          body: {'sid': sid, 'reqID': reqId, 'qty': qty.toString()})
          .timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> cancelMarketListing(
      String sid, String reqId) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/marketCancelReq.php'),
          body: {'sid': sid, 'reqID': reqId}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  // ── Shop ─────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> buyShopItem(
      String sid, int itemId, int qty) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/shopBuyItem.php'),
          body: {'sid': sid, 'itemID': itemId.toString(), 'qty': qty.toString()})
          .timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  // ── Log ──────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> getLog(String sid, {int offset = 0, String type = ''}) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/protokollGetData.php'),
          body: {'sid': sid, 'offset': offset.toString(), 'type': type})
          .timeout(const Duration(seconds: 10));
      final decoded = ZLibDecoder().convert(r.bodyBytes);
      return jsonDecode(utf8.decode(decoded)) as Map<String, dynamic>;
    } catch (_) { return null; }
  }

  static Future<void> ping(String sid) async {
    try {
      await http.post(Uri.parse('$kBaseUrl/flut23/ping.php'), body: {'sid': sid})
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  // ── Geolocation ──────────────────────────────────────────────────────────

  static Future<String?> getCountryCode() async {
    try {
      final r = await http.get(Uri.parse('http://ip-api.com/json?fields=status,countryCode'))
          .timeout(const Duration(seconds: 5));
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      if (data['status'] == 'success') {
        return (data['countryCode'] as String).toLowerCase();
      }
    } catch (_) {}
    return null;
  }

  static Future<void> setCountryCode(String sid, String code) async {
    try {
      await http.post(Uri.parse('$kBaseUrl/flut23/setCountryCode.php'),
          body: {'sid': sid, 'code': code}).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> getLeaderboard(String sid) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/leaderboard.php'),
          body: {'sid': sid}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> buySpecialBuilding(String sid, int itemId) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/specialBuildingBuy.php'),
          body: {'sid': sid, 'itemID': itemId.toString()}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> upgradeSpecialBuilding(String sid, String fid) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/specialBuildingUpgrade.php'),
          body: {'sid': sid, 'fID': fid}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<void> registerFcmToken(String sid, String token) async {
    try {
      await http.post(Uri.parse('$kBaseUrl/flut23/fcmRegister.php'),
          body: {'sid': sid, 'token': token, 'platform': 'android'})
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  // ── Chat ─────────────────────────────────────────────────────────────────

  static Future<List<dynamic>?> chatGetMessages(String sid, int since) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/chatGetData2.php'), body: {
        'sid': sid, 'since': since.toString(),
      }).timeout(const Duration(seconds: 10));
      final decoded = ZLibDecoder().convert(r.bodyBytes);
      return jsonDecode(utf8.decode(decoded)) as List;
    } catch (_) { return null; }
  }

  // ── Casino ───────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> casinoGetData(String sid) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/casinoGetData.php'),
          body: {'sid': sid}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> casinoSpin(
      String sid, int bet, {int count = 1}) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/casinoNewRoll.php'), body: {
        'sid': sid, 'bet': bet.toString(), 'count': count.toString(),
      }).timeout(const Duration(seconds: 15));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> casinoUseDiamond(String sid) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/casinoUseDiamond.php'),
          body: {'sid': sid}).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  static Future<Map<String, dynamic>?> chatSendMessage(String sid, String msg) async {
    try {
      final r = await http.post(Uri.parse('$kBaseUrl/flut23/chatNewMsg2.php'), body: {
        'sid': sid, 'msg': msg,
      }).timeout(const Duration(seconds: 10));
      return _zlibJson(r.bodyBytes);
    } catch (_) { return null; }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  static String makeSid(String hid) =>
      base64Url.encode(utf8.encode(jsonEncode({'hID': hid}))).replaceAll('=', '');

  static Map<String, dynamic>? _zlibJson(List<int> bytes) {
    try {
      final decoded = ZLibDecoder().convert(bytes);
      return jsonDecode(utf8.decode(decoded)) as Map<String, dynamic>;
    } catch (_) { return null; }
  }
}

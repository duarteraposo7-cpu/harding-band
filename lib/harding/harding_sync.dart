// HARDING Band → HARDING: sends the day's numbers to the person's HARDING
// account. Not part of upstream OpenStrap Edge.
//
// Pairing: this phone asks HARDING for a short code and shows it; the person
// types it in HARDING (Account → Band) while signed in; the phone then
// collects its own key. Nothing anyone sends can point this phone at another
// account, and no key ever travels in a link. HARDING answers 410 once the
// phone was unlinked there, which clears the key here.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// HARDING's server. Override at build time with
/// `--dart-define=HARDING_SERVER=https://…`.
const String kHardingServer = String.fromEnvironment('HARDING_SERVER',
    defaultValue: 'https://personal-os-two-gilt.vercel.app');

/// The same numbers as the «Get Today's Numbers» Shortcut action
/// (`OpenStrapShared.numbersJSON` in ios/OpenStrapIntents.swift): ints are
/// -1 and strings '' for "no data", sent as null.
class HardingNumbers {
  final bool hasData;
  final int readiness, hrv, hrvBaseline, restingHr, sleepMin, sleepNeedMin,
      sleepEfficiency;
  final String readinessBand;
  final double strain;
  final DateTime at;

  const HardingNumbers({
    required this.hasData,
    required this.readiness,
    required this.readinessBand,
    required this.hrv,
    required this.hrvBaseline,
    required this.restingHr,
    required this.sleepMin,
    required this.sleepNeedMin,
    required this.sleepEfficiency,
    required this.strain,
    required this.at,
  });

  Map<String, Object?> toJson() {
    int? i(int v) => hasData && v >= 0 ? v : null;
    return {
      'source': 'HARDING Band',
      'has_data': hasData,
      'readiness': i(readiness),
      'readiness_band': hasData && readinessBand.isNotEmpty ? readinessBand : null,
      'hrv_ms': i(hrv),
      'hrv_baseline_ms': i(hrvBaseline),
      'resting_hr': i(restingHr),
      'sleep_min': i(sleepMin),
      'sleep_need_min': i(sleepNeedMin),
      'sleep_efficiency': i(sleepEfficiency),
      'strain': hasData && strain >= 0 ? double.parse(strain.toStringAsFixed(1)) : null,
      'updated_at': isoWithOffset(at),
      'date': localDay(at),
    };
  }
}

String localDay(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)}';
}

/// ISO 8601 with the phone's own offset, as the Shortcut sends it.
String isoWithOffset(DateTime t) {
  final l = t.toLocal();
  final off = l.timeZoneOffset;
  String two(int n) => n.abs().toString().padLeft(2, '0');
  final sign = off.isNegative ? '-' : '+';
  final base = l.toIso8601String().split('.').first;
  return '$base$sign${two(off.inHours)}:${two(off.inMinutes.remainder(60))}';
}

/// A code to show the person, and the token this phone polls with.
class HardingPairing {
  final String code;
  final String pollToken;
  final DateTime expiresAt;
  const HardingPairing(this.code, this.pollToken, this.expiresAt);
}

sealed class PairingState {
  const PairingState();
}

class PairingPending extends PairingState {
  const PairingPending();
}

class PairingExpired extends PairingState {
  const PairingExpired();
}

class PairingLinked extends PairingState {
  const PairingLinked();
}

/// A network or server problem: try again on the next poll.
class PairingRetry extends PairingState {
  const PairingRetry();
}

enum HardingSendResult { notLinked, sent, unlinked, failed }

class HardingSync {
  // first_unlock: the Sync Data Shortcut runs while the phone is locked.
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  static const _kServer = 'harding.server';
  static const _kKey = 'harding.key';

  /// Whether this phone is paired with a HARDING account.
  static final ValueNotifier<bool> linked = ValueNotifier<bool>(false);
  static HardingNumbers? _last;
  static Uri get _server => Uri.parse(kHardingServer);

  static Future<void> init() async {
    try {
      linked.value = (await _storage.read(key: _kKey)) != null;
    } catch (e) {
      debugPrint('[harding] init: $e');
    }
  }

  /// Asks HARDING for a code to show. Throws with a message the person can read.
  static Future<HardingPairing> startPairing({http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final res = await c
          .post(_server.replace(path: '/api/band/pair'))
          .timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body);
      if (res.statusCode != 200 || body is! Map || body['ok'] != true) {
        throw HardingError(body is Map && body['message'] is String
            ? body['message'] as String
            : 'Could not reach HARDING. Try again.');
      }
      return HardingPairing(body['code'] as String, body['pollToken'] as String,
          DateTime.parse(body['expiresAt'] as String));
    } on HardingError {
      rethrow;
    } catch (e) {
      debugPrint('[harding] pair: $e');
      throw const HardingError('Could not reach HARDING. Try again.');
    } finally {
      if (client == null) c.close();
    }
  }

  /// Asks whether the code was typed in HARDING. On «linked» the key is stored
  /// and the latest numbers are sent right away.
  static Future<PairingState> poll(HardingPairing p, {http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final res = await c
          .post(_server.replace(path: '/api/band/pair/claim'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'pollToken': p.pollToken}))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 410) return const PairingExpired();
      if (res.statusCode != 200) return const PairingRetry();
      final body = jsonDecode(res.body);
      if (body is! Map || body['ok'] != true) return const PairingRetry();
      if (body['status'] == 'pending') return const PairingPending();
      final key = body['key'];
      if (body['status'] != 'linked' || key is! String || !key.startsWith('hb_')) {
        return const PairingRetry();
      }
      await _storage.write(key: _kServer, value: _server.toString());
      await _storage.write(key: _kKey, value: key);
      linked.value = true;
      final last = _last;
      if (last != null) unawaited(send(last, client: client));
      return const PairingLinked();
    } catch (e) {
      debugPrint('[harding] poll: $e');
      return const PairingRetry();
    } finally {
      if (client == null) c.close();
    }
  }

  static Future<void> unlink() async {
    await _storage.delete(key: _kServer);
    await _storage.delete(key: _kKey);
    linked.value = false;
  }

  /// Best-effort: never throws. Called after each widget snapshot changes.
  static Future<HardingSendResult> send(HardingNumbers n, {http.Client? client}) async {
    _last = n;
    try {
      final s = await _storage.read(key: _kServer);
      final key = await _storage.read(key: _kKey);
      final server = s == null ? null : Uri.tryParse(s);
      if (server == null || key == null) return HardingSendResult.notLinked;
      if (!n.hasData) return HardingSendResult.sent;
      final c = client ?? http.Client();
      try {
        final res = await c
            .post(
              server.replace(path: '/api/band/sync'),
              headers: {'Authorization': 'Bearer $key', 'Content-Type': 'application/json'},
              body: jsonEncode(n.toJson()),
            )
            .timeout(const Duration(seconds: 15));
        // Only 410 means «unlinked in HARDING». A 401 can come from a server
        // build that does not know this route yet; keep the key and retry later.
        if (res.statusCode == 410) {
          await unlink();
          return HardingSendResult.unlinked;
        }
        return res.statusCode == 200 ? HardingSendResult.sent : HardingSendResult.failed;
      } finally {
        if (client == null) c.close();
      }
    } catch (e) {
      debugPrint('[harding] send: $e');
      return HardingSendResult.failed;
    }
  }
}

class HardingError implements Exception {
  final String message;
  const HardingError(this.message);
  @override
  String toString() => message;
}

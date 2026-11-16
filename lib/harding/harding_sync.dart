// HARDING Band → HARDING: sends the day's numbers to the person's HARDING
// account. Not part of upstream OpenStrap Edge.
//
// Linking: HARDING (Account → Band) opens `hardingband://link?server=…&key=…`.
// The key is per person and per phone; only its owner's band rows can be
// written with it. Unlinking in HARDING makes the server answer 401, which
// clears the link here.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class HardingLink {
  final Uri server;
  final String key;
  const HardingLink(this.server, this.key);
}

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

/// Parses the link HARDING hands over. Only https, or http on localhost for
/// development, and only keys in HARDING's format.
HardingLink? parseHardingLink(Uri uri) {
  if (uri.scheme != 'hardingband' || uri.host != 'link') return null;
  final server = Uri.tryParse(uri.queryParameters['server'] ?? '');
  final key = uri.queryParameters['key'] ?? '';
  if (server == null || !server.hasAuthority) return null;
  final local = server.host == 'localhost' || server.host == '127.0.0.1';
  if (server.scheme != 'https' && !(server.scheme == 'http' && local)) return null;
  if (!RegExp(r'^hb_[A-Za-z0-9_-]{20,77}$').hasMatch(key)) return null;
  return HardingLink(Uri(scheme: server.scheme, host: server.host, port: server.hasPort ? server.port : null), key);
}

enum HardingSendResult { notLinked, sent, unlinked, failed }

class HardingSync {
  // first_unlock: the Sync Data Shortcut runs while the phone is locked.
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  static const _kServer = 'harding.server';
  static const _kKey = 'harding.key';

  /// Visible state for the settings row.
  static final ValueNotifier<Uri?> linkedServer = ValueNotifier<Uri?>(null);
  static HardingNumbers? _last;

  static Future<void> init() async {
    try {
      final s = await _storage.read(key: _kServer);
      linkedServer.value = s == null ? null : Uri.tryParse(s);
    } catch (e) {
      debugPrint('[harding] init: $e');
    }
  }

  static Future<HardingLink?> _read() async {
    final s = await _storage.read(key: _kServer);
    final k = await _storage.read(key: _kKey);
    final server = s == null ? null : Uri.tryParse(s);
    if (server == null || k == null) return null;
    return HardingLink(server, k);
  }

  /// Stores a link from HARDING and sends the latest numbers right away.
  static Future<bool> link(Uri uri) async {
    final parsed = parseHardingLink(uri);
    if (parsed == null) return false;
    await _storage.write(key: _kServer, value: parsed.server.toString());
    await _storage.write(key: _kKey, value: parsed.key);
    linkedServer.value = parsed.server;
    final last = _last;
    if (last != null) unawaited(send(last));
    return true;
  }

  static Future<void> unlink() async {
    await _storage.delete(key: _kServer);
    await _storage.delete(key: _kKey);
    linkedServer.value = null;
  }

  /// Best-effort: never throws. Called after each widget snapshot changes.
  static Future<HardingSendResult> send(HardingNumbers n, {http.Client? client}) async {
    _last = n;
    try {
      final link = await _read();
      if (link == null) return HardingSendResult.notLinked;
      if (!n.hasData) return HardingSendResult.sent;
      final c = client ?? http.Client();
      try {
        final res = await c
            .post(
              link.server.replace(path: '/api/band/sync'),
              headers: {
                'Authorization': 'Bearer ${link.key}',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(n.toJson()),
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode == 401) {
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

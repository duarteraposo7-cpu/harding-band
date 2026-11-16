import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harding_band/harding/harding_pairing_dialog.dart';
import 'package:harding_band/harding/harding_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const key = 'hb_abcdefghijklmnopqrstuvwxyz0123456789-_ABCDEFG';
final numbers = HardingNumbers(hasData: true, readiness: 64, readinessBand: 'Good to go', hrv: 58, hrvBaseline: 52,
    restingHr: 51, sleepMin: 425, sleepNeedMin: 480, sleepEfficiency: 91, strain: 3.25, at: DateTime(2026, 10, 17, 7, 31, 12));
final pairing = HardingPairing('ABCD-EFGH', 'hbp_token', DateTime.now().add(const Duration(minutes: 10)));

/// A HARDING server: `claim` answers the pairing poll, `sync` the number upload.
MockClient server(List<http.Request> calls, {int claimStatus = 200, String claim = 'linked', int syncStatus = 200}) =>
    MockClient((r) async {
      calls.add(r);
      switch (r.url.path) {
        case '/api/band/pair':
          return http.Response(jsonEncode({'ok': true, 'code': 'ABCD-EFGH', 'pollToken': 'hbp_token', 'expiresAt': '2099-01-01T00:00:00.000Z', 'minutes': 10}), 200);
        case '/api/band/pair/claim':
          if (claimStatus != 200) return http.Response(jsonEncode({'ok': false, 'status': 'expired'}), claimStatus);
          return http.Response(jsonEncode(claim == 'linked' ? {'ok': true, 'status': 'linked', 'key': key} : {'ok': true, 'status': claim}), 200);
        case '/api/band/sync':
          return http.Response(jsonEncode({'ok': syncStatus == 200}), syncStatus);
      }
      return http.Response('', 404);
    });

void main() {
  group('HardingNumbers.toJson', () {
    test('matches the shape HARDING parses', () {
      final j = numbers.toJson();
      expect(j['readiness'], 64);
      expect(j['strain'], 3.3);
      expect(j['date'], '2026-10-17');
      expect(RegExp(r'^2026-10-17T07:31:12[+-]\d{2}:\d{2}$').hasMatch(j['updated_at'] as String), isTrue);
    });
    test('sends null for the no-data sentinels and when there is no fresh data', () {
      final none = HardingNumbers(hasData: true, readiness: -1, readinessBand: '', hrv: 58, hrvBaseline: 52, restingHr: 51,
          sleepMin: 425, sleepNeedMin: 480, sleepEfficiency: 91, strain: -1, at: DateTime(2026, 10, 17)).toJson();
      expect([none['readiness'], none['strain'], none['readiness_band']], [null, null, null]);
      final stale = HardingNumbers(hasData: false, readiness: 64, readinessBand: 'x', hrv: 58, hrvBaseline: 52, restingHr: 51,
          sleepMin: 425, sleepNeedMin: 480, sleepEfficiency: 91, strain: 3, at: DateTime(2026, 10, 17)).toJson();
      expect(stale['hrv_ms'], isNull);
    });
  });

  group('pairing and sending', () {
    late List<http.Request> calls;
    setUp(() async {
      calls = [];
      FlutterSecureStorage.setMockInitialValues({});
      await HardingSync.unlink();
    });

    test('nothing is sent before the phone is paired', () async {
      expect(await HardingSync.send(numbers, client: server(calls)), HardingSendResult.notLinked);
      expect(calls, isEmpty);
    });

    test('asks HARDING for a code, then waits until the person types it', () async {
      final p = await HardingSync.startPairing(client: server(calls));
      expect(p.code, 'ABCD-EFGH');
      expect(await HardingSync.poll(p, client: server(calls, claim: 'pending')), isA<PairingPending>());
      expect(HardingSync.linked.value, isFalse);
    });

    test('once linked, stores the key and sends the latest numbers with it', () async {
      await HardingSync.send(numbers, client: server(calls));
      expect(await HardingSync.poll(pairing, client: server(calls)), isA<PairingLinked>());
      expect(HardingSync.linked.value, isTrue);
      await Future<void>.delayed(Duration.zero);
      final sync = calls.where((r) => r.url.path == '/api/band/sync').single;
      expect(sync.headers['Authorization'], 'Bearer $key');
      expect(sync.url.origin, kHardingServer);
    });

    test('an expired code is 410 and stores nothing', () async {
      expect(await HardingSync.poll(pairing, client: server(calls, claimStatus: 410)), isA<PairingExpired>());
      expect(HardingSync.linked.value, isFalse);
    });

    test('a key that does not look like a HARDING key is refused', () async {
      final odd = MockClient((r) async => http.Response(jsonEncode({'ok': true, 'status': 'linked', 'key': 'nope'}), 200));
      expect(await HardingSync.poll(pairing, client: odd), isA<PairingRetry>());
      expect(HardingSync.linked.value, isFalse);
    });

    test('only 410 unlinks: a 401 from an older server build keeps the key', () async {
      await HardingSync.poll(pairing, client: server(calls));
      expect(await HardingSync.send(numbers, client: server(calls, syncStatus: 401)), HardingSendResult.failed);
      expect(HardingSync.linked.value, isTrue);
      expect(await HardingSync.send(numbers, client: server(calls, syncStatus: 410)), HardingSendResult.unlinked);
      expect(HardingSync.linked.value, isFalse);
    });

    test('a server it cannot reach gives a message the person can read', () async {
      final down = MockClient((r) async => throw Exception('offline'));
      expect(() => HardingSync.startPairing(client: down), throwsA(isA<HardingError>()));
    });
  });

  testWidgets('the dialog shows a new code when the server has one', (t) async {
    FlutterSecureStorage.setMockInitialValues({});
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: HardingPairingDialog())));
    await t.pump();
    expect(find.text('Link to HARDING'), findsOneWidget);
  });
}

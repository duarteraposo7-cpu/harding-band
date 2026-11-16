import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:harding_band/harding/harding_sync.dart';

void main() {
  group('parseHardingLink', () {
    const key = 'hb_abcdefghijklmnopqrstuvwxyz0123456789-_ABCDEFG';
    Uri link(String server, [String k = key]) =>
        Uri(scheme: 'hardingband', host: 'link', queryParameters: {'server': server, 'key': k});

    test('accepts an https server and a HARDING key', () {
      final l = parseHardingLink(link('https://harding.pt'))!;
      expect(l.server.toString(), 'https://harding.pt');
      expect(l.key, key);
    });
    test('drops any path or query from the server', () {
      expect(parseHardingLink(link('https://harding.pt/conta?x=1'))!.server.toString(), 'https://harding.pt');
    });
    test('allows plain http only on localhost', () {
      expect(parseHardingLink(link('http://localhost:3000'))!.server.port, 3000);
      expect(parseHardingLink(link('http://harding.pt')), isNull);
    });
    test('refuses any server that is not HARDING', () {
      expect(parseHardingLink(link('https://evil.example')), isNull);
      expect(parseHardingLink(link('https://harding.pt.evil.example')), isNull);
      expect(parseHardingLink(link('http://localhost:3000'), allowLocal: false), isNull);
    });
    test('refuses other schemes, hosts and key shapes', () {
      expect(parseHardingLink(Uri.parse('https://link?server=https://harding.pt&key=$key')), isNull);
      expect(parseHardingLink(Uri.parse('hardingband://other?server=https://harding.pt&key=$key')), isNull);
      expect(parseHardingLink(link('https://harding.pt', 'not-a-key')), isNull);
      expect(parseHardingLink(link('https://harding.pt', 'hb_short')), isNull);
      expect(parseHardingLink(link('ftp://harding.pt')), isNull);
    });
  });

  group('HardingNumbers.toJson', () {
    final at = DateTime(2026, 10, 17, 7, 31, 12);
    HardingNumbers n({bool hasData = true, int readiness = 64, double strain = 3.25, String band = 'Good to go'}) => HardingNumbers(
          hasData: hasData,
          readiness: readiness,
          readinessBand: band,
          hrv: 58,
          hrvBaseline: 52,
          restingHr: 51,
          sleepMin: 425,
          sleepNeedMin: 480,
          sleepEfficiency: 91,
          strain: strain,
          at: at,
        );

    test('matches the shape HARDING parses', () {
      final j = n().toJson();
      expect(j['has_data'], true);
      expect(j['readiness'], 64);
      expect(j['readiness_band'], 'Good to go');
      expect(j['strain'], 3.3);
      expect(j['date'], '2026-10-17');
      expect(j['updated_at'], startsWith('2026-10-17T07:31:12'));
      expect(RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(j['updated_at'] as String), isTrue);
      expect(jsonDecode(jsonEncode(j)), isA<Map>());
    });
    test('sends null for the no-data sentinels', () {
      final j = n(readiness: -1, strain: -1, band: '').toJson();
      expect(j['readiness'], isNull);
      expect(j['strain'], isNull);
      expect(j['readiness_band'], isNull);
    });
    test('sends no numbers when there is no fresh data', () {
      final j = n(hasData: false).toJson();
      expect(j['readiness'], isNull);
      expect(j['hrv_ms'], isNull);
    });
  });

  group('HardingSync.link', () {
    const key = 'hb_abcdefghijklmnopqrstuvwxyz0123456789-_ABCDEFG';
    final uri = Uri(scheme: 'hardingband', host: 'link', queryParameters: {'server': 'https://harding.pt', 'key': key});
    final numbers = HardingNumbers(hasData: true, readiness: 64, readinessBand: 'Good to go', hrv: 58, hrvBaseline: 52,
        restingHr: 51, sleepMin: 425, sleepNeedMin: 480, sleepEfficiency: 91, strain: 3.2, at: DateTime(2026, 10, 17, 7));
    late List<http.Request> calls;
    MockClient server({int whoami = 200}) => MockClient((r) async {
          calls.add(r);
          if (r.method == 'GET') return http.Response(jsonEncode({'ok': whoami == 200, 'name': 'Ana'}), whoami);
          return http.Response(jsonEncode({'ok': true, 'stored': true}), 200);
        });

    setUp(() async {
      calls = [];
      FlutterSecureStorage.setMockInitialValues({});
      await HardingSync.unlink();
      HardingSync.confirm = null;
    });

    test('links only after the person confirms the named account, then sends', () async {
      String? asked;
      HardingSync.confirm = (host, name, replacing) async { asked = '$host|$name|$replacing'; return true; };
      await HardingSync.send(numbers, client: server());
      expect(calls, isEmpty);
      expect(await HardingSync.link(uri, client: server()), isTrue);
      expect(asked, 'harding.pt|Ana|false');
      expect(HardingSync.linkedServer.value.toString(), 'https://harding.pt');
      await Future<void>.delayed(Duration.zero);
      final posts = calls.where((r) => r.method == 'POST').toList();
      expect(posts, hasLength(1));
      expect(posts.single.headers['Authorization'], 'Bearer $key');
      expect(posts.single.url.path, '/api/band/sync');
    });

    test('a cancelled confirmation links nothing and sends nothing', () async {
      HardingSync.confirm = (_, _, _) async => false;
      expect(await HardingSync.link(uri, client: server()), isFalse);
      expect(HardingSync.linkedServer.value, isNull);
      expect(calls.where((r) => r.method == 'POST'), isEmpty);
      expect(await HardingSync.send(numbers, client: server()), HardingSendResult.notLinked);
    });

    test('a key the server refuses is never offered', () async {
      var asked = false;
      HardingSync.confirm = (_, _, _) async => asked = true;
      expect(await HardingSync.link(uri, client: server(whoami: 401)), isFalse);
      expect(asked, isFalse);
      expect(HardingSync.linkedServer.value, isNull);
    });

    test('no dialog available: nothing is linked', () async {
      expect(await HardingSync.link(uri, client: server()), isFalse);
      expect(calls, isEmpty);
    });

    test('a foreign server is refused before any request', () async {
      HardingSync.confirm = (_, _, _) async => true;
      final evil = Uri(scheme: 'hardingband', host: 'link', queryParameters: {'server': 'https://evil.example', 'key': key});
      expect(await HardingSync.link(evil, client: server()), isFalse);
      expect(calls, isEmpty);
    });
  });
}

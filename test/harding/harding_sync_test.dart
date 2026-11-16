import 'dart:convert';

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
}

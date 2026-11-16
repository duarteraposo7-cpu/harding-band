// Opens `hardingband://link?…` from HARDING and stores the link.
import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'harding_sync.dart';

class HardingLinks {
  static StreamSubscription<Uri>? _sub;

  /// Never throws: a broken link must not stop the app from starting.
  static Future<void> start() async {
    try {
      await HardingSync.init();
      final links = AppLinks();
      _sub ??= links.uriLinkStream.listen(_open, onError: (Object e) => debugPrint('[harding] link: $e'));
    } catch (e) {
      debugPrint('[harding] links: $e');
    }
  }

  static void _open(Uri uri) {
    if (uri.scheme != 'hardingband') return;
    unawaited(HardingSync.link(uri));
  }
}

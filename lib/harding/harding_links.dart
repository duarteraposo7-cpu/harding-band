// Opens `hardingband://link?…` from HARDING and stores the link once the
// person confirms which account it is.
import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import 'harding_sync.dart';

class HardingLinks {
  static StreamSubscription<Uri>? _sub;
  static GlobalKey<NavigatorState>? navigatorKey;

  /// Never throws: a broken link must not stop the app from starting.
  static Future<void> start() async {
    try {
      await HardingSync.init();
      HardingSync.confirm = _confirm;
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

  static Future<bool> _confirm(String host, String name, bool replacing) async {
    final context = navigatorKey?.currentContext;
    if (context == null) return false;
    final who = name.isEmpty ? 'this account' : "$name's account";
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Send your band numbers to $who?'),
        content: Text(replacing ? '$host · replaces the current link' : host),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Link')),
        ],
      ),
    );
    return ok ?? false;
  }
}

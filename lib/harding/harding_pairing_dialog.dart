// Shows the code this phone got from HARDING and waits until the person types
// it in HARDING (Account → Band). Not part of upstream OpenStrap Edge.
import 'dart:async';

import 'package:flutter/material.dart';

import 'harding_sync.dart';

Future<void> showHardingPairing(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const HardingPairingDialog());

class HardingPairingDialog extends StatefulWidget {
  const HardingPairingDialog({super.key, this.pollEvery = const Duration(seconds: 3)});
  final Duration pollEvery;
  @override
  State<HardingPairingDialog> createState() => _HardingPairingDialogState();
}

class _HardingPairingDialogState extends State<HardingPairingDialog> {
  HardingPairing? _pairing;
  String? _error;
  bool _linked = false;
  bool _expired = false;
  Timer? _timer;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _timer?.cancel();
    setState(() {
      _pairing = null;
      _error = null;
      _expired = false;
    });
    try {
      final p = await HardingSync.startPairing();
      if (!mounted) return;
      setState(() => _pairing = p);
      _timer = Timer.periodic(widget.pollEvery, (_) => _poll());
    } on HardingError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _poll() async {
    final p = _pairing;
    if (p == null || _polling) return;
    _polling = true;
    try {
      final state = await HardingSync.poll(p);
      if (!mounted) return;
      switch (state) {
        case PairingLinked():
          _timer?.cancel();
          setState(() => _linked = true);
        case PairingExpired():
          _timer?.cancel();
          setState(() => _expired = true);
        case PairingPending() || PairingRetry():
          if (DateTime.now().isAfter(p.expiresAt)) {
            _timer?.cancel();
            setState(() => _expired = true);
          }
      }
    } finally {
      _polling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget body;
    if (_linked) {
      body = const Text('Linked');
    } else if (_error != null) {
      body = Text(_error!);
    } else if (_expired) {
      body = const Text('This code expired.');
    } else if (_pairing == null) {
      body = const SizedBox(height: 48, child: Center(child: CircularProgressIndicator()));
    } else {
      body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('HARDING → Account → Band'),
        const SizedBox(height: 12),
        SelectableText(
          _pairing!.code,
          key: const ValueKey('harding-pairing-code'),
          style: theme.textTheme.headlineMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], letterSpacing: 2),
        ),
      ]);
    }
    return AlertDialog(
      title: const Text('Link to HARDING'),
      content: body,
      actions: [
        if (_expired || _error != null) TextButton(onPressed: _start, child: const Text('New code')),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(_linked ? 'Done' : 'Cancel')),
      ],
    );
  }
}

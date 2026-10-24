import 'dart:async';

import 'package:flutter/material.dart';

import 'config/node_config.dart';
import 'services/airbridge_link.dart';
import 'services/airbridge_link_source.dart';
import 'services/node_controller.dart';
import 'ui/dashboard_page.dart';
import 'ui/pairing_dialog.dart';

class AirbridgeApp extends StatefulWidget {
  const AirbridgeApp({
    super.key,
    required this.config,
    required this.linkSource,
  });

  final NodeConfig config;
  final AirbridgeLinkSource linkSource;

  @override
  State<AirbridgeApp> createState() => _AirbridgeAppState();
}

class _AirbridgeAppState extends State<AirbridgeApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final NodeController _controller;
  late final Future<void> _startup;
  StreamSubscription<Uri>? _linkSubscription;
  String? _queuedPairingLink;
  String? _activePairingLink;
  bool _presentingPairingLink = false;

  @override
  void initState() {
    super.initState();
    _controller = NodeController(widget.config);
    _startup = _controller.start();
    _linkSubscription = widget.linkSource.stream.listen(
      _handleIncomingUri,
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Airbridge link listener failed: $error');
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_presentQueuedPairingLink());
    });
  }

  void _handleIncomingUri(Uri uri) {
    if (!isAirbridgePairingUri(uri)) return;
    final link = uri.toString();
    if (link == _queuedPairingLink || link == _activePairingLink) return;
    _queuedPairingLink = link;
    unawaited(_presentQueuedPairingLink());
  }

  Future<void> _presentQueuedPairingLink() async {
    if (!mounted || _presentingPairingLink || _queuedPairingLink == null) return;
    _presentingPairingLink = true;
    var consumedLink = false;
    try {
      await _startup;
      if (!mounted) return;
      final context = _navigatorKey.currentContext;
      if (context == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_presentQueuedPairingLink());
        });
        return;
      }

      final link = _queuedPairingLink!;
      _queuedPairingLink = null;
      _activePairingLink = link;
      consumedLink = true;
      await showPairingDialog(
        context,
        _controller,
        initialQrPayload: link,
      );
    } on Object catch (error) {
      debugPrint('Could not open Airbridge pairing link: $error');
    } finally {
      _activePairingLink = null;
      _presentingPairingLink = false;
      if (mounted && consumedLink && _queuedPairingLink != null) {
        unawaited(_presentQueuedPairingLink());
      }
    }
  }

  Future<void> _disposeLinks() async {
    await _linkSubscription?.cancel();
    await widget.linkSource.dispose();
  }

  @override
  void dispose() {
    unawaited(_disposeLinks());
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: _navigatorKey,
        title: 'Airbridge',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0B0F19),
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF63E6BE),
            brightness: Brightness.dark,
            surface: const Color(0xFF111827),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF0C1220),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF263247)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF263247)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF63E6BE)),
            ),
          ),
        ),
        home: DashboardPage(controller: _controller),
      );
}

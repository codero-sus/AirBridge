import 'dart:async';

import 'package:flutter/material.dart';

import 'config/node_config.dart';
import 'services/node_controller.dart';
import 'ui/dashboard_page.dart';

class AirbridgeApp extends StatefulWidget {
  const AirbridgeApp({super.key, required this.config});

  final NodeConfig config;

  @override
  State<AirbridgeApp> createState() => _AirbridgeAppState();
}

class _AirbridgeAppState extends State<AirbridgeApp> {
  late final NodeController _controller;

  @override
  void initState() {
    super.initState();
    _controller = NodeController(widget.config);
    unawaited(_controller.start());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
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

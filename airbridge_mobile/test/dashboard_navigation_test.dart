import 'dart:io';

import 'package:airbridge_mobile/config/node_config.dart';
import 'package:airbridge_mobile/services/node_controller.dart';
import 'package:airbridge_mobile/ui/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

NodeController _newController() => NodeController(
      NodeConfig.forTesting(
        deviceId: '00000000-0000-4000-8000-000000000001',
        deviceName: 'Navigation test node',
        supportDirectory: Directory.systemTemp,
        messageDirectory: Directory.systemTemp,
        httpPort: 18765,
      ),
    );

void _setTestViewport(WidgetTester tester, Size size) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
}

void _resetTestViewport(WidgetTester tester) {
  tester.view
    ..resetPhysicalSize()
    ..resetDevicePixelRatio();
}

void main() {
  testWidgets('desktop sidebar switches between dashboard sections', (
    tester,
  ) async {
    final controller = _newController();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      _resetTestViewport(tester);
    });

    _setTestViewport(tester, const Size(1280, 900));
    await tester.pumpWidget(
      MaterialApp(home: DashboardPage(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('WORKSPACE'), findsOneWidget);
    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();
    expect(
      find.text('Broadcast payloads and search the message history.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Activity').first);
    await tester.pumpAndSettle();
    expect(
      find.text('Recent startup, discovery, pairing, and delivery events.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Files').first);
    await tester.pumpAndSettle();
    expect(find.text('File transfers'), findsOneWidget);

    await tester.tap(find.text('Bluetooth').first);
    await tester.pumpAndSettle();
    expect(find.text('Bluetooth LE'), findsOneWidget);

    await tester.tap(find.text('Troubleshooting').first);
    await tester.pumpAndSettle();
    expect(find.text('Quick diagnostics for discovery, pairing, file delivery, and Bluetooth.'), findsOneWidget);

    await tester.tap(find.text('Docs').first);
    await tester.pumpAndSettle();
    expect(find.text('Airbridge docs'), findsOneWidget);

    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(find.text('Transport security'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Accept files from paired peers'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Accept files from paired peers'), findsOneWidget);
  });

  testWidgets('mobile drawer navigates to the peer list', (tester) async {
    final controller = _newController();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      _resetTestViewport(tester);
    });

    _setTestViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(home: DashboardPage(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Open navigation'), findsOneWidget);
    await tester.tap(find.byTooltip('Open navigation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mesh peers'));
    await tester.pumpAndSettle();
    expect(
      find.text('Devices discovered on this subnet. Pairing establishes trust.'),
      findsOneWidget,
    );
  });
}

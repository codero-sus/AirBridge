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

void main() {
  testWidgets('desktop sidebar switches between dashboard sections', (
    tester,
  ) async {
    final controller = _newController();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.binding.setSurfaceSize(const Size(1280, 900));
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
  });

  testWidgets('mobile drawer navigates to the peer list', (tester) async {
    final controller = _newController();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.binding.setSurfaceSize(const Size(390, 844));
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

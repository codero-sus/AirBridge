import 'dart:io';

import 'package:airbridge_mobile/config/node_config.dart';
import 'package:airbridge_mobile/services/node_controller.dart';
import 'package:airbridge_mobile/ui/dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'sidebar navigation adapts to desktop and mobile layouts',
    (tester) async {
    final directory = await Directory.systemTemp.createTemp('airbridge-ui-');
    final controller = NodeController(
      NodeConfig.forTesting(
        deviceId: '00000000-0000-4000-8000-000000000001',
        deviceName: 'Navigation test node',
        supportDirectory: directory,
        messageDirectory: directory,
        httpPort: 18765,
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.binding.setSurfaceSize(null);
      if (await directory.exists()) await directory.delete(recursive: true);
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

    await tester.binding.setSurfaceSize(const Size(390, 844));
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

import 'dart:io';

import 'package:flutter/widgets.dart';

import 'app.dart';
import 'config/node_config.dart';
import 'services/airbridge_link_source.dart';
import 'services/update_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final linkSource = AirbridgeLinkSource();
  final config = await NodeConfig.load();
  final updateService = AutoUpdateService(
    supportDirectory: config.supportDirectory,
  );
  if (await updateService.applyPendingUpdateBeforeLaunch()) exit(0);
  runApp(
    AirbridgeApp(
      config: config,
      linkSource: linkSource,
      updateService: updateService,
    ),
  );
}

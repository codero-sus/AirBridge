import 'package:flutter/widgets.dart';

import 'app.dart';
import 'config/node_config.dart';
import 'services/airbridge_link_source.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final linkSource = AirbridgeLinkSource();
  final config = await NodeConfig.load();
  runApp(AirbridgeApp(config: config, linkSource: linkSource));
}

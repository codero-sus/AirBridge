import 'package:flutter/widgets.dart';

import 'app.dart';
import 'config/node_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = await NodeConfig.load();
  runApp(AirbridgeApp(config: config));
}

import 'dart:async';

import 'package:app_links/app_links.dart';

/// Starts listening before asynchronous app setup and buffers any cold-start URL
/// until the navigation tree is ready to present the pairing flow.
class AirbridgeLinkSource {
  AirbridgeLinkSource() {
    _nativeSubscription = _appLinks.uriLinkStream.listen(
      _incomingLinks.add,
      onError: _incomingLinks.addError,
    );
  }

  final AppLinks _appLinks = AppLinks();
  final StreamController<Uri> _incomingLinks = StreamController<Uri>();
  late final StreamSubscription<Uri> _nativeSubscription;

  Stream<Uri> get stream => _incomingLinks.stream;

  Future<void> dispose() async {
    await _nativeSubscription.cancel();
    await _incomingLinks.close();
  }
}

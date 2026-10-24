import 'package:airbridge_mobile/services/airbridge_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes the Airbridge pairing URL scheme', () {
    expect(isAirbridgePairingUri(Uri.parse('airbridge://pair?v=1')), isTrue);
    expect(isAirbridgePairingUri(Uri.parse('AIRBRIDGE://PAIR?v=1')), isTrue);
    expect(isAirbridgePairingUri(Uri.parse('https://example.com')), isFalse);
    expect(isAirbridgePairingUri(Uri.parse('airbridge://settings')), isFalse);
  });
}

import 'package:airbridge_mobile/models/node_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('message JSON export preserves identity, payload text, timestamp, and direction', () {
    final message = NodeMessage(
      messageId: 'message-1',
      senderId: 'node-1',
      senderName: 'Test node',
      text: '{"text":"hello"}',
      timestamp: DateTime.utc(2026, 10, 11, 12, 30),
      isLocal: true,
    );

    expect(message.toJson(), <String, Object?>{
      'messageId': 'message-1',
      'senderId': 'node-1',
      'senderName': 'Test node',
      'payloadText': '{"text":"hello"}',
      'timestamp': '2026-10-11T12:30:00.000Z',
      'isLocal': true,
    });
  });

  test('system log JSON export includes UTC timestamp, level, and message', () {
    final entry = NodeLogEntry(
      timestamp: DateTime.utc(2026, 10, 16, 12, 30),
      level: 'WARN',
      message: 'Retry scheduled',
    );

    expect(entry.toJson(), <String, Object?>{
      'timestamp': '2026-10-16T12:30:00.000Z',
      'level': 'WARN',
      'message': 'Retry scheduled',
    });
  });
}

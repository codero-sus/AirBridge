import 'dart:io';

import 'package:airbridge_mobile/services/task_worker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late TaskWorker worker;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('airbridge-worker-test-');
    worker = TaskWorker(maxConcurrent: 1, maxQueued: 4);
  });

  tearDown(() async {
    await worker.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('encrypts, stores, and decrypts a message envelope', () async {
    const secret = 'a-production-style-test-secret-with-at-least-32-bytes';
    final envelope = await worker.storeMessage(
      directoryPath: directory.path,
      sharedSecret: secret,
      messageId: 'message-test-1',
      senderId: 'node-test-1',
      senderName: 'Test node',
      createdAt: DateTime.utc(2025, 1, 1),
      payload: <String, Object?>{'text': 'hello mesh', 'count': 3},
      maxPayloadBytes: 4096,
    );

    expect(envelope['algorithm'], 'AES-256-GCM');
    expect(envelope.containsKey('payload'), isFalse);
    final decoded = await worker.decodeEnvelope(
      sharedSecret: secret,
      envelope: envelope,
    );
    expect(decoded, <String, Object?>{'text': 'hello mesh', 'count': 3});
    expect(await directory.list().length, 1);
  });

  test('uses clear JSON only when no shared secret is configured', () async {
    final envelope = await worker.storeMessage(
      directoryPath: directory.path,
      sharedSecret: '',
      messageId: 'message-test-2',
      senderId: 'node-test-1',
      senderName: 'Test node',
      createdAt: DateTime.utc(2025, 1, 1),
      payload: 'open mode',
      maxPayloadBytes: 4096,
    );

    expect(envelope['algorithm'], 'none');
    expect(
      await worker.decodeEnvelope(sharedSecret: '', envelope: envelope),
      'open mode',
    );
  });

  test('loads a recent persisted history snapshot in chronological order', () async {
    const secret = 'history-test-secret-with-at-least-32-bytes-for-aes';
    for (var index = 1; index <= 3; index++) {
      await worker.storeMessage(
        directoryPath: directory.path,
        sharedSecret: secret,
        messageId: 'history-$index',
        senderId: 'node-test-1',
        senderName: 'Test node',
        createdAt: DateTime.utc(2025, 1, 1, 0, 0, index),
        payload: 'message $index',
        maxPayloadBytes: 4096,
      );
    }

    final history = await worker.loadRecentMessages(
      directoryPath: directory.path,
      sharedSecret: secret,
    );
    expect(history.map((message) => message['messageId']), <String>[
      'history-1',
      'history-2',
      'history-3',
    ]);
    expect(history.map((message) => message['text']), <String>[
      'message 1',
      'message 2',
      'message 3',
    ]);

    final tooSmallBudget = await worker.loadRecentMessages(
      directoryPath: directory.path,
      sharedSecret: secret,
      maxBytes: 1,
    );
    expect(tooSmallBudget, isEmpty);

    final wrongSecret = await worker.loadRecentMessages(
      directoryPath: directory.path,
      sharedSecret: 'another-secret-with-at-least-32-bytes',
    );
    expect(wrongSecret, isEmpty);
  });
}

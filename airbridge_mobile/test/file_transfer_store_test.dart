import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:airbridge_mobile/services/file_transfer_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory supportDirectory;
  late FileTransferStore store;

  setUp(() async {
    supportDirectory =
        await Directory.systemTemp.createTemp('airbridge-file-store-test-');
    store = FileTransferStore(supportDirectory: supportDirectory);
    await store.loadExisting();
  });

  tearDown(() async {
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  test('assembles, verifies, and persists an incoming file', () async {
    const contents = <int>[1, 3, 5, 7, 9, 11];
    const transferId = 'transfer-0001';
    await store.beginTransfer(
      transferId: transferId,
      fileName: r'folder\report.bin',
      sizeBytes: contents.length,
      sha256Hex: sha256.convert(contents).toString(),
      source: 'LAN',
      senderId: 'trusted-device',
      senderName: 'Trusted sender',
    );
    await store.addChunk(transferId: transferId, index: 0, bytes: contents.take(3).toList());
    await store.addChunk(transferId: transferId, index: 1, bytes: contents.skip(3).toList());

    final record = await store.completeTransfer(transferId);
    expect(record.fileName, 'report.bin');
    expect(record.source, 'LAN');
    expect(await File(record.path).readAsBytes(), contents);
    expect(store.records, hasLength(1));

    final restored = FileTransferStore(supportDirectory: supportDirectory);
    await restored.loadExisting();
    expect(restored.records, hasLength(1));
    expect(restored.records.single.transferId, transferId);
    expect(restored.records.single.fileName, 'report.bin');
  });

  test('rejects wrong chunk ordering and failed file integrity', () async {
    const transferId = 'transfer-0002';
    await store.beginTransfer(
      transferId: transferId,
      fileName: 'broken.txt',
      sizeBytes: 3,
      sha256Hex: sha256.convert(utf8.encode('abc')).toString(),
      source: 'Bluetooth',
      senderId: 'trusted-device',
      senderName: 'Trusted sender',
    );
    await expectLater(
      store.addChunk(transferId: transferId, index: 1, bytes: utf8.encode('abc')),
      throwsA(isA<FileTransferException>()),
    );
    await store.addChunk(transferId: transferId, index: 0, bytes: utf8.encode('xyz'));
    await expectLater(
      store.completeTransfer(transferId),
      throwsA(isA<FileTransferException>()),
    );
    expect(await Directory('${supportDirectory.path}/files/receiving').list().isEmpty, isTrue);
    expect(store.records, isEmpty);
  });

  test('enforces the configured maximum incoming file size', () async {
    store.maxIncomingFileBytes = 2;
    await expectLater(
      store.beginTransfer(
        transferId: 'transfer-0003',
        fileName: 'large.bin',
        sizeBytes: 3,
        sha256Hex: sha256.convert(<int>[]).toString(),
        source: 'LAN',
        senderId: 'trusted-device',
        senderName: 'Trusted sender',
      ),
      throwsA(isA<FileTransferException>()),
    );
  });
}

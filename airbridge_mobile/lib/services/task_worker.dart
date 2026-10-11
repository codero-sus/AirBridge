import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';

class WorkerQueueFullException implements Exception {
  const WorkerQueueFullException();

  @override
  String toString() => 'The Airbridge background task queue is full.';
}

/// A bounded task queue. File I/O and AES-GCM are performed in worker isolates,
/// not on Flutter's UI isolate. Queued tasks are drained during [close].
class TaskWorker {
  TaskWorker({this.maxConcurrent = 2, this.maxQueued = 64}) {
    if (maxConcurrent < 1 || maxQueued < 1) {
      throw ArgumentError('Worker limits must be positive.');
    }
  }

  final int maxConcurrent;
  final int maxQueued;
  final Queue<_QueueItem> _pending = Queue<_QueueItem>();
  int _active = 0;
  bool _accepting = true;
  Completer<void>? _drained;

  int get pendingCount => _pending.length + _active;

  Future<T> submit<T>(Future<T> Function() work) {
    if (!_accepting) {
      return Future<T>.error(StateError('TaskWorker is closed.'));
    }
    if (_pending.length >= maxQueued) {
      return Future<T>.error(const WorkerQueueFullException());
    }
    final item = _TypedQueueItem<T>(work);
    _pending.add(item);
    _pump();
    return item.result;
  }

  Future<Map<String, dynamic>> storeMessage({
    required String directoryPath,
    required String sharedSecret,
    required String messageId,
    required String senderId,
    required String senderName,
    required DateTime createdAt,
    required Object? payload,
    required int maxPayloadBytes,
  }) {
    final input = <String, Object?>{
      'directoryPath': directoryPath,
      'sharedSecret': sharedSecret,
      'messageId': messageId,
      'senderId': senderId,
      'senderName': senderName,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'payload': payload,
      'maxPayloadBytes': maxPayloadBytes,
    };
    return submit<Map<String, dynamic>>(
      () => Isolate.run<Map<String, dynamic>>(
        () => _createAndPersistEnvelope(input),
        debugName: 'airbridge-encrypt-and-store',
      ),
    );
  }

  Future<void> persistReceivedEnvelope({
    required String directoryPath,
    required Map<String, dynamic> envelope,
  }) {
    final input = <String, Object?>{
      'directoryPath': directoryPath,
      'envelope': envelope,
    };
    return submit<void>(
      () => Isolate.run<void>(
        () => _persistReceivedEnvelope(input),
        debugName: 'airbridge-store-peer-envelope',
      ),
    );
  }

  Future<Object?> decodeEnvelope({
    required String sharedSecret,
    required Map<String, dynamic> envelope,
  }) {
    final input = <String, Object?>{
      'sharedSecret': sharedSecret,
      'envelope': envelope,
    };
    return submit<Object?>(
      () => Isolate.run<Object?>(
        () => _decodeEnvelope(input),
        debugName: 'airbridge-decrypt-envelope',
      ),
    );
  }

  /// Reads and decrypts a bounded recent history snapshot in one worker isolate.
  /// The byte budget prevents a large spool from causing an unbounded UI heap.
  Future<List<Map<String, Object?>>> loadRecentMessages({
    required String directoryPath,
    required String sharedSecret,
    int limit = 100,
    int maxBytes = 8 * 1024 * 1024,
  }) {
    if (limit < 1 ||
        limit > 5000 ||
        maxBytes < 1 ||
        maxBytes > 32 * 1024 * 1024) {
      throw ArgumentError('History limits are outside their supported bounds.');
    }
    final input = <String, Object?>{
      'directoryPath': directoryPath,
      'sharedSecret': sharedSecret,
      'limit': limit,
      'maxBytes': maxBytes,
    };
    return submit<List<Map<String, Object?>>>(
      () => Isolate.run<List<Map<String, Object?>>>(
        () => _loadRecentMessages(input),
        debugName: 'airbridge-load-message-history',
      ),
    );
  }

  Future<void> close() {
    _accepting = false;
    _pump();
    if (_pending.isEmpty && _active == 0) return Future<void>.value();
    _drained ??= Completer<void>();
    return _drained!.future;
  }

  void _pump() {
    while (_active < maxConcurrent && _pending.isNotEmpty) {
      final item = _pending.removeFirst();
      _active++;
      unawaited(_run(item));
    }
    _finishCloseIfDrained();
  }

  Future<void> _run(_QueueItem item) async {
    try {
      await item.execute();
    } finally {
      _active--;
      _pump();
    }
  }

  void _finishCloseIfDrained() {
    if (!_accepting && _pending.isEmpty && _active == 0) {
      final completer = _drained;
      if (completer != null && !completer.isCompleted) completer.complete();
    }
  }
}

abstract class _QueueItem {
  Future<void> execute();
}

class _TypedQueueItem<T> implements _QueueItem {
  _TypedQueueItem(this._work);

  final Future<T> Function() _work;
  final Completer<T> _completer = Completer<T>();

  Future<T> get result => _completer.future;

  @override
  Future<void> execute() async {
    try {
      final value = await _work();
      if (!_completer.isCompleted) _completer.complete(value);
    } catch (error, stackTrace) {
      if (!_completer.isCompleted) {
        _completer.completeError(error, stackTrace);
      }
    }
  }
}

Future<Map<String, dynamic>> _createAndPersistEnvelope(
  Map<String, Object?> input,
) async {
  final messageId = input['messageId']! as String;
  final senderId = input['senderId']! as String;
  final sharedSecret = input['sharedSecret']! as String;
  final payload = input['payload'];
  final clearText = utf8.encode(jsonEncode(payload));
  final maxPayloadBytes = input['maxPayloadBytes']! as int;
  if (clearText.length > maxPayloadBytes) {
    throw const FormatException('Payload exceeds the configured size limit.');
  }
  final envelope = <String, dynamic>{
    'version': 1,
    'id': messageId,
    'senderId': senderId,
    'senderName': input['senderName']! as String,
    'createdAt': input['createdAt']! as String,
  };

  if (sharedSecret.isEmpty) {
    envelope
      ..['algorithm'] = 'none'
      ..['payload'] = payload;
  } else {
    final keyBytes = sha256
        .convert(utf8.encode('airbridge-aes-gcm-v1:$sharedSecret'))
        .bytes;
    final aad = utf8.encode('airbridge-message-v1:$messageId:$senderId');
    final algorithm = AesGcm.with256bits();
    final nonce = algorithm.newNonce();
    final secretBox = await algorithm.encrypt(
      clearText,
      secretKey: SecretKey(keyBytes),
      nonce: nonce,
      aad: aad,
    );
    envelope
      ..['algorithm'] = 'AES-256-GCM'
      ..['nonce'] = base64Encode(secretBox.nonce)
      ..['ciphertext'] = base64Encode(secretBox.cipherText)
      ..['mac'] = base64Encode(secretBox.mac.bytes);
  }

  await _writeEnvelope(input['directoryPath']! as String, envelope);
  return envelope;
}

Future<void> _persistReceivedEnvelope(Map<String, Object?> input) async {
  final envelope = Map<String, dynamic>.from(
    input['envelope']! as Map<dynamic, dynamic>,
  );
  await _writeEnvelope(input['directoryPath']! as String, envelope);
}

Future<Object?> _decodeEnvelope(Map<String, Object?> input) async {
  final envelope = Map<String, dynamic>.from(
    input['envelope']! as Map<dynamic, dynamic>,
  );
  final algorithmName = envelope['algorithm'];
  if (algorithmName == 'none') return envelope['payload'];
  if (algorithmName != 'AES-256-GCM') {
    throw const FormatException('Unsupported Airbridge message encryption.');
  }

  final secret = input['sharedSecret']! as String;
  if (secret.isEmpty) {
    throw const FormatException('This encrypted message requires a shared secret.');
  }
  final messageId = envelope['id']! as String;
  final senderId = envelope['senderId']! as String;
  final keyBytes = sha256
      .convert(utf8.encode('airbridge-aes-gcm-v1:$secret'))
      .bytes;
  final aad = utf8.encode('airbridge-message-v1:$messageId:$senderId');
  final box = SecretBox(
    base64Decode(envelope['ciphertext']! as String),
    nonce: base64Decode(envelope['nonce']! as String),
    mac: Mac(base64Decode(envelope['mac']! as String)),
  );
  final clearText = await AesGcm.with256bits().decrypt(
    box,
    secretKey: SecretKey(keyBytes),
    aad: aad,
  );
  return jsonDecode(utf8.decode(clearText));
}

Future<List<Map<String, Object?>>> _loadRecentMessages(
  Map<String, Object?> input,
) async {
  final directory = Directory(input['directoryPath']! as String);
  if (!await directory.exists()) return <Map<String, Object?>>[];

  final records = <_SpoolEntry>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.json')) continue;
    try {
      final stat = await entity.stat();
      records.add(_SpoolEntry(entity, stat.modified, stat.size));
    } on FileSystemException {
      // A concurrent writer may be replacing the file.
    }
  }
  records.sort((left, right) => right.modified.compareTo(left.modified));

  final secret = input['sharedSecret']! as String;
  final limit = input['limit']! as int;
  final maxBytes = input['maxBytes']! as int;
  var bytesRead = 0;
  final messages = <Map<String, Object?>>[];
  for (final record in records) {
    if (messages.length >= limit) break;
    if (record.size > maxBytes - bytesRead) continue;
    bytesRead += record.size;
    try {
      final raw = jsonDecode(await record.file.readAsString());
      if (raw is! Map<String, dynamic>) continue;
      final envelope = Map<String, dynamic>.from(raw);
      final messageId = envelope['id'];
      final senderId = envelope['senderId'];
      if (messageId is! String ||
          messageId.isEmpty ||
          senderId is! String ||
          senderId.isEmpty) {
        continue;
      }
      final decoded = await _decodeEnvelope(<String, Object?>{
        'sharedSecret': secret,
        'envelope': envelope,
      });
      final senderName = envelope['senderName'];
      final createdAt = envelope['createdAt'];
      messages.add(<String, Object?>{
        'messageId': messageId,
        'senderId': senderId,
        'senderName': senderName is String ? senderName : 'Airbridge peer',
        'text': decoded is String
            ? decoded
            : const JsonEncoder.withIndent('  ').convert(decoded),
        'timestamp': DateTime.tryParse(createdAt is String ? createdAt : '')
                ?.toUtc()
                .toIso8601String() ??
            record.modified.toUtc().toIso8601String(),
      });
    } on Object {
      // Ignore corrupt records or messages encrypted with a different secret.
    }
  }
  messages.sort((left, right) {
    final leftTime = DateTime.parse(left['timestamp']! as String);
    final rightTime = DateTime.parse(right['timestamp']! as String);
    return leftTime.compareTo(rightTime);
  });
  return messages;
}

Future<void> _writeEnvelope(
  String directoryPath,
  Map<String, dynamic> envelope,
) async {
  final directory = Directory(directoryPath);
  await directory.create(recursive: true);
  final messageId = envelope['id'];
  if (messageId is! String || messageId.isEmpty) {
    throw const FormatException('Message envelope has no valid id.');
  }
  final filename = sha256.convert(utf8.encode(messageId)).toString();
  final destination = File(
    '${directory.path}${Platform.pathSeparator}$filename.json',
  );
  final temporary = File(
    '${destination.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  await temporary.writeAsString(jsonEncode(envelope), flush: true);
  try {
    await temporary.rename(destination.path);
  } on FileSystemException {
    if (await destination.exists()) await destination.delete();
    await temporary.rename(destination.path);
  }
  await _pruneSpool(directory);
}

Future<void> _pruneSpool(Directory directory) async {
  const maxRecords = 5000;
  const maxBytes = 256 * 1024 * 1024;
  final records = <_SpoolEntry>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.json')) continue;
    try {
      final stat = await entity.stat();
      records.add(_SpoolEntry(entity, stat.modified, stat.size));
    } on FileSystemException {
      // A concurrent worker may already have removed the record.
    }
  }
  var totalBytes = records.fold<int>(0, (total, record) => total + record.size);
  if (records.length <= maxRecords && totalBytes <= maxBytes) return;

  // Most writes stay below the caps; avoid sorting the full spool on those.
  records.sort((left, right) => left.modified.compareTo(right.modified));
  var removed = 0;
  while (records.length - removed > maxRecords || totalBytes > maxBytes) {
    final record = records[removed++];
    try {
      await record.file.delete();
    } on FileSystemException {
      // Best-effort pruning; another isolate may have won the race.
    }
    totalBytes -= record.size;
  }
}

class _SpoolEntry {
  const _SpoolEntry(this.file, this.modified, this.size);

  final File file;
  final DateTime modified;
  final int size;
}

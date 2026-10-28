import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;

const int defaultMaxIncomingFileBytes = 100 * 1024 * 1024;
const int maxSupportedIncomingFileBytes = 1024 * 1024 * 1024;

class FileTransferException implements Exception {
  const FileTransferException(this.message, {this.statusCode = HttpStatus.badRequest});

  final String message;
  final int statusCode;

  @override
  String toString() => message;
}

class FileTransferRecord {
  const FileTransferRecord({
    required this.transferId,
    required this.fileName,
    required this.sizeBytes,
    required this.path,
    required this.receivedAt,
    required this.source,
    required this.senderId,
    required this.senderName,
  });

  final String transferId;
  final String fileName;
  final int sizeBytes;
  final String path;
  final DateTime receivedAt;
  final String source;
  final String senderId;
  final String senderName;

  Map<String, Object?> toJson() => <String, Object?>{
        'transferId': transferId,
        'fileName': fileName,
        'sizeBytes': sizeBytes,
        'path': path,
        'receivedAt': receivedAt.toUtc().toIso8601String(),
        'source': source,
        'senderId': senderId,
        'senderName': senderName,
      };
}

/// A bounded on-disk receiver shared by LAN and BLE transfers. File bytes are
/// appended in order to a private temporary file and made visible only after
/// the final length and SHA-256 digest have been verified.
class FileTransferStore {
  FileTransferStore({
    required Directory supportDirectory,
    this.maxIncomingFileBytes = defaultMaxIncomingFileBytes,
  })  : _root = Directory(
          '${supportDirectory.path}${Platform.pathSeparator}files',
        ),
        _receiving = Directory(
          '${supportDirectory.path}${Platform.pathSeparator}files'
          '${Platform.pathSeparator}receiving',
        ),
        _received = Directory(
          '${supportDirectory.path}${Platform.pathSeparator}files'
          '${Platform.pathSeparator}received',
        );

  final Directory _root;
  final Directory _receiving;
  final Directory _received;
  final Map<String, _IncomingFile> _active = <String, _IncomingFile>{};
  final Map<String, FileTransferRecord> _records = <String, FileTransferRecord>{};

  int maxIncomingFileBytes;

  List<FileTransferRecord> get records {
    final result = _records.values.toList(growable: false)
      ..sort((left, right) => right.receivedAt.compareTo(left.receivedAt));
    return List<FileTransferRecord>.unmodifiable(result);
  }

  String get receivedDirectoryPath => _received.path;

  Future<void> loadExisting() async {
    await _root.create(recursive: true);
    await _receiving.create(recursive: true);
    await _received.create(recursive: true);
    _records.clear();

    await for (final entity in _received.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.airbridge-meta.json')) {
        continue;
      }
      try {
        final decoded = jsonDecode(await entity.readAsString());
        final record = _parseStoredRecord(decoded);
        if (record == null) continue;
        final file = File(record.path);
        if (await file.exists() && await file.length() == record.sizeBytes) {
          _records[record.transferId] = record;
        }
      } on Object {
        // Ignore a corrupt sidecar; the original file is left untouched.
      }
    }
  }

  Future<void> beginTransfer({
    required String transferId,
    required String fileName,
    required int sizeBytes,
    required String sha256Hex,
    required String source,
    required String senderId,
    required String senderName,
  }) async {
    _validateTransferId(transferId);
    if (sizeBytes < 0 || sizeBytes > maxIncomingFileBytes) {
      throw FileTransferException(
        'This file is larger than the configured ${_formatBytes(maxIncomingFileBytes)} receive limit.',
        statusCode: HttpStatus.requestEntityTooLarge,
      );
    }
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256Hex)) {
      throw const FileTransferException('The file SHA-256 digest is invalid.');
    }
    if (_active.containsKey(transferId) || _records.containsKey(transferId)) {
      throw const FileTransferException('This file transfer ID has already been used.');
    }

    final safeName = _safeFileName(fileName);
    final part = File('${_receiving.path}${Platform.pathSeparator}$transferId.part');
    await part.writeAsBytes(const <int>[], flush: true);
    _active[transferId] = _IncomingFile(
      transferId: transferId,
      fileName: safeName,
      sizeBytes: sizeBytes,
      expectedSha256: sha256Hex.toLowerCase(),
      source: source,
      senderId: senderId,
      senderName: _safeSenderName(senderName),
      partFile: part,
      nextChunkIndex: 0,
      receivedBytes: 0,
    );
  }

  Future<void> addChunk({
    required String transferId,
    required int index,
    required List<int> bytes,
  }) async {
    final incoming = _active[transferId];
    if (incoming == null) {
      throw const FileTransferException('The file transfer is not active.');
    }
    if (index != incoming.nextChunkIndex) {
      throw FileTransferException(
        'Unexpected file chunk $index; expected ${incoming.nextChunkIndex}.',
        statusCode: HttpStatus.conflict,
      );
    }
    if (bytes.isEmpty || incoming.receivedBytes + bytes.length > incoming.sizeBytes) {
      throw const FileTransferException('The file chunk length is invalid.');
    }

    final handle = await incoming.partFile.open(mode: FileMode.append);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
    incoming.receivedBytes += bytes.length;
    incoming.nextChunkIndex++;
  }

  Future<FileTransferRecord> completeTransfer(String transferId) async {
    final incoming = _active[transferId];
    if (incoming == null) {
      throw const FileTransferException('The file transfer is not active.');
    }
    final actualLength = await incoming.partFile.length();
    if (actualLength != incoming.sizeBytes ||
        incoming.receivedBytes != incoming.sizeBytes) {
      throw FileTransferException(
        'The received file is incomplete (${_formatBytes(actualLength)} of '
        '${_formatBytes(incoming.sizeBytes)}).',
        statusCode: HttpStatus.conflict,
      );
    }
    final digest = await sha256.bind(incoming.partFile.openRead()).first;
    if (digest.toString() != incoming.expectedSha256) {
      await cancelTransfer(transferId);
      throw const FileTransferException(
        'The received file failed its SHA-256 integrity check.',
        statusCode: HttpStatus.unprocessableEntity,
      );
    }

    final storedName = '${transferId}_${incoming.fileName}';
    final destination = File('${_received.path}${Platform.pathSeparator}$storedName');
    if (await destination.exists()) {
      await cancelTransfer(transferId);
      throw const FileTransferException('A file with this transfer ID already exists.');
    }
    await incoming.partFile.rename(destination.path);
    _active.remove(transferId);

    final record = FileTransferRecord(
      transferId: transferId,
      fileName: incoming.fileName,
      sizeBytes: actualLength,
      path: destination.path,
      receivedAt: DateTime.now().toUtc(),
      source: incoming.source,
      senderId: incoming.senderId,
      senderName: incoming.senderName,
    );
    final sidecar = File('${destination.path}.airbridge-meta.json');
    final temporarySidecar = File('${sidecar.path}.tmp');
    await temporarySidecar.writeAsString(jsonEncode(record.toJson()), flush: true);
    await temporarySidecar.rename(sidecar.path);
    _records[transferId] = record;
    return record;
  }

  Future<void> cancelTransfer(String transferId) async {
    final incoming = _active.remove(transferId);
    if (incoming == null) return;
    try {
      if (await incoming.partFile.exists()) await incoming.partFile.delete();
    } on FileSystemException {
      // Best-effort cleanup of a partially received file.
    }
  }

  static FileTransferRecord? _parseStoredRecord(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final transferId = value['transferId'];
    final fileName = value['fileName'];
    final size = value['sizeBytes'];
    final path = value['path'];
    final receivedAt = value['receivedAt'];
    final source = value['source'];
    final senderId = value['senderId'];
    final senderName = value['senderName'];
    if (transferId is! String ||
        !_transferIdPattern.hasMatch(transferId) ||
        fileName is! String ||
        fileName.isEmpty ||
        size is! int ||
        size < 0 ||
        path is! String ||
        path.isEmpty ||
        receivedAt is! String ||
        DateTime.tryParse(receivedAt) == null ||
        source is! String ||
        senderId is! String ||
        senderName is! String) {
      return null;
    }
    final storedName = path.split(Platform.pathSeparator).last;
    if (!storedName.startsWith('${transferId}_') ||
        storedName.contains('/') ||
        storedName.contains('\\')) {
      return null;
    }
    return FileTransferRecord(
      transferId: transferId,
      fileName: fileName,
      sizeBytes: size,
      path: path,
      receivedAt: DateTime.parse(receivedAt).toUtc(),
      source: source,
      senderId: senderId,
      senderName: senderName,
    );
  }

  static void _validateTransferId(String transferId) {
    if (!_transferIdPattern.hasMatch(transferId)) {
      throw const FileTransferException('The file transfer ID is invalid.');
    }
  }

  static String _safeFileName(String value) {
    final leaf = value.replaceAll('\\', '/').split('/').last;
    final cleaned = leaf
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
        .replaceAll(RegExp(r'[:*?"<>|]'), '_')
        .trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'received-file';
    return cleaned.length > 180 ? cleaned.substring(cleaned.length - 180) : cleaned;
  }

  static String _safeSenderName(String value) {
    final cleaned = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
    if (cleaned.isEmpty) return 'Airbridge peer';
    return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
  }

  static String _formatBytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

final RegExp _transferIdPattern = RegExp(r'^[a-fA-F0-9-]{8,64}$');

class _IncomingFile {
  _IncomingFile({
    required this.transferId,
    required this.fileName,
    required this.sizeBytes,
    required this.expectedSha256,
    required this.source,
    required this.senderId,
    required this.senderName,
    required this.partFile,
    required this.nextChunkIndex,
    required this.receivedBytes,
  });

  final String transferId;
  final String fileName;
  final int sizeBytes;
  final String expectedSha256;
  final String source;
  final String senderId;
  final String senderName;
  final File partFile;
  int nextChunkIndex;
  int receivedBytes;
}

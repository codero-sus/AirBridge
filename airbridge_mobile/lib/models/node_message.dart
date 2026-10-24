class NodeMessage {
  const NodeMessage({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.timestamp,
    required this.isLocal,
  });

  final String messageId;
  final String senderId;
  final String senderName;
  final String text;
  final DateTime timestamp;
  final bool isLocal;

  Map<String, Object?> toJson() => <String, Object?>{
        'messageId': messageId,
        'senderId': senderId,
        'senderName': senderName,
        'payloadText': text,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'isLocal': isLocal,
      };
}

class NodeLogEntry {
  const NodeLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  final DateTime timestamp;
  final String level;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
        'timestamp': timestamp.toUtc().toIso8601String(),
        'level': level,
        'message': message,
      };
}

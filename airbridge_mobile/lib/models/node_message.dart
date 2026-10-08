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
}

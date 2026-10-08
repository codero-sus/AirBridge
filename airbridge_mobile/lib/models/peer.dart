class Peer {
  const Peer({
    required this.deviceId,
    required this.deviceName,
    required this.host,
    required this.httpPort,
    required this.udpPort,
    required this.lastSeen,
    required this.role,
    required this.masterId,
  });

  final String deviceId;
  final String deviceName;
  final String host;
  final int httpPort;
  final int udpPort;
  final DateTime lastSeen;
  final String role;
  final String masterId;

  Peer copyWith({DateTime? lastSeen, String? role, String? masterId}) => Peer(
        deviceId: deviceId,
        deviceName: deviceName,
        host: host,
        httpPort: httpPort,
        udpPort: udpPort,
        lastSeen: lastSeen ?? this.lastSeen,
        role: role ?? this.role,
        masterId: masterId ?? this.masterId,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'deviceId': deviceId,
        'deviceName': deviceName,
        'host': host,
        'httpPort': httpPort,
        'udpPort': udpPort,
        'lastSeen': lastSeen.toUtc().toIso8601String(),
        'role': role,
        'masterId': masterId,
      };
}

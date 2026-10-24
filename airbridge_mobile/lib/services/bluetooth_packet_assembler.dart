import 'dart:typed_data';

/// Reassembles the version-1 Airbridge BLE fragments used by every platform.
///
/// The assembler is transport-agnostic so both the universal_ble central path
/// and the Linux BlueZ GATT peripheral path use exactly the same framing and
/// resource limits.
class BluetoothPacketAssembler {
  static const int fragmentHeaderBytes = 8;
  static const int defaultMaxPacketBytes = 128 * 1024;

  BluetoothPacketAssembler({
    this.maxPacketBytes = defaultMaxPacketBytes,
    this.maxAssembliesPerPeer = 4,
    this.maxFragmentCount = 12000,
    this.fragmentLifetime = const Duration(seconds: 30),
  })  : assert(maxPacketBytes > 0),
        assert(maxAssembliesPerPeer > 0),
        assert(maxFragmentCount > 0),
        assert(fragmentLifetime > Duration.zero);

  final int maxPacketBytes;
  final int maxAssembliesPerPeer;
  final int maxFragmentCount;
  final Duration fragmentLifetime;

  final Map<(String, int), _PacketAssembly> _assemblies =
      <(String, int), _PacketAssembly>{};

  int get pendingAssemblyCount => _assemblies.length;

  /// Adds one ATT value. Returns a complete packet when its final fragment
  /// arrives; invalid, duplicate, or incomplete fragments return `null`.
  Uint8List? addFragment(
    String peerId,
    Uint8List value, {
    DateTime? now,
  }) {
    if (peerId.isEmpty || value.length < fragmentHeaderBytes ||
        value[0] != 0x41 || value[1] != 0x42) {
      return null;
    }

    final header = ByteData.sublistView(value);
    final packetId = header.getUint16(2, Endian.big);
    final index = header.getUint16(4, Endian.big);
    final count = header.getUint16(6, Endian.big);
    if (count == 0 || count > maxFragmentCount || index >= count) return null;

    final receivedAt = now ?? DateTime.now();
    _prune(receivedAt);
    final key = (peerId, packetId);
    var assembly = _assemblies[key];
    if (assembly == null) {
      final peerAssemblyCount =
          _assemblies.keys.where((entry) => entry.$1 == peerId).length;
      if (peerAssemblyCount >= maxAssembliesPerPeer) return null;
      assembly = _PacketAssembly(count, receivedAt);
      _assemblies[key] = assembly;
    }
    if (assembly.count != count) {
      _assemblies.remove(key);
      return null;
    }

    if (!assembly.fragments.containsKey(index)) {
      final fragment = Uint8List.fromList(value.sublist(fragmentHeaderBytes));
      assembly.fragments[index] = fragment;
      assembly.receivedBytes += fragment.length;
    }
    if (assembly.receivedBytes > maxPacketBytes) {
      _assemblies.remove(key);
      return null;
    }
    if (assembly.fragments.length != count) return null;

    final builder = BytesBuilder(copy: false);
    for (var fragmentIndex = 0; fragmentIndex < count; fragmentIndex++) {
      final fragment = assembly.fragments[fragmentIndex];
      if (fragment == null) return null;
      builder.add(fragment);
    }
    _assemblies.remove(key);
    return builder.takeBytes();
  }

  void clear() => _assemblies.clear();

  void _prune(DateTime now) {
    final cutoff = now.subtract(fragmentLifetime);
    _assemblies.removeWhere((_, assembly) => assembly.createdAt.isBefore(cutoff));
  }
}

class _PacketAssembly {
  _PacketAssembly(this.count, this.createdAt);

  final int count;
  final DateTime createdAt;
  final Map<int, Uint8List> fragments = <int, Uint8List>{};
  int receivedBytes = 0;
}

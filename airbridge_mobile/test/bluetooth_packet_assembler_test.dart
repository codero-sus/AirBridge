import 'dart:typed_data';

import 'package:airbridge_mobile/services/bluetooth_packet_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BluetoothPacketAssembler', () {
    test('reassembles out-of-order fragments and ignores duplicates', () {
      final assembler = BluetoothPacketAssembler();
      final packet = Uint8List.fromList(List<int>.generate(53, (i) => i));
      final fragments = _fragment(packet, packetId: 0x1234, payloadLength: 18);

      expect(assembler.addFragment('peer-a', fragments[2]), isNull);
      expect(assembler.addFragment('peer-a', fragments[2]), isNull);
      expect(assembler.pendingAssemblyCount, 1);
      expect(assembler.addFragment('peer-a', fragments[0]), isNull);
      final complete = assembler.addFragment('peer-a', fragments[1]);

      expect(complete, packet);
      expect(assembler.pendingAssemblyCount, 0);
    });

    test('keeps same packet IDs isolated between peers', () {
      final assembler = BluetoothPacketAssembler();
      final firstPacket = Uint8List.fromList(<int>[1, 2, 3]);
      final secondPacket = Uint8List.fromList(<int>[7, 8, 9]);
      final firstFragments =
          _fragment(firstPacket, packetId: 9, payloadLength: 2);
      final secondFragments =
          _fragment(secondPacket, packetId: 9, payloadLength: 2);

      expect(assembler.addFragment('peer-a', firstFragments[0]), isNull);
      expect(assembler.addFragment('peer-b', secondFragments[0]), isNull);
      expect(assembler.addFragment('peer-a', firstFragments[1]), firstPacket);
      expect(assembler.addFragment('peer-b', secondFragments[1]), secondPacket);
      expect(assembler.pendingAssemblyCount, 0);
    });

    test('rejects malformed headers and discards inconsistent fragment counts', () {
      final assembler = BluetoothPacketAssembler();
      expect(assembler.addFragment('peer-a', Uint8List(7)), isNull);
      expect(assembler.addFragment('peer-a', _frame(0x00, 1, 0, <int>[1])), isNull);
      expect(assembler.addFragment('peer-a', _frame(0x01, 1, 1, <int>[1])), isNull);

      expect(
        assembler.addFragment('peer-a', _frame(7, 0, 2, <int>[1])),
        isNull,
      );
      expect(
        assembler.addFragment('peer-a', _frame(7, 1, 3, <int>[2])),
        isNull,
      );
      expect(assembler.pendingAssemblyCount, 0);
    });

    test('enforces per-peer assembly and packet-size limits and expires old work', () {
      final assembler = BluetoothPacketAssembler(
        maxPacketBytes: 2,
        maxAssembliesPerPeer: 1,
        fragmentLifetime: const Duration(seconds: 5),
      );
      final now = DateTime.utc(2026, 10, 24);

      expect(
        assembler.addFragment(
          'peer-a',
          _frame(1, 0, 2, <int>[1]),
          now: now,
        ),
        isNull,
      );
      expect(
        assembler.addFragment(
          'peer-a',
          _frame(2, 0, 2, <int>[2]),
          now: now,
        ),
        isNull,
      );
      expect(assembler.pendingAssemblyCount, 1);

      expect(
        assembler.addFragment(
          'peer-a',
          _frame(1, 1, 2, <int>[2, 3]),
          now: now.add(const Duration(seconds: 1)),
        ),
        isNull,
      );
      expect(assembler.pendingAssemblyCount, 0);

      expect(
        assembler.addFragment(
          'peer-a',
          _frame(3, 0, 2, <int>[4]),
          now: now,
        ),
        isNull,
      );
      expect(
        assembler.addFragment(
          'peer-b',
          _frame(4, 0, 2, <int>[5]),
          now: now.add(const Duration(seconds: 6)),
        ),
        isNull,
      );
      expect(assembler.pendingAssemblyCount, 1);
      assembler.clear();
      expect(assembler.pendingAssemblyCount, 0);
    });
  });
}

List<Uint8List> _fragment(
  Uint8List packet, {
  required int packetId,
  required int payloadLength,
}) {
  final count = (packet.length + payloadLength - 1) ~/ payloadLength;
  return List<Uint8List>.generate(count, (index) {
    final start = index * payloadLength;
    final end = (start + payloadLength).clamp(0, packet.length).toInt();
    return _frame(
      packetId,
      index,
      count,
      packet.sublist(start, end),
    );
  });
}

Uint8List _frame(int packetId, int index, int count, List<int> payload) {
  final frame = Uint8List(
    BluetoothPacketAssembler.fragmentHeaderBytes + payload.length,
  );
  frame[0] = 0x41;
  frame[1] = 0x42;
  final header = ByteData.sublistView(frame);
  header.setUint16(2, packetId, Endian.big);
  header.setUint16(4, index, Endian.big);
  header.setUint16(6, count, Endian.big);
  frame.setRange(BluetoothPacketAssembler.fragmentHeaderBytes, frame.length, payload);
  return frame;
}

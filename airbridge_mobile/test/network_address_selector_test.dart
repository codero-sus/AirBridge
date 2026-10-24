import 'package:airbridge_mobile/services/network_address_selector.dart';
import 'package:flutter_test/flutter_test.dart';

NetworkAddressCandidate _candidate(String interfaceName, String address) =>
    NetworkAddressCandidate(
      interfaceName: interfaceName,
      address: address,
    );

void main() {
  test(
    'prefers Wi-Fi over Ethernet, cellular, VPN, and virtual interfaces',
    () {
      final selected = selectPreferredIpv4Address(<NetworkAddressCandidate>[
        _candidate('rmnet_data0', '10.127.9.76'),
        _candidate('vEthernet (Default Switch)', '172.20.0.1'),
        _candidate('Ethernet', '192.168.1.20'),
        _candidate('wlan0', '192.168.1.42'),
        _candidate('tun0', '10.8.0.2'),
      ]);

      expect(selected, '192.168.1.42');
    },
  );

  test('recognizes common Wi-Fi interface names across platforms', () {
    for (final interfaceName in <String>['wlp2s0', 'wlo1', 'Wi-Fi']) {
      final selected = selectPreferredIpv4Address(<NetworkAddressCandidate>[
        _candidate('Ethernet', '192.168.1.20'),
        _candidate(interfaceName, '192.168.1.42'),
      ]);

      expect(selected, '192.168.1.42', reason: interfaceName);
    }
  });

  test('prefers Ethernet over VPN and unknown interfaces', () {
    final selected = selectPreferredIpv4Address(<NetworkAddressCandidate>[
      _candidate('vpn0', '10.8.0.2'),
      _candidate('enp3s0', '192.168.1.20'),
      _candidate('some-interface', '172.16.0.5'),
    ]);

    expect(selected, '192.168.1.20');
  });

  test('uses a valid unknown interface when no named LAN interface exists', () {
    final selected = selectPreferredIpv4Address(<NetworkAddressCandidate>[
      _candidate('vpn0', '10.8.0.2'),
      _candidate('usb0', '192.168.42.10'),
    ]);

    expect(selected, '192.168.42.10');
  });

  test('prefers an unclassified interface over VPN and virtual adapters', () {
    final selected = selectPreferredIpv4Address(<NetworkAddressCandidate>[
      _candidate('vEthernet (Default Switch)', '172.20.0.1'),
      _candidate('tun0', '10.8.0.2'),
      _candidate('usb0', '192.168.42.10'),
    ]);

    expect(selected, '192.168.42.10');
  });

  test('does not advertise a cellular-only interface', () {
    final selected = selectPreferredIpv4Address(<NetworkAddressCandidate>[
      _candidate('rmnet_data0', '10.127.9.76'),
      _candidate('wwan0', '100.72.4.12'),
    ]);

    expect(selected, isNull);
  });

  test('ignores invalid, loopback, link-local, and non-unicast addresses', () {
    final selected = selectPreferredIpv4Address(<NetworkAddressCandidate>[
      _candidate('wlan0', 'not-an-ip'),
      _candidate('wlan0', '::1'),
      _candidate('wlan0', '0.0.0.0'),
      _candidate('wlan0', '127.0.0.1'),
      _candidate('wlan0', '169.254.10.2'),
      _candidate('wlan0', '224.0.0.1'),
      _candidate('wlan0', '240.0.0.1'),
    ]);

    expect(selected, isNull);
  });

  test('orders same-priority addresses deterministically', () {
    final selected = selectPreferredIpv4Address(<NetworkAddressCandidate>[
      _candidate('wlan0', '192.168.1.50'),
      _candidate('wlan0', '192.168.1.20'),
    ]);

    expect(selected, '192.168.1.20');
  });
}

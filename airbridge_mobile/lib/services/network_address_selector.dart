import 'dart:io';

/// An IPv4 address advertised by a local network interface.
class NetworkAddressCandidate {
  const NetworkAddressCandidate({
    required this.interfaceName,
    required this.address,
  });

  final String interfaceName;
  final String address;
}

/// Selects a likely local-network address rather than cellular, VPN, or
/// virtual-adapter addresses when several IPv4 interfaces are available.
String? selectPreferredIpv4Address(
  Iterable<NetworkAddressCandidate> candidates,
) {
  final usable = candidates
      .where(_isUsableIpv4)
      .where((candidate) => !_isCellularInterface(candidate.interfaceName))
      .toList();
  usable.sort((left, right) {
    final priorityDifference =
        _interfacePriority(left.interfaceName) -
        _interfacePriority(right.interfaceName);
    if (priorityDifference != 0) return priorityDifference;
    return left.address.compareTo(right.address);
  });
  return usable.isEmpty ? null : usable.first.address;
}

bool _isUsableIpv4(NetworkAddressCandidate candidate) {
  final parsed = InternetAddress.tryParse(candidate.address);
  if (parsed == null || parsed.type != InternetAddressType.IPv4) return false;
  final octets = parsed.rawAddress;
  if (octets.length != 4) return false;
  final first = octets[0];
  final second = octets[1];
  return first != 0 &&
      first != 127 &&
      !(first == 169 && second == 254) &&
      first < 224;
}

bool _isCellularInterface(String interfaceName) =>
    _hasAny(interfaceName.toLowerCase(), <String>[
      'rmnet',
      'wwan',
      'cell',
      'pdp',
      'ccmni',
      'mobile',
    ]);

int _interfacePriority(String interfaceName) {
  final name = interfaceName.toLowerCase();
  if (_hasAny(name, <String>[
    'vpn',
    'tun',
    'utun',
    'tap',
    'wireguard',
    'tailscale',
    'zerotier',
    'hamachi',
    'openvpn',
    'docker',
    'podman',
    'veth',
    'vmnet',
    'vbox',
    'vethernet',
    'hyper-v',
    'virbr',
    'virtual',
    'loopback',
    'bluetooth',
    'wsl',
  ])) {
    return 4;
  }
  if (_hasAny(name, <String>[
        'wifi',
        'wi-fi',
        'wlan',
        'wireless',
        'swlan',
        'hotspot',
      ]) ||
      name.startsWith('wl') ||
      RegExp(r'^ap\d+').hasMatch(name)) {
    return 0;
  }
  if (_hasAny(name, <String>['ethernet', 'eth', 'enp', 'ens']) ||
      RegExp(r'^en\d+').hasMatch(name)) {
    return 1;
  }
  return 2;
}

bool _hasAny(String value, List<String> fragments) =>
    fragments.any(value.contains);

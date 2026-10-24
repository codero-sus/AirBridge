import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:universal_ble/universal_ble.dart' show BleDevice;

import '../models/node_message.dart';
import '../services/file_transfer_store.dart';
import '../models/peer.dart';
import '../services/node_controller.dart';
import 'pairing_dialog.dart';

const Color _background = Color(0xFF0B0F19);
const Color _panel = Color(0xDD111827);
const Color _border = Color(0xFF253247);
const Color _mint = Color(0xFF63E6BE);
const Color _muted = Color(0xFF92A0B8);

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.controller});

  final NodeController controller;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

enum _DashboardSection {
  overview,
  messages,
  peers,
  files,
  bluetooth,
  activity,
  troubleshooting,
  docs,
  settings,
}

extension _DashboardSectionDetails on _DashboardSection {
  String get label => switch (this) {
        _DashboardSection.overview => 'Overview',
        _DashboardSection.messages => 'Messages',
        _DashboardSection.peers => 'Mesh peers',
        _DashboardSection.files => 'Files',
        _DashboardSection.bluetooth => 'Bluetooth',
        _DashboardSection.activity => 'Activity',
        _DashboardSection.troubleshooting => 'Troubleshooting',
        _DashboardSection.docs => 'Docs',
        _DashboardSection.settings => 'Settings',
      };

  String get description => switch (this) {
        _DashboardSection.overview => 'A quick view of your local mesh.',
        _DashboardSection.messages => 'Send payloads and review encrypted message traffic.',
        _DashboardSection.peers => 'Discover, pair, and monitor nearby devices.',
        _DashboardSection.files => 'Send and receive encrypted files on your local network.',
        _DashboardSection.bluetooth => 'Pair and transfer data over nearby Bluetooth LE.',
        _DashboardSection.activity => 'Inspect recent node and network events.',
        _DashboardSection.troubleshooting => 'Run checks and find fixes for connection issues.',
        _DashboardSection.docs => 'Learn how to pair, transfer, and secure your devices.',
        _DashboardSection.settings => 'Manage your device, file, and Bluetooth preferences.',
      };

  IconData get icon => switch (this) {
        _DashboardSection.overview => Icons.grid_view_rounded,
        _DashboardSection.messages => Icons.forum_outlined,
        _DashboardSection.peers => Icons.hub_outlined,
        _DashboardSection.files => Icons.folder_open_rounded,
        _DashboardSection.bluetooth => Icons.bluetooth_rounded,
        _DashboardSection.activity => Icons.receipt_long_outlined,
        _DashboardSection.troubleshooting => Icons.build_circle_outlined,
        _DashboardSection.docs => Icons.menu_book_outlined,
        _DashboardSection.settings => Icons.settings_outlined,
      };
}

class _DashboardPageState extends State<DashboardPage> {
  final TextEditingController _payloadController = TextEditingController();
  bool _sending = false;
  _DashboardSection _section = _DashboardSection.overview;

  @override
  void dispose() {
    _payloadController.dispose();
    super.dispose();
  }

  Future<void> _sendPayload() async {
    final raw = _payloadController.text.trim();
    if (raw.isEmpty || _sending) return;
    Object? payload;
    try {
      payload = jsonDecode(raw);
    } on FormatException {
      payload = raw;
    }

    setState(() => _sending = true);
    try {
      await widget.controller.sendPayload(payload);
      _payloadController.clear();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Dispatch failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openPairing({required bool closeDrawer}) async {
    if (!widget.controller.isRunning) return;
    if (closeDrawer) {
      await Navigator.of(context).maybePop();
      if (!mounted) return;
    }
    await showPairingDialog(context, widget.controller);
  }

  void _selectSection(_DashboardSection section, {required bool closeDrawer}) {
    setState(() => _section = section);
    if (closeDrawer) Navigator.of(context).pop();
  }

  Widget _buildSection({required bool wide}) => switch (_section) {
        _DashboardSection.overview => _OverviewSection(
            controller: widget.controller,
            onPair: () => unawaited(_openPairing(closeDrawer: false)),
            onOpenMessages: () => _selectSection(_DashboardSection.messages,
                closeDrawer: false),
            onOpenPeers: () =>
                _selectSection(_DashboardSection.peers, closeDrawer: false),
          ),
        _DashboardSection.messages => _MessagesSection(
            controller: widget.controller,
            textController: _payloadController,
            sending: _sending,
            onSend: _sendPayload,
            wide: wide,
          ),
        _DashboardSection.peers => _PeersSection(
            controller: widget.controller,
            onPair: () => unawaited(_openPairing(closeDrawer: false)),
          ),
        _DashboardSection.files => _FilesSection(
            controller: widget.controller,
          ),
        _DashboardSection.bluetooth => _BluetoothSection(
            controller: widget.controller,
          ),
        _DashboardSection.activity => _ActivitySection(
            controller: widget.controller,
          ),
        _DashboardSection.troubleshooting => _TroubleshootingSection(
            controller: widget.controller,
            onPair: () => unawaited(_openPairing(closeDrawer: false)),
          ),
        _DashboardSection.docs => const _DocsSection(),
        _DashboardSection.settings => _SettingsSection(
            controller: widget.controller,
          ),
      };

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final wide = MediaQuery.sizeOf(context).width >= 1080;
          return Scaffold(
            backgroundColor: _background,
            drawer: wide
                ? null
                : Drawer(
                    width: 286,
                    backgroundColor: const Color(0xFF0E1522),
                    child: SafeArea(
                      child: _Sidebar(
                        controller: widget.controller,
                        selectedSection: _section,
                        onSelect: (section) => _selectSection(
                          section,
                          closeDrawer: true,
                        ),
                        onPair: () => unawaited(
                          _openPairing(closeDrawer: true),
                        ),
                      ),
                    ),
                  ),
            appBar: wide
                ? null
                : AppBar(
                    backgroundColor: _background,
                    foregroundColor: const Color(0xFFE8EDF5),
                    elevation: 0,
                    leading: Builder(
                      builder: (drawerContext) => IconButton(
                        tooltip: 'Open navigation',
                        onPressed: () =>
                            Scaffold.of(drawerContext).openDrawer(),
                        icon: const Icon(Icons.menu_rounded),
                      ),
                    ),
                    titleSpacing: 0,
                    title: Row(
                      children: <Widget>[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.asset(
                            'assets/airbridge_logo.png',
                            width: 31,
                            height: 31,
                            fit: BoxFit.cover,
                            semanticLabel: 'Airbridge logo',
                          ),
                        ),
                        const SizedBox(width: 9),
                        const Text(
                          'AIRBRIDGE',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ],
                    ),
                    actions: <Widget>[
                      IconButton(
                        tooltip: 'Pair a device with QR',
                        onPressed: widget.controller.isRunning
                            ? () => unawaited(
                                  _openPairing(closeDrawer: false),
                                )
                            : null,
                        color: _mint,
                        icon: const Icon(Icons.qr_code_2_rounded),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ),
            body: SafeArea(
              top: wide,
              child: Row(
                children: <Widget>[
                  if (wide)
                    _Sidebar(
                      width: 252,
                      controller: widget.controller,
                      selectedSection: _section,
                      onSelect: (section) => _selectSection(
                        section,
                        closeDrawer: false,
                      ),
                      onPair: () => unawaited(
                        _openPairing(closeDrawer: false),
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        wide ? 26 : 15,
                        wide ? 18 : 10,
                        wide ? 26 : 15,
                        wide ? 22 : 15,
                      ),
                      child: Column(
                        children: <Widget>[
                          _NodeHeader(controller: widget.controller),
                          const SizedBox(height: 16),
                          Expanded(child: _buildSection(wide: wide)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.controller,
    required this.selectedSection,
    required this.onSelect,
    required this.onPair,
    this.width,
  });

  final NodeController controller;
  final _DashboardSection selectedSection;
  final ValueChanged<_DashboardSection> onSelect;
  final VoidCallback onPair;
  final double? width;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        padding: const EdgeInsets.fromLTRB(14, 20, 14, 16),
        decoration: const BoxDecoration(
          color: Color(0xFF0E1522),
          border: Border(right: BorderSide(color: _border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
              child: Row(
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Image.asset(
                      'assets/airbridge_logo.png',
                      width: 39,
                      height: 39,
                      fit: BoxFit.cover,
                      semanticLabel: 'Airbridge logo',
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'AIRBRIDGE',
                          style: TextStyle(
                            color: Color(0xFFE9F0F7),
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.45,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'LOCAL MESH',
                          style: TextStyle(
                            color: _muted,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 0, 10, 9),
              child: Text(
                'WORKSPACE',
                style: TextStyle(
                  color: Color(0xFF65738A),
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.35,
                ),
              ),
            ),
            for (final section in _DashboardSection.values)
              _SidebarDestination(
                section: section,
                selected: section == selectedSection,
                onTap: () => onSelect(section),
              ),
            const Spacer(),
            FilledButton.icon(
              onPressed: controller.isRunning ? onPair : null,
              style: FilledButton.styleFrom(
                backgroundColor: _mint,
                foregroundColor: const Color(0xFF07120F),
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
              icon: const Icon(Icons.qr_code_2_rounded, size: 19),
              label: const Text(
                'Pair a device',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 13),
            _SidebarNodeStatus(controller: controller),
          ],
        ),
      );
}

class _SidebarDestination extends StatelessWidget {
  const _SidebarDestination({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final _DashboardSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Semantics(
          button: true,
          selected: selected,
          label: section.label,
          child: Tooltip(
            message: section.description,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(12),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  height: 46,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: selected ? const Color(0x1F63E6BE) : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected
                          ? const Color(0x4D63E6BE)
                          : Colors.transparent,
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        section.icon,
                        size: 18,
                        color: selected ? _mint : const Color(0xFF8390A5),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          section.label,
                          style: TextStyle(
                            color: selected
                                ? const Color(0xFFE7F7F1)
                                : const Color(0xFFB7C1D0),
                            fontSize: 12,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ),
                      if (selected)
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: _mint,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class _SidebarNodeStatus extends StatelessWidget {
  const _SidebarNodeStatus({required this.controller});

  final NodeController controller;

  @override
  Widget build(BuildContext context) {
    final online = controller.isRunning;
    final color = online ? _mint : const Color(0xFFFFC977);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF111B2A),
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  online ? 'Node online' : 'Node ${controller.lifecycle}',
                  style: const TextStyle(
                    color: Color(0xFFE5EAF3),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${controller.connectedPeerCount} linked  ·  ${controller.peers.length} discovered',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 9),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PageHeading extends StatelessWidget {
  const _PageHeading({
    required this.icon,
    required this.title,
    required this.detail,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
        children: <Widget>[
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0x1F63E6BE),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: _mint, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFFE8EDF5),
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.35,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.detail,
    required this.accent,
    required this.iconBackground,
  });

  final IconData icon;
  final String label;
  final String value;
  final String detail;
  final Color accent;
  final Color iconBackground;

  @override
  Widget build(BuildContext context) => _GlassPanel(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: <Widget>[
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconBackground,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: accent, size: 19),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .8,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFE8EDF5),
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _muted, fontSize: 9),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

class _OverviewSection extends StatelessWidget {
  const _OverviewSection({
    required this.controller,
    required this.onPair,
    required this.onOpenMessages,
    required this.onOpenPeers,
  });

  final NodeController controller;
  final VoidCallback onPair;
  final VoidCallback onOpenMessages;
  final VoidCallback onOpenPeers;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 820;
    final latestMessages = controller.messages.reversed.take(3).toList();
    final metrics = <Widget>[
      _MetricCard(
        icon: controller.isRunning ? Icons.wifi_tethering_rounded : Icons.power_settings_new_rounded,
        label: 'Node status',
        value: controller.lifecycle.toUpperCase(),
        detail: '${controller.localAddress}:${controller.config.httpPort}',
        accent: controller.isRunning ? _mint : const Color(0xFFFFC977),
        iconBackground: controller.isRunning
            ? const Color(0x1F63E6BE)
            : const Color(0x1FFFC977),
      ),
      _MetricCard(
        icon: Icons.hub_outlined,
        label: 'Mesh peers',
        value: '${controller.peers.length}',
        detail: '${controller.connectedPeerCount} linked now',
        accent: const Color(0xFF8CA8FF),
        iconBackground: const Color(0x1F8CA8FF),
      ),
      _MetricCard(
        icon: Icons.swap_horiz_rounded,
        label: 'Messages',
        value: '${controller.messages.length}',
        detail: 'retained on this device',
        accent: const Color(0xFFFFC977),
        iconBackground: const Color(0x1FFFC977),
      ),
      _MetricCard(
        icon: Icons.verified_user_outlined,
        label: 'Trusted devices',
        value: '${controller.trustedPeers.length}',
        detail: 'per-peer encrypted links',
        accent: const Color(0xFFC5A5FF),
        iconBackground: const Color(0x1FC5A5FF),
      ),
    ];

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: <Widget>[
        _PageHeading(
          icon: Icons.grid_view_rounded,
          title: 'Overview',
          detail: 'Your local mesh at a glance. Choose a section from the sidebar to get started.',
        ),
        const SizedBox(height: 17),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 960
                ? 4
                : constraints.maxWidth >= 680
                    ? 3
                    : 2;
            final aspectRatio = switch (columns) {
              4 => 2.1,
              3 => 1.85,
              _ => 1.55,
            };
            return GridView.count(
              crossAxisCount: columns,
              crossAxisSpacing: 11,
              mainAxisSpacing: 11,
              childAspectRatio: aspectRatio,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: metrics,
            );
          },
        ),
        const SizedBox(height: 15),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: _QuickStartPanel(
                  canPair: controller.isRunning,
                  onPair: onPair,
                  onOpenPeers: onOpenPeers,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: _RecentMessagesPanel(
                  messages: latestMessages,
                  totalMessages: controller.messages.length,
                  onOpenMessages: onOpenMessages,
                ),
              ),
            ],
          )
        else ...<Widget>[
          _QuickStartPanel(
            canPair: controller.isRunning,
            onPair: onPair,
            onOpenPeers: onOpenPeers,
          ),
          const SizedBox(height: 13),
          _RecentMessagesPanel(
            messages: latestMessages,
            totalMessages: controller.messages.length,
            onOpenMessages: onOpenMessages,
          ),
        ],
      ],
    );
  }
}

class _QuickStartPanel extends StatelessWidget {
  const _QuickStartPanel({
    required this.canPair,
    required this.onPair,
    required this.onOpenPeers,
  });

  final bool canPair;
  final VoidCallback onPair;
  final VoidCallback onOpenPeers;

  @override
  Widget build(BuildContext context) => _GlassPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const _PanelHeading(
              icon: Icons.bolt_rounded,
              title: 'Get connected',
              detail: 'Bring another device onto this mesh.',
            ),
            const SizedBox(height: 13),
            const Text(
              'Pair with a one-time QR invitation. Nearby devices are discovered automatically on your local network.',
              style: TextStyle(color: Color(0xFFB3BED0), fontSize: 11, height: 1.5),
            ),
            const SizedBox(height: 13),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: canPair ? onPair : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: _mint,
                    foregroundColor: const Color(0xFF07120F),
                  ),
                  icon: const Icon(Icons.qr_code_2_rounded, size: 17),
                  label: const Text('Pair a device'),
                ),
                OutlinedButton.icon(
                  onPressed: onOpenPeers,
                  icon: const Icon(Icons.hub_outlined, size: 17),
                  label: const Text('Browse peers'),
                ),
              ],
            ),
          ],
        ),
      );
}

class _RecentMessagesPanel extends StatelessWidget {
  const _RecentMessagesPanel({
    required this.messages,
    required this.totalMessages,
    required this.onOpenMessages,
  });

  final List<NodeMessage> messages;
  final int totalMessages;
  final VoidCallback onOpenMessages;

  @override
  Widget build(BuildContext context) => _GlassPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _PanelHeading(
              icon: Icons.forum_outlined,
              title: 'Recent traffic',
              detail: '$totalMessages messages on this device',
              trailing: TextButton(
                onPressed: onOpenMessages,
                child: const Text('View all'),
              ),
            ),
            const SizedBox(height: 10),
            if (messages.isEmpty)
              const _EmptyState(
                icon: Icons.mark_chat_unread_outlined,
                title: 'No messages yet',
                detail: 'Broadcast a payload or wait for a peer.',
              )
            else
              ...messages.map(
                (message) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _MessageTile(message: message),
                ),
              ),
          ],
        ),
      );
}

class _MessagesSection extends StatelessWidget {
  const _MessagesSection({
    required this.controller,
    required this.textController,
    required this.sending,
    required this.onSend,
    required this.wide,
  });

  final NodeController controller;
  final TextEditingController textController;
  final bool sending;
  final VoidCallback onSend;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final messageHeight = (MediaQuery.sizeOf(context).height - 300)
        .clamp(330.0, 620.0)
        .toDouble();
    final terminal = _TerminalPanel(
      controller: controller,
      textController: textController,
      sending: sending,
      onSend: onSend,
    );
    return Column(
      children: <Widget>[
        const _PageHeading(
          icon: Icons.forum_outlined,
          title: 'Messages',
          detail: 'Broadcast payloads and search the message history.',
        ),
        const SizedBox(height: 15),
        Expanded(
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 360,
                      child: SingleChildScrollView(child: terminal),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: SingleChildScrollView(
                        child: _MessagePanel(
                          controller: controller,
                          height: messageHeight,
                        ),
                      ),
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 8),
                  children: <Widget>[
                    terminal,
                    const SizedBox(height: 13),
                    _MessagePanel(controller: controller),
                  ],
                ),
        ),
      ],
    );
  }
}

class _PeersSection extends StatelessWidget {
  const _PeersSection({required this.controller, required this.onPair});

  final NodeController controller;
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.only(bottom: 8),
        children: <Widget>[
          _PageHeading(
            icon: Icons.hub_outlined,
            title: 'Mesh peers',
            detail: 'Devices discovered on this subnet. Pairing establishes trust.',
            trailing: FilledButton.tonalIcon(
              onPressed: controller.isRunning ? onPair : null,
              icon: const Icon(Icons.qr_code_2_rounded, size: 17),
              label: const Text('Pair'),
            ),
          ),
          const SizedBox(height: 16),
          _PeerPanel(controller: controller),
        ],
      );
}

class _ActivitySection extends StatelessWidget {
  const _ActivitySection({required this.controller});

  final NodeController controller;

  @override
  Widget build(BuildContext context) => Column(
        children: <Widget>[
          const _PageHeading(
            icon: Icons.receipt_long_outlined,
            title: 'Activity',
            detail: 'Recent startup, discovery, pairing, and delivery events.',
          ),
          const SizedBox(height: 15),
          Expanded(child: _LogPanel(controller: controller)),
        ],
      );
}

class _FilesSection extends StatefulWidget {
  const _FilesSection({required this.controller});

  final NodeController controller;

  @override
  State<_FilesSection> createState() => _FilesSectionState();
}

class _FilesSectionState extends State<_FilesSection> {
  String? _selectedPeerId;
  bool _sending = false;
  double _progress = 0;

  Future<void> _sendFile() async {
    final peerId = _selectedPeerId;
    if (peerId == null || _sending) return;
    _PickedLocalFile? picked;
    try {
      picked = await _pickLocalFile();
      if (picked == null) return;
      setState(() {
        _sending = true;
        _progress = 0;
      });
      await widget.controller.sendFileToPeer(
        path: picked.path,
        peerId: peerId,
        onProgress: (sent, total) {
          if (mounted) {
            setState(() => _progress = total == 0 ? 1 : sent / total);
          }
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Encrypted file transfer completed.')),
        );
      }
    } on Object catch (error) {
      if (mounted) _showError(context, 'File transfer failed: $error');
    } finally {
      await picked?.cleanup();
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _saveFile(FileTransferRecord record) async {
    try {
      if (record.sizeBytes > 256 * 1024 * 1024) {
        throw const FileTransferException(
          'This file is too large for the in-app Save As dialog. Use the received-files folder shown below.',
        );
      }
      final bytes = await File(record.path).readAsBytes();
      final result = await FilePicker.saveFile(
        dialogTitle: 'Save received file',
        fileName: record.fileName,
        bytes: bytes,
      );
      if (!mounted || result == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${record.fileName}.')),
      );
    } on Object catch (error) {
      if (mounted) _showError(context, 'Could not export file: $error');
    }
  }

  Future<void> _copyPath(FileTransferRecord record) async {
    await Clipboard.setData(ClipboardData(text: record.path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied the local path for ${record.fileName}.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trustedIds = widget.controller.trustedPeers
        .map((peer) => peer.deviceId)
        .toSet();
    final peers = widget.controller.peers
        .where((peer) => trustedIds.contains(peer.deviceId) || widget.controller.hasSharedSecret)
        .toList(growable: false);
    final selected = peers.any((peer) => peer.deviceId == _selectedPeerId)
        ? _selectedPeerId
        : (peers.isEmpty ? null : peers.first.deviceId);
    final files = widget.controller.receivedFiles;

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: <Widget>[
        const _PageHeading(
          icon: Icons.folder_open_rounded,
          title: 'File transfers',
          detail: 'Send encrypted files to a paired mesh peer and receive them directly on this device.',
        ),
        const SizedBox(height: 15),
        _GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _PanelHeading(
                icon: Icons.outgoing_mail,
                title: 'Send over your local network',
                detail: 'Files are encrypted in chunks and verified after delivery.',
              ),
              const SizedBox(height: 14),
              if (peers.isEmpty)
                const _EmptyState(
                  icon: Icons.devices_other_rounded,
                  title: 'No trusted peer available',
                  detail: 'Pair a device with its QR code first. Both devices must be on a reachable local network.',
                )
              else ...<Widget>[
                DropdownButtonFormField<String>(
                  initialValue: selected,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Send to paired device',
                    prefixIcon: Icon(Icons.devices_rounded),
                  ),
                  hint: const Text('Choose a trusted peer'),
                  items: peers
                      .map(
                        (peer) => DropdownMenuItem<String>(
                          value: peer.deviceId,
                          child: Text(
                            '${peer.deviceName}  ·  ${peer.host}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: _sending
                      ? null
                      : (value) => setState(() => _selectedPeerId = value),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: !widget.controller.isRunning || _sending || peers.isEmpty
                        ? null
                        : _sendFile,
                    icon: _sending
                        ? const SizedBox(
                            width: 17,
                            height: 17,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.upload_file_rounded),
                    label: Text(_sending ? 'Encrypting and sending…' : 'Choose a file and send'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _mint,
                      foregroundColor: const Color(0xFF07120F),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                if (_sending) ...<Widget>[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: _progress),
                  const SizedBox(height: 5),
                  Text('${(_progress * 100).round()}% sent',
                      style: const TextStyle(color: _muted, fontSize: 10)),
                ],
              ],
              const SizedBox(height: 12),
              const Text(
                'The receiver stores completed files in its private Airbridge data folder. Incoming files are accepted only from paired peers; SHA-256 is checked before a file appears here.',
                style: TextStyle(color: _muted, fontSize: 10, height: 1.45),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _PanelHeading(
                icon: Icons.download_done_rounded,
                title: 'Received files',
                detail: '${files.length} saved on this device',
                trailing: IconButton(
                  tooltip: 'Copy received-files folder path',
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: widget.controller.receivedFilesDirectory),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied received-files folder path.')),
                    );
                  },
                  icon: const Icon(Icons.folder_copy_outlined, size: 17),
                ),
              ),
              const SizedBox(height: 10),
              if (files.isEmpty)
                const _EmptyState(
                  icon: Icons.move_to_inbox_outlined,
                  title: 'No files received yet',
                  detail: 'New files appear after encryption and integrity checks complete.',
                )
              else
                ...files.map(
                  (record) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ReceivedFileTile(
                      record: record,
                      onSave: () => _saveFile(record),
                      onCopyPath: () => _copyPath(record),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ReceivedFileTile extends StatelessWidget {
  const _ReceivedFileTile({
    required this.record,
    required this.onSave,
    required this.onCopyPath,
  });

  final FileTransferRecord record;
  final VoidCallback onSave;
  final VoidCallback onCopyPath;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0xFF0C1220),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0x1F63E6BE),
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(Icons.insert_drive_file_outlined, color: _mint, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(record.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFFE5EAF3), fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(
                    '${_formatBytes(record.sizeBytes)}  ·  ${record.senderName}  ·  ${record.source}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _muted, fontSize: 10),
                  ),
                ],
              ),
            ),
            IconButton(tooltip: 'Save a copy', onPressed: onSave, icon: const Icon(Icons.save_alt_rounded, size: 17)),
            IconButton(tooltip: 'Copy file path', onPressed: onCopyPath, icon: const Icon(Icons.content_copy_rounded, size: 16)),
          ],
        ),
      );
}

class _BluetoothSection extends StatefulWidget {
  const _BluetoothSection({required this.controller});

  final NodeController controller;

  @override
  State<_BluetoothSection> createState() => _BluetoothSectionState();
}

class _BluetoothSectionState extends State<_BluetoothSection> {
  final TextEditingController _messageController = TextEditingController();
  bool _busy = false;
  double _progress = 0;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _enableOrScan() async {
    try {
      if (!widget.controller.bluetooth.isEnabled) {
        await widget.controller.updateSettings(bluetoothEnabled: true);
      }
      if (!widget.controller.bluetooth.isScanning) {
        await widget.controller.bluetooth.startScan();
      } else {
        await widget.controller.bluetooth.stopScan();
      }
    } on Object catch (error) {
      if (mounted) _showError(context, 'Bluetooth could not start: $error');
    }
  }

  Future<_PickedLocalFile?> _chooseFile() async {
    try {
      return await _pickLocalFile();
    } on Object catch (error) {
      if (mounted) _showError(context, 'Could not read the selected file: $error');
      return null;
    }
  }

  Future<void> _sendFile(BleDevice device) async {
    if (_busy) return;
    _PickedLocalFile? picked;
    try {
      picked = await _chooseFile();
      if (picked == null) return;
      setState(() {
        _busy = true;
        _progress = 0;
      });
      await widget.controller.sendBluetoothFile(
        device: device,
        path: picked.path,
        onProgress: (sent, total) {
          if (mounted) setState(() => _progress = total == 0 ? 1 : sent / total);
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Encrypted Bluetooth file sent.')),
        );
      }
    } on Object catch (error) {
      if (mounted) _showError(context, 'Bluetooth transfer failed: $error');
    } finally {
      await picked?.cleanup();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendMessage(BleDevice device) async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.controller.sendBluetoothMessage(device: device, payload: text);
      _messageController.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Encrypted Bluetooth message sent to ${device.name ?? 'device'}.')),
        );
      }
    } on Object catch (error) {
      if (mounted) _showError(context, 'Bluetooth message failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bluetooth = widget.controller.bluetooth;
    final devices = bluetooth.devices;
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: <Widget>[
        _PageHeading(
          icon: Icons.bluetooth_rounded,
          title: 'Bluetooth LE',
          detail: 'Send encrypted messages and files directly to a paired nearby device.',
          trailing: IconButton(
            tooltip: bluetooth.isEnabled ? 'Stop Bluetooth' : 'Enable Bluetooth',
            onPressed: _busy ? null : () => unawaited(_toggleBluetooth()),
            icon: Icon(bluetooth.isEnabled ? Icons.bluetooth_disabled_rounded : Icons.bluetooth_rounded),
          ),
        ),
        const SizedBox(height: 14),
        _GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: bluetooth.isAdvertising ? _mint : const Color(0xFFFFC977),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(bluetooth.status,
                        style: const TextStyle(color: Color(0xFFE5EAF3), fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : () => unawaited(_enableOrScan()),
                    icon: Icon(bluetooth.isScanning ? Icons.stop_rounded : Icons.radar_rounded, size: 17),
                    label: Text(bluetooth.isScanning ? 'Stop scan' : 'Scan'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                'Bluetooth uses BLE (not Bluetooth Classic). Pair with the QR code first; the six-digit code remains part of the trust flow. Wi-Fi is much faster for large files.',
                style: TextStyle(color: _muted, fontSize: 10, height: 1.45),
              ),
              if (_busy) ...<Widget>[
                const SizedBox(height: 12),
                LinearProgressIndicator(value: _progress == 0 ? null : _progress),
                const SizedBox(height: 5),
                Text('${(_progress * 100).round()}% sent',
                    style: const TextStyle(color: _muted, fontSize: 10)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 13),
        if (devices.isNotEmpty) ...<Widget>[
          _GlassPanel(
            child: TextField(
              controller: _messageController,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Bluetooth message',
                hintText: 'Type a message to send to a scanned device',
                prefixIcon: Icon(Icons.chat_bubble_outline_rounded),
              ),
              minLines: 1,
              maxLines: 3,
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (devices.isEmpty)
          const _GlassPanel(
            child: _EmptyState(
              icon: Icons.bluetooth_searching_rounded,
              title: 'No Airbridge Bluetooth devices found',
              detail: 'Enable Bluetooth on both devices, turn on Airbridge Bluetooth in Settings, then scan again.',
            ),
          )
        else ...devices.map(
          (device) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _BluetoothDeviceCard(
              device: device,
              busy: _busy,
              onSendFile: () => _sendFile(device),
              onSendMessage: () => _sendMessage(device),
            ),
          ),
        ),
        const SizedBox(height: 3),
        const _GlassPanel(
          child: Text(
            'Airbridge uses the same BLE GATT service and encrypted packet protocol across supported OSs. Linux uses BlueZ for its GATT peripheral; keep the Bluetooth service running and use a Bluetooth LE adapter. BlueStacks Bluetooth passthrough depends on the host and emulator configuration.',
            style: TextStyle(color: _muted, fontSize: 10, height: 1.5),
          ),
        ),
      ],
    );
  }

  Future<void> _toggleBluetooth() async {
    try {
      await widget.controller.updateSettings(
        bluetoothEnabled: !widget.controller.settings.bluetoothEnabled,
      );
    } on Object catch (error) {
      if (mounted) _showError(context, 'Bluetooth setting could not be changed: $error');
    }
  }
}

class _BluetoothDeviceCard extends StatelessWidget {
  const _BluetoothDeviceCard({
    required this.device,
    required this.busy,
    required this.onSendFile,
    required this.onSendMessage,
  });

  final BleDevice device;
  final bool busy;
  final VoidCallback onSendFile;
  final VoidCallback onSendMessage;

  @override
  Widget build(BuildContext context) => _GlassPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.bluetooth_connected_rounded, color: _mint, size: 19),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(device.name?.isNotEmpty == true ? device.name! : 'Airbridge BLE device',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFFE5EAF3), fontSize: 12, fontWeight: FontWeight.w700)),
                ),
                if (device.rssi != null)
                  Text('${device.rssi} dBm', style: const TextStyle(color: _muted, fontSize: 10)),
              ],
            ),
            const SizedBox(height: 5),
            Text('ID ${device.deviceId}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _muted, fontSize: 9)),
            const SizedBox(height: 11),
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    'Send a message or file over an encrypted BLE link.',
                    style: TextStyle(color: _muted, fontSize: 10),
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Send encrypted message',
                  onPressed: busy ? null : onSendMessage,
                  icon: const Icon(Icons.send_rounded, size: 17),
                ),
                const SizedBox(width: 5),
                FilledButton.tonalIcon(
                  onPressed: busy ? null : onSendFile,
                  icon: const Icon(Icons.upload_file_rounded, size: 16),
                  label: const Text('File'),
                ),
              ],
            ),
          ],
        ),
      );
}

class _TroubleshootingSection extends StatelessWidget {
  const _TroubleshootingSection({required this.controller, required this.onPair});

  final NodeController controller;
  final VoidCallback onPair;

  Future<void> _copyDiagnostics(BuildContext context) async {
    final diagnostics = <String, Object?>{
      'app': 'Airbridge',
      'deviceId': controller.config.deviceId,
      'deviceName': controller.config.deviceName,
      'lifecycle': controller.lifecycle,
      'localAddress': controller.localAddress,
      'httpPort': controller.config.httpPort,
      'udpPort': controller.config.udpPort,
      'discoveredPeers': controller.peers.length,
      'trustedPeers': controller.trustedPeers.length,
      'connectedPeers': controller.connectedPeerCount,
      'bluetoothEnabled': controller.bluetooth.isEnabled,
      'bluetoothStatus': controller.bluetooth.status,
      'logs': controller.logs.take(60).map((entry) => entry.toJson()).toList(),
    };
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(diagnostics)),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied diagnostics without pairing keys or message contents.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final online = controller.isRunning;
    final hasAddress = controller.localAddress != 'Unavailable' &&
        controller.localAddress != 'Resolving…';
    final paired = controller.trustedPeers.isNotEmpty || controller.hasSharedSecret;
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: <Widget>[
        _PageHeading(
          icon: Icons.build_circle_outlined,
          title: 'Troubleshooting',
          detail: 'Quick diagnostics for discovery, pairing, file delivery, and Bluetooth.',
          trailing: IconButton(
            tooltip: 'Copy diagnostics',
            onPressed: () => unawaited(_copyDiagnostics(context)),
            icon: const Icon(Icons.content_copy_rounded),
          ),
        ),
        const SizedBox(height: 15),
        _GlassPanel(
          child: Column(
            children: <Widget>[
              _DiagnosticRow(
                ok: online,
                title: 'Airbridge node',
                detail: online ? 'Online and listening on port ${controller.config.httpPort}.' : 'Node status: ${controller.lifecycle}.',
              ),
              const Divider(height: 20, color: _border),
              _DiagnosticRow(
                ok: hasAddress,
                title: 'Local network address',
                detail: hasAddress ? '${controller.localAddress}:${controller.config.httpPort}' : 'Join the same Wi-Fi/LAN, then retry the node.',
              ),
              const Divider(height: 20, color: _border),
              _DiagnosticRow(
                ok: paired,
                title: 'Peer trust',
                detail: paired ? '${controller.trustedPeers.length} QR-paired trusted devices.' : 'Pair both devices using the QR invitation and compare the six-digit code.',
              ),
              const Divider(height: 20, color: _border),
              _DiagnosticRow(
                ok: controller.connectedPeerCount > 0,
                title: 'Mesh link',
                detail: '${controller.connectedPeerCount} linked · ${controller.peers.length} discovered. Allow TCP ${controller.config.httpPort} and UDP ${controller.config.udpPort} through local firewalls.',
              ),
              const Divider(height: 20, color: _border),
              _DiagnosticRow(
                ok: controller.bluetooth.isEnabled,
                title: 'Bluetooth LE',
                detail: controller.bluetooth.status,
              ),
            ],
          ),
        ),
        const SizedBox(height: 13),
        _GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _PanelHeading(
                icon: Icons.tips_and_updates_outlined,
                title: 'Common fixes',
                detail: 'Try these before pairing again.',
              ),
              const SizedBox(height: 12),
              const _InfoBullet(text: 'Put both devices on the same reachable LAN. Guest Wi-Fi, VPNs, and router client isolation can block discovery.'),
              const _InfoBullet(text: 'Allow Airbridge through the Windows firewall for private networks. Keep TCP and UDP ports matched on both devices.'),
              const _InfoBullet(text: 'If pairing fails, create a fresh QR. Invitations expire after five minutes and can only be used once.'),
              const _InfoBullet(text: 'For a failed file transfer, check receiver auto-accept, free disk space, and the maximum file-size setting.'),
              const _InfoBullet(text: 'Bluetooth transfers use BLE and require both adapters to support the Airbridge GATT service; use LAN for larger files.'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton.tonalIcon(
                    onPressed: online ? () => unawaited(controller.start()) : null,
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    label: const Text('Retry node'),
                  ),
                  OutlinedButton.icon(
                    onPressed: online ? onPair : null,
                    icon: const Icon(Icons.qr_code_2_rounded, size: 17),
                    label: const Text('Pair with QR'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow({required this.ok, required this.title, required this.detail});

  final bool ok;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(ok ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
              color: ok ? _mint : const Color(0xFFFFC977), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: const TextStyle(color: Color(0xFFE5EAF3), fontSize: 11, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(detail, style: const TextStyle(color: _muted, fontSize: 10, height: 1.4)),
              ],
            ),
          ),
        ],
      );
}

class _DocsSection extends StatelessWidget {
  const _DocsSection();

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.only(bottom: 8),
        children: const <Widget>[
          _PageHeading(
            icon: Icons.menu_book_outlined,
            title: 'Airbridge docs',
            detail: 'A short guide to pairing, data transfer, and security.',
          ),
          SizedBox(height: 15),
          _DocCard(
            icon: Icons.qr_code_2_rounded,
            title: '1. Pair devices',
            bullets: <String>[
              'Put the devices on a reachable local network and start Airbridge on both.',
              'On one device choose Pair a device; scan the one-time QR from the other.',
              'Compare the six-digit verification code, then confirm. No account or password is required.',
            ],
          ),
          SizedBox(height: 12),
          _DocCard(
            icon: Icons.forum_outlined,
            title: '2. Send messages and data',
            bullets: <String>[
              'Messages accepts text or JSON and broadcasts to connected trusted mesh peers.',
              'Files sends directly to a paired peer. The receiver verifies the file length and SHA-256 digest before showing it.',
              'Received files are kept in the Airbridge application data folder; use Save a copy to export one.',
            ],
          ),
          SizedBox(height: 12),
          _DocCard(
            icon: Icons.bluetooth_rounded,
            title: '3. Bluetooth LE',
            bullets: <String>[
              'Enable Bluetooth in Settings, then scan from the Bluetooth tab. Pair with QR before transferring.',
              'Bluetooth uses BLE GATT, not Bluetooth Classic. Lower throughput makes LAN preferable for large files.',
              'Android, iOS, macOS, Windows, and Linux use the same Airbridge BLE service and encrypted packet protocol. Linux GATT advertising/receiving uses BlueZ; keep its Bluetooth service running and power an LE adapter.',
            ],
          ),
          SizedBox(height: 12),
          _DocCard(
            icon: Icons.lock_outline_rounded,
            title: '4. Encryption and trust',
            bullets: <String>[
              'Paired peer message envelopes, file names/metadata, and file chunks use per-peer AES-256-GCM encryption in transit.',
              'HMAC-SHA256 authenticates paired HTTP requests and WebSocket handshakes; replayed HTTP nonces are rejected.',
              'LAN discovery and basic node status are local control data. Do not expose Airbridge ports to the public internet.',
            ],
          ),
        ],
      );
}

class _DocCard extends StatelessWidget {
  const _DocCard({required this.icon, required this.title, required this.bullets});

  final IconData icon;
  final String title;
  final List<String> bullets;

  @override
  Widget build(BuildContext context) => _GlassPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _PanelHeading(icon: icon, title: title, detail: ''),
            const SizedBox(height: 10),
            ...bullets.map((bullet) => _InfoBullet(text: bullet)),
          ],
        ),
      );
}

class _InfoBullet extends StatelessWidget {
  const _InfoBullet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.only(top: 5),
              child: Icon(Icons.circle, color: _mint, size: 5),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(text, style: const TextStyle(color: _muted, fontSize: 10, height: 1.45)),
            ),
          ],
        ),
      );
}

class _SettingsSection extends StatefulWidget {
  const _SettingsSection({required this.controller});

  final NodeController controller;

  @override
  State<_SettingsSection> createState() => _SettingsSectionState();
}

class _SettingsSectionState extends State<_SettingsSection> {
  late final TextEditingController _nameController;
  late double _maxFileSizeMb;
  bool _savingName = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.controller.settings.deviceName);
    _maxFileSizeMb = widget.controller.settings.maxIncomingFileBytes / (1024 * 1024);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    if (_savingName) return;
    setState(() => _savingName = true);
    try {
      await widget.controller.updateSettings(deviceName: _nameController.text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device name saved.')),
        );
      }
    } on Object catch (error) {
      if (mounted) _showError(context, 'Could not save device name: $error');
    } finally {
      if (mounted) setState(() => _savingName = false);
    }
  }

  Future<void> _setBluetooth(bool value) async {
    try {
      await widget.controller.updateSettings(bluetoothEnabled: value);
    } on Object catch (error) {
      if (mounted) _showError(context, 'Bluetooth could not be changed: $error');
    }
  }

  Future<void> _setAutoAccept(bool value) async {
    try {
      await widget.controller.updateSettings(autoAcceptFiles: value);
    } on Object catch (error) {
      if (mounted) _showError(context, 'File setting could not be saved: $error');
    }
  }

  Future<void> _setMaxFileSize(double value) async {
    final bytes = (value.round() * 1024 * 1024);
    try {
      await widget.controller.updateSettings(maxIncomingFileBytes: bytes);
      if (mounted) setState(() => _maxFileSizeMb = value);
    } on Object catch (error) {
      if (mounted) _showError(context, 'File-size limit could not be saved: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.controller.settings;
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: <Widget>[
        const _PageHeading(
          icon: Icons.settings_outlined,
          title: 'Settings',
          detail: 'A few practical controls for how this device joins and receives data.',
        ),
        const SizedBox(height: 15),
        _GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _PanelHeading(
                icon: Icons.badge_outlined,
                title: 'This device',
                detail: 'Shown to trusted peers during discovery and pairing.',
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _nameController,
                      maxLength: 64,
                      onSubmitted: (_) => unawaited(_saveName()),
                      decoration: const InputDecoration(
                        labelText: 'Device name',
                        counterText: '',
                        prefixIcon: Icon(Icons.devices_rounded),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _savingName ? null : _saveName,
                    child: _savingName
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Save'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText('Device ID  ${widget.controller.config.deviceId}',
                  style: const TextStyle(color: _muted, fontSize: 10)),
            ],
          ),
        ),
        const SizedBox(height: 13),
        _GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _PanelHeading(
                icon: Icons.shield_outlined,
                title: 'Transport security',
                detail: 'Encryption is always on for paired-peer content.',
              ),
              const SizedBox(height: 10),
              const _InfoBullet(text: 'AES-256-GCM protects message bodies, file names/metadata, and every file chunk while in transit.'),
              const _InfoBullet(text: 'HMAC-SHA256 verifies trusted HTTP writes and mesh handshakes. Cleartext writes are rejected.'),
              const _InfoBullet(text: 'This security control is mandatory; there is no “send unencrypted” switch.'),
            ],
          ),
        ),
        const SizedBox(height: 13),
        _GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _PanelHeading(
                icon: Icons.bluetooth_rounded,
                title: 'Bluetooth LE',
                detail: 'Optional nearby transfer transport.',
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: settings.bluetoothEnabled,
                onChanged: (value) => unawaited(_setBluetooth(value)),
                title: const Text('Enable Bluetooth transfers', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                subtitle: Text(widget.controller.bluetooth.status, style: const TextStyle(color: _muted, fontSize: 10)),
                activeThumbColor: _mint,
              ),
            ],
          ),
        ),
        const SizedBox(height: 13),
        _GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _PanelHeading(
                icon: Icons.move_to_inbox_outlined,
                title: 'Incoming files',
                detail: 'Trusted peers only. Files are verified before they are listed.',
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: settings.autoAcceptFiles,
                onChanged: (value) => unawaited(_setAutoAccept(value)),
                title: const Text('Accept files from paired peers', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                subtitle: const Text('Turn this off to reject new file transfers.', style: TextStyle(color: _muted, fontSize: 10)),
                activeThumbColor: _mint,
              ),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  const Expanded(
                    child: Text('Maximum file size', style: TextStyle(color: Color(0xFFE5EAF3), fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                  Text('${_maxFileSizeMb.round()} MB', style: const TextStyle(color: _mint, fontSize: 11, fontWeight: FontWeight.w800)),
                ],
              ),
              Slider(
                value: _maxFileSizeMb.clamp(1, 1024).toDouble(),
                min: 1,
                max: 1024,
                divisions: 1023,
                label: '${_maxFileSizeMb.round()} MB',
                onChanged: (value) => setState(() => _maxFileSizeMb = value),
                onChangeEnd: (value) => unawaited(_setMaxFileSize(value)),
                activeColor: _mint,
              ),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Received files folder\n${widget.controller.receivedFilesDirectory}',
                      style: const TextStyle(color: _muted, fontSize: 9, height: 1.4),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy folder path',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: widget.controller.receivedFilesDirectory));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied folder path.')));
                    },
                    icon: const Icon(Icons.content_copy_rounded, size: 17),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<_PickedLocalFile?> _pickLocalFile() async {
  final selected = await FilePicker.pickFile(dialogTitle: 'Choose a file to send');
  if (selected == null) return null;
  final path = selected.path;
  if (path != null && await File(path).exists()) {
    return _PickedLocalFile(path: path);
  }
  final expectedLength = await selected.length();
  if (expectedLength != null && expectedLength > maxSupportedIncomingFileBytes) {
    throw const FileTransferException('Files larger than 1 GiB are not supported.');
  }
  final directory = await Directory.systemTemp.createTemp('airbridge-outgoing-');
  final selectedName = selected.name
      .replaceAll(String.fromCharCode(92), '/')
      .split('/')
      .last;
  final sanitizedName = selectedName
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '_')
      .replaceAll(RegExp(r'[:*?"<>|]'), '_')
      .trim();
  final safeName = sanitizedName.isEmpty || sanitizedName == '.' || sanitizedName == '..'
      ? 'outgoing-file'
      : sanitizedName;
  final file = File('${directory.path}${Platform.pathSeparator}$safeName');
  try {
    final sink = file.openWrite();
    var copiedBytes = 0;
    try {
      await for (final chunk in selected.readAsByteStream()) {
        copiedBytes += chunk.length;
        if (copiedBytes > maxSupportedIncomingFileBytes) {
          throw const FileTransferException('Files larger than 1 GiB are not supported.');
        }
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (expectedLength != null && copiedBytes != expectedLength) {
      throw const FileTransferException('The selected file changed while it was being prepared.');
    }
    return _PickedLocalFile(path: file.path, temporaryDirectory: directory);
  } on Object {
    if (await directory.exists()) await directory.delete(recursive: true);
    rethrow;
  }
}

class _PickedLocalFile {
  const _PickedLocalFile({required this.path, this.temporaryDirectory});

  final String path;
  final Directory? temporaryDirectory;

  Future<void> cleanup() async {
    final directory = temporaryDirectory;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

void _showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

class _NodeHeader extends StatelessWidget {
  const _NodeHeader({required this.controller});

  final NodeController controller;

  @override
  Widget build(BuildContext context) {
    final isMaster = controller.role == 'master';
    return _GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 37,
                height: 37,
                decoration: BoxDecoration(
                  color: controller.isRunning
                      ? const Color(0x1F63E6BE)
                      : const Color(0x1FFFC977),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.router_rounded,
                  color: controller.isRunning ? _mint : const Color(0xFFFFC977),
                  size: 19,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'Node status',
                      style: TextStyle(
                        color: Color(0xFFE8EDF5),
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${controller.localAddress}  ·  ${controller.lifecycle.toUpperCase()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _muted, fontSize: 10),
                    ),
                  ],
                ),
              ),
              _RoleBadge(isMaster: isMaster),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Pair a device with QR',
                onPressed: controller.isRunning
                    ? () => showPairingDialog(context, controller)
                    : null,
                color: _mint,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.qr_code_2_rounded),
              ),
            ],
          ),
          const SizedBox(height: 11),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: <Widget>[
              Tooltip(
                message: controller.config.deviceId,
                child: _InfoChip(
                  icon: Icons.fingerprint_rounded,
                  label: controller.config.deviceId,
                  compact: true,
                ),
              ),
              _InfoChip(
                icon: Icons.lan_rounded,
                label: '${controller.localAddress}:${controller.config.httpPort}',
              ),
              _InfoChip(
                icon: Icons.sensors_rounded,
                label: 'UDP ${controller.config.udpPort}',
              ),
              _InfoChip(
                icon: Icons.devices_rounded,
                label: '${controller.peers.length} discovered  ·  '
                    '${controller.connectedPeerCount} linked',
              ),
            ],
          ),
          if (controller.lifecycle == 'error') ...<Widget>[
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    'The node could not start. Check the event log and verify the configured ports are free.',
                    style: TextStyle(color: Color(0xFFFF9E9E), fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () => unawaited(controller.start()),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.isMaster});

  final bool isMaster;

  @override
  Widget build(BuildContext context) {
    final color = isMaster ? _mint : const Color(0xFF8CA8FF);
    final badgeFill = isMaster ? const Color(0x1F63E6BE) : const Color(0x1F8CA8FF);
    final badgeBorder = isMaster ? const Color(0x6663E6BE) : const Color(0x668CA8FF);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: badgeFill,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: badgeBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(isMaster ? Icons.stars_rounded : Icons.device_hub_rounded,
              color: color, size: 15),
          const SizedBox(width: 6),
          Text(
            isMaster ? 'MASTER' : 'PEER',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: .9,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.icon,
    required this.label,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(maxWidth: 360),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFF0C1220),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 14, color: const Color(0xE663E6BE)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                compact && label.length > 28 ? '${label.substring(0, 28)}…' : label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFCFD7E5), fontSize: 11),
              ),
            ),
          ],
        ),
      );
}

class _TerminalPanel extends StatelessWidget {
  const _TerminalPanel({
    required this.controller,
    required this.textController,
    required this.sending,
    required this.onSend,
  });

  final NodeController controller;
  final TextEditingController textController;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => _GlassPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const _PanelHeading(
              icon: Icons.terminal_rounded,
              title: 'Payload terminal',
              detail: 'Dispatch to this node and fan out over the mesh',
            ),
            const SizedBox(height: 14),
            TextField(
              controller: textController,
              minLines: 1,
              maxLines: 4,
              maxLength: controller.config.maxPayloadBytes,
              onSubmitted: (_) => onSend(),
              decoration: const InputDecoration(
                hintText: 'Type text or JSON, e.g. {"event":"hello"}',
                counterText: '',
                prefixIcon: Icon(Icons.code_rounded),
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                const Icon(Icons.lock_outline_rounded, size: 15, color: _muted),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'AES-256-GCM encrypted peer links  •  HMAC-authenticated',
                    style: const TextStyle(
                      color: _mint,
                      fontSize: 11,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: sending || !controller.isRunning ? null : onSend,
                  style: FilledButton.styleFrom(
                    backgroundColor: _mint,
                    foregroundColor: const Color(0xFF07120F),
                    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
                  ),
                  icon: sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded, size: 17),
                  label: Text(sending ? 'Sending' : 'Broadcast'),
                ),
              ],
            ),
          ],
        ),
      );
}

class _PeerPanel extends StatelessWidget {
  const _PeerPanel({required this.controller});

  final NodeController controller;

  @override
  Widget build(BuildContext context) {
    final peers = controller.peers;
    final connected = controller.connectedPeerIds;
    final trusted = controller.trustedPeers.map((peer) => peer.deviceId).toSet();
    return _GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _PanelHeading(
            icon: Icons.hub_outlined,
            title: 'Mesh peers',
            detail: '${peers.length} visible on this subnet',
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0x1F63E6BE),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${connected.length} LINKED',
                style: const TextStyle(
                  color: _mint,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .5,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (peers.isEmpty)
            const _EmptyState(
              icon: Icons.radar_rounded,
              title: 'Scanning local subnet',
              detail: 'Peers appear here as UDP heartbeats arrive.',
            )
          else
            ...peers.map(
              (peer) => Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: _PeerTile(
                  peer: peer,
                  linked: connected.contains(peer.deviceId),
                  trusted: controller.hasSharedSecret || trusted.contains(peer.deviceId),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({
    required this.peer,
    required this.linked,
    required this.trusted,
  });

  final Peer peer;
  final bool linked;
  final bool trusted;

  @override
  Widget build(BuildContext context) {
    final accent = linked ? _mint : const Color(0xFF71809B);
    final connectionStatus = linked
        ? 'WebSocket linked'
        : trusted
            ? 'Trusted • connecting'
            : 'Unpaired • scan QR';
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1220),
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: linked ? const Color(0x2163E6BE) : const Color(0x2171809B),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(Icons.devices_rounded, size: 17, color: accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        peer.deviceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFE5EAF3),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      peer.role.toUpperCase(),
                      style: TextStyle(
                        color: peer.role == 'master' ? _mint : _muted,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${peer.host}:${peer.httpPort}  •  $connectionStatus',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 10),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
        ],
      ),
    );
  }
}

class _MessagePanel extends StatefulWidget {
  const _MessagePanel({required this.controller, this.height = 330});

  final NodeController controller;
  final double height;

  @override
  State<_MessagePanel> createState() => _MessagePanelState();
}

class _MessagePanelState extends State<_MessagePanel> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _copyMessages(List<NodeMessage> messages) async {
    final json = const JsonEncoder.withIndent('  ').convert(
      messages.map((message) => message.toJson()).toList(growable: false),
    );
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${messages.length} messages as JSON.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allMessages = widget.controller.messages;
    final normalizedQuery = _query.trim().toLowerCase();
    final messages = normalizedQuery.isEmpty
        ? allMessages
        : allMessages
            .where(
              (message) =>
                  message.senderName.toLowerCase().contains(normalizedQuery) ||
                  message.senderId.toLowerCase().contains(normalizedQuery) ||
                  message.text.toLowerCase().contains(normalizedQuery),
            )
            .toList(growable: false);
    final detail = normalizedQuery.isEmpty
        ? '${allMessages.length} recent messages'
        : '${messages.length} matches • ${allMessages.length} retained';

    return SizedBox(
      height: widget.height,
      child: _GlassPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _PanelHeading(
              icon: Icons.swap_horiz_rounded,
              title: 'Message stream',
              detail: detail,
              trailing: IconButton(
                tooltip: 'Copy visible messages as JSON',
                visualDensity: VisualDensity.compact,
                onPressed: messages.isEmpty ? null : () => _copyMessages(messages),
                icon: const Icon(Icons.content_copy_rounded, size: 17),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: 'Search sender or payload',
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                suffixIcon: normalizedQuery.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.close_rounded, size: 17),
                      ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: allMessages.isEmpty
                  ? const _EmptyState(
                      icon: Icons.mark_chat_unread_outlined,
                      title: 'No messages yet',
                      detail: 'Broadcast a payload or wait for a peer.',
                    )
                  : messages.isEmpty
                      ? const _EmptyState(
                          icon: Icons.search_off_rounded,
                          title: 'No matches',
                          detail: 'Try a different sender name or payload term.',
                        )
                      : ListView.separated(
                          reverse: true,
                          itemCount: messages.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, index) => _MessageTile(
                            message: messages[messages.length - index - 1],
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message});

  final NodeMessage message;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: message.isLocal ? const Color(0xFF10251F) : const Color(0xFF101827),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: message.isLocal ? const Color(0xFF245A49) : _border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  message.isLocal ? Icons.north_east_rounded : Icons.south_west_rounded,
                  size: 13,
                  color: message.isLocal ? _mint : const Color(0xFF8CA8FF),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    message.senderName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFDDE5F2),
                    ),
                  ),
                ),
                Text(_formatTime(message.timestamp),
                    style: const TextStyle(color: _muted, fontSize: 10)),
              ],
            ),
            const SizedBox(height: 7),
            SelectableText(
              message.text,
              maxLines: 4,
              style: const TextStyle(
                color: Color(0xFFB8C3D5),
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ],
        ),
      );
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.controller});

  final NodeController controller;

  Future<void> _copyLogs(BuildContext context, List<NodeLogEntry> logs) async {
    final json = const JsonEncoder.withIndent('  ').convert(
      logs.map((entry) => entry.toJson()).toList(growable: false),
    );
    await Clipboard.setData(ClipboardData(text: json));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${logs.length} system log events as JSON.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final logs = controller.logs;
    return _GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _PanelHeading(
            icon: Icons.receipt_long_rounded,
            title: 'System log',
            detail: '${logs.length} recent events',
            trailing: IconButton(
              tooltip: 'Copy recent system log as JSON',
              visualDensity: VisualDensity.compact,
              onPressed: logs.isEmpty
                  ? null
                  : () => unawaited(_copyLogs(context, logs)),
              icon: const Icon(Icons.content_copy_rounded, size: 17),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: logs.isEmpty
                ? const _EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: 'No activity yet',
                    detail: 'Node events will appear here as the mesh starts.',
                  )
                : ListView.builder(
                    reverse: true,
                    itemCount: logs.length,
                    itemBuilder: (context, index) {
                      final entry = logs[logs.length - index - 1];
                      return _LogLine(entry: entry);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.entry});

  final NodeLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = switch (entry.level) {
      'ERROR' => const Color(0xFFFF8585),
      'WARN' => const Color(0xFFFFC977),
      'PEER' => const Color(0xFF9DAFFF),
      'DATA' => _mint,
      _ => const Color(0xFF93A0B5),
    };
    final tint = switch (entry.level) {
      'ERROR' => const Color(0x1FFF8585),
      'WARN' => const Color(0x1FFFC977),
      'PEER' => const Color(0x1F9DAFFF),
      'DATA' => const Color(0x1F63E6BE),
      _ => const Color(0x1F93A0B5),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _formatTime(entry.timestamp),
            style: const TextStyle(color: _muted, fontSize: 10, fontFamily: 'monospace'),
          ),
          const SizedBox(width: 9),
          Container(
            width: 44,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              color: tint,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              entry.level,
              style: TextStyle(color: color, fontSize: 8, fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              entry.message,
              style: const TextStyle(color: Color(0xFFB1BDD0), fontSize: 10, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelHeading extends StatelessWidget {
  const _PanelHeading({
    required this.icon,
    required this.title,
    required this.detail,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
        children: <Widget>[
          Container(
            width: 33,
            height: 33,
            decoration: BoxDecoration(
              color: const Color(0x1763E6BE),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 17, color: _mint),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFFE8EDF5),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(detail, style: const TextStyle(color: _muted, fontSize: 10)),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title, required this.detail});

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 28, color: const Color(0xFF596982)),
              const SizedBox(height: 8),
              Text(title,
                  style: const TextStyle(color: Color(0xFFD7E0EE), fontSize: 12)),
              const SizedBox(height: 4),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _muted, fontSize: 10),
              ),
            ],
          ),
        ),
      );
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({
    required this.child,
    this.padding = const EdgeInsets.all(15),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xE6253247)),
          boxShadow: const <BoxShadow>[
            BoxShadow(color: Color(0x22000000), blurRadius: 20, offset: Offset(0, 8)),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: child,
        ),
      );
}

String _formatBytes(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _formatTime(DateTime timestamp) {
  final local = timestamp.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}:'
      '${local.second.toString().padLeft(2, '0')}';
}

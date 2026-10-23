import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/node_message.dart';
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

enum _DashboardSection { overview, messages, peers, activity }

extension _DashboardSectionDetails on _DashboardSection {
  String get label => switch (this) {
        _DashboardSection.overview => 'Overview',
        _DashboardSection.messages => 'Messages',
        _DashboardSection.peers => 'Mesh peers',
        _DashboardSection.activity => 'Activity',
      };

  String get description => switch (this) {
        _DashboardSection.overview => 'A quick view of your local mesh.',
        _DashboardSection.messages => 'Send payloads and review message traffic.',
        _DashboardSection.peers => 'Discover, pair, and monitor nearby devices.',
        _DashboardSection.activity => 'Inspect recent node and network events.',
      };

  IconData get icon => switch (this) {
        _DashboardSection.overview => Icons.grid_view_rounded,
        _DashboardSection.messages => Icons.forum_outlined,
        _DashboardSection.peers => Icons.hub_outlined,
        _DashboardSection.activity => Icons.receipt_long_outlined,
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
        _DashboardSection.activity => _ActivitySection(
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
  });

  final IconData icon;
  final String label;
  final String value;
  final String detail;
  final Color accent;

  @override
  Widget build(BuildContext context) => _GlassPanel(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: <Widget>[
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Color.fromARGB(31, accent.red, accent.green, accent.blue),
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
      ),
      _MetricCard(
        icon: Icons.hub_outlined,
        label: 'Mesh peers',
        value: '${controller.peers.length}',
        detail: '${controller.connectedPeerCount} linked now',
        accent: const Color(0xFF8CA8FF),
      ),
      _MetricCard(
        icon: Icons.swap_horiz_rounded,
        label: 'Messages',
        value: '${controller.messages.length}',
        detail: 'retained on this device',
        accent: const Color(0xFFFFC977),
      ),
      _MetricCard(
        icon: Icons.verified_user_outlined,
        label: 'Trusted devices',
        value: '${controller.trustedPeers.length}',
        detail: controller.hasSharedSecret ? 'encrypted mesh enabled' : 'paired individually',
        accent: const Color(0xFFC5A5FF),
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
                    controller.hasSharedSecret
                        ? 'AES-256-GCM payloads  •  HMAC-authenticated mesh'
                        : 'QR pairing required  •  payloads are cleartext',
                    style: TextStyle(
                      color: controller.hasSharedSecret ? _mint : const Color(0xFFFFC977),
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
        child: child,
      );
}

String _formatTime(DateTime timestamp) {
  final local = timestamp.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}:'
      '${local.second.toString().padLeft(2, '0')}';
}

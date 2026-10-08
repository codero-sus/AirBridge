import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/node_message.dart';
import '../models/peer.dart';
import '../services/node_controller.dart';

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

class _DashboardPageState extends State<DashboardPage> {
  final TextEditingController _payloadController = TextEditingController();
  bool _sending = false;

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

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => Scaffold(
          backgroundColor: _background,
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 980;
                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: wide ? 28 : 16,
                    vertical: 16,
                  ),
                  child: Column(
                    children: <Widget>[
                      _NodeHeader(controller: widget.controller),
                      const SizedBox(height: 18),
                      Expanded(
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  Expanded(
                                    child: _mainPanels(wide: true),
                                  ),
                                  const SizedBox(width: 18),
                                  SizedBox(
                                    width: 310,
                                    child: SingleChildScrollView(
                                      child: _PeerPanel(controller: widget.controller),
                                    ),
                                  ),
                                ],
                              )
                            : _mainPanels(wide: false),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );

  Widget _mainPanels({required bool wide}) => ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          _TerminalPanel(
            controller: widget.controller,
            textController: _payloadController,
            sending: _sending,
            onSend: _sendPayload,
          ),
          if (!wide) ...<Widget>[
            const SizedBox(height: 14),
            _PeerPanel(controller: widget.controller),
          ],
          const SizedBox(height: 14),
          _MessagePanel(controller: widget.controller),
          const SizedBox(height: 14),
          _LogPanel(controller: widget.controller),
          const SizedBox(height: 16),
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
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  gradient: const LinearGradient(
                    colors: <Color>[Color(0xFF43D9B1), Color(0xFF4D83FF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const Icon(Icons.hub_rounded, color: Color(0xFF06111A)),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'AIRBRIDGE',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Local mesh node  •  ${controller.lifecycle.toUpperCase()}',
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              _RoleBadge(isMaster: isMaster),
            ],
          ),
          const SizedBox(height: 15),
          Wrap(
            spacing: 8,
            runSpacing: 8,
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
                label: '${controller.peers.length} discovered  •  '
                    '${controller.connectedPeerCount} linked',
              ),
            ],
          ),
          if (controller.lifecycle == 'error') ...<Widget>[
            const SizedBox(height: 10),
            const Text(
              'The node could not start. Check the event log and verify the configured ports are free.',
              style: TextStyle(color: Color(0xFFFF9E9E), fontSize: 12),
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
                        ? 'AES-256-GCM enabled  •  HMAC-authenticated mesh'
                        : 'Open LAN mode  •  configure AIRBRIDGE_SHARED_SECRET for protection',
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
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, required this.linked});

  final Peer peer;
  final bool linked;

  @override
  Widget build(BuildContext context) {
    final accent = linked ? _mint : const Color(0xFF71809B);
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
                  '${peer.host}:${peer.httpPort}  •  ${linked ? 'WebSocket linked' : 'discovered'}',
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

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({required this.controller});

  final NodeController controller;

  @override
  Widget build(BuildContext context) {
    final messages = controller.messages;
    return SizedBox(
      height: 330,
      child: _GlassPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _PanelHeading(
              icon: Icons.swap_horiz_rounded,
              title: 'Live message stream',
              detail: '${messages.length} recent messages',
            ),
            const SizedBox(height: 10),
            Expanded(
              child: messages.isEmpty
                  ? const _EmptyState(
                      icon: Icons.mark_chat_unread_outlined,
                      title: 'No messages yet',
                      detail: 'Broadcast a payload or wait for a peer.',
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

  @override
  Widget build(BuildContext context) {
    final logs = controller.logs;
    return SizedBox(
      height: 240,
      child: _GlassPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _PanelHeading(
              icon: Icons.receipt_long_rounded,
              title: 'System log',
              detail: '${logs.length} recent events',
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
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

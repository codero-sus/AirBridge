import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/node_controller.dart';
import '../services/pairing_service.dart';
import 'pairing_qr_scanner.dart';

const Color _pairPanel = Color(0xFF111827);
const Color _pairBorder = Color(0xFF253247);
const Color _pairMint = Color(0xFF63E6BE);
const Color _pairMuted = Color(0xFF92A0B8);

Future<void> showPairingDialog(
  BuildContext context,
  NodeController controller, {
  String? initialQrPayload,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => PairingDialog(
        controller: controller,
        initialQrPayload: initialQrPayload,
      ),
    );

class PairingDialog extends StatefulWidget {
  const PairingDialog({
    super.key,
    required this.controller,
    this.initialQrPayload,
  });

  final NodeController controller;
  final String? initialQrPayload;

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  final TextEditingController _qrInputController = TextEditingController();
  PairingInvitation? _invitation;
  PairingInvitation? _pendingInvitation;
  Timer? _expiryTimer;
  bool _creatingInvitation = false;
  bool _joining = false;
  String? _error;
  String? _success;

  bool get _canScan =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows ||
      Platform.isLinux;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshInvitation());
    final initialQrPayload = widget.initialQrPayload;
    if (initialQrPayload != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _acceptQrPayload(initialQrPayload);
      });
    }
    _expiryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _invitation != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    final invitation = _invitation;
    if (invitation != null) {
      widget.controller.cancelPairingInvitation(invitation);
    }
    _qrInputController.dispose();
    super.dispose();
  }

  Future<void> _refreshInvitation() async {
    if (_creatingInvitation) return;
    setState(() {
      _creatingInvitation = true;
      _error = null;
      _success = null;
    });
    try {
      final invitation = await widget.controller.createPairingInvitation();
      if (!mounted) return;
      setState(() {
        _invitation = invitation;
        _creatingInvitation = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _creatingInvitation = false;
      });
    }
  }

  Future<void> _scanQr() async {
    final payload = await scanAirbridgePairingQr(context);
    if (payload != null && mounted) _acceptQrPayload(payload);
  }

  void _acceptQrPayload(String payload) {
    try {
      final invitation = PairingInvitation.parse(payload);
      setState(() {
        _qrInputController.text = payload;
        _pendingInvitation = invitation;
        _error = null;
        _success = null;
      });
    } on Object catch (error) {
      setState(() {
        _pendingInvitation = null;
        _error = error.toString();
        _success = null;
      });
    }
  }

  Future<void> _joinDevice() async {
    final invitation = _pendingInvitation;
    final rawQr = _qrInputController.text.trim();
    if (invitation == null || rawQr.isEmpty || _joining) return;
    setState(() {
      _joining = true;
      _error = null;
      _success = null;
    });
    try {
      final peer = await widget.controller.joinPairingInvitation(rawQr);
      if (!mounted) return;
      setState(() {
        _joining = false;
        _success = 'Securely paired with ${peer.deviceName}.';
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = error.toString();
      });
    }
  }

  String _remaining(PairingInvitation invitation) {
    final seconds = invitation.expiresAt
        .difference(DateTime.now().toUtc())
        .inSeconds
        .clamp(0, 5 * 60);
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final remainder = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$remainder';
  }

  @override
  Widget build(BuildContext context) {
    final invitation = _invitation;
    final pending = _pendingInvitation;
    final inviteExpired = invitation == null
        ? false
        : !widget.controller.isPairingInvitationActive(invitation);
    return Dialog(
      backgroundColor: _pairPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: _pairBorder),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: Image.asset(
                      'assets/airbridge_logo.png',
                      width: 34,
                      height: 34,
                      fit: BoxFit.cover,
                      semanticLabel: 'Airbridge logo',
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Pair a device',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const Text(
                'Scan this one-time QR from the other device, then compare the six-digit code. No account or password is needed.',
                style: TextStyle(color: _pairMuted, height: 1.45),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF172132),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _pairBorder),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.wifi_rounded, color: _pairMint, size: 18),
                    SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        'Both devices must be on the same Wi-Fi/LAN. Mobile data, VPNs, guest Wi-Fi, or router client isolation can block pairing. After switching networks, create a fresh QR.',
                        style: TextStyle(color: _pairMuted, fontSize: 12, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _buildHostInvitation(invitation, inviteExpired),
              const SizedBox(height: 20),
              const Divider(color: _pairBorder),
              const SizedBox(height: 12),
              const Text(
                'JOIN ANOTHER DEVICE',
                style: TextStyle(
                  color: _pairMint,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.3,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _qrInputController,
                minLines: 1,
                maxLines: 3,
                maxLength: 2048,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: 'Paste AirBridge QR text',
                  hintText: 'airbridge://pair?...',
                  counterText: '',
                  suffixIcon: IconButton(
                    tooltip: 'Paste from clipboard',
                    onPressed: () async {
                      final data = await Clipboard.getData(Clipboard.kTextPlain);
                      if (data?.text != null && mounted) {
                        _qrInputController.text = data!.text!;
                        _acceptQrPayload(data.text!);
                      }
                    },
                    icon: const Icon(Icons.content_paste_rounded),
                  ),
                ),
                onChanged: (value) {
                  if (value.trim().startsWith('airbridge://pair')) {
                    _acceptQrPayload(value.trim());
                  }
                },
              ),
              if (_canScan) ...<Widget>[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _joining ? null : _scanQr,
                  icon: const Icon(Icons.document_scanner_rounded),
                  label: const Text('Scan QR with camera'),
                ),
              ],
              if (pending != null) ...<Widget>[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0C1220),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _pairBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Connect to ${pending.hostDeviceName}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${pending.hostAddress}:${pending.httpPort}  •  expires ${_remaining(pending)}',
                        style: const TextStyle(color: _pairMuted, fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: SelectableText(
                          pending.formattedVerificationCode,
                          style: const TextStyle(
                            color: _pairMint,
                            fontSize: 27,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 4,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Check that this matches the code shown on the device you are pairing with.',
                        style: TextStyle(color: _pairMuted, fontSize: 12, height: 1.4),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _joining || pending.isExpired ? null : _joinDevice,
                        icon: _joining
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.link_rounded),
                        label: Text(_joining ? 'Pairing…' : 'Confirm code & connect'),
                      ),
                    ],
                  ),
                ),
              ],
              if (_error != null) ...<Widget>[
                const SizedBox(height: 12),
                _FeedbackMessage(message: _error!, isError: true),
              ],
              if (_success != null) ...<Widget>[
                const SizedBox(height: 12),
                _FeedbackMessage(message: _success!, isError: false),
              ],
              const SizedBox(height: 8),
              const Text(
                'Pairing secrets are one-time and expire after five minutes. Keep the QR private until pairing finishes.',
                style: TextStyle(color: _pairMuted, fontSize: 11, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHostInvitation(PairingInvitation? invitation, bool expired) {
    if (_creatingInvitation) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (invitation == null || expired) {
      return Column(
        children: <Widget>[
          if (invitation == null)
            const Text(
              'Connect this device to Wi-Fi/LAN and allow local-network access, then try again. Mobile data or a VPN alone cannot provide a reachable pairing address.',
              style: TextStyle(color: _pairMuted),
              textAlign: TextAlign.center,
            )
          else
            const Text(
              'This QR expired or was already used. Create a fresh one to pair another device.',
              style: TextStyle(color: _pairMuted),
              textAlign: TextAlign.center,
            ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _refreshInvitation,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Create new QR'),
          ),
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1220),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _pairBorder),
      ),
      child: Column(
        children: <Widget>[
          const Text(
            'SHOW THIS QR TO THE OTHER DEVICE',
            style: TextStyle(
              color: _pairMuted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: QrImageView(
              data: invitation.qrPayload,
              version: QrVersions.auto,
              size: 200,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.Q,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'SIX-DIGIT PAIR CODE',
            style: TextStyle(
              color: _pairMuted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            invitation.formattedVerificationCode,
            style: const TextStyle(
              color: _pairMint,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: 5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${invitation.hostDeviceName}  •  ${invitation.hostAddress}:${invitation.httpPort}  •  ${_remaining(invitation)} remaining',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _pairMuted, fontSize: 11),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: invitation.qrPayload));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('One-time pairing QR text copied.')),
                );
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 17),
            label: const Text('Copy QR text'),
          ),
        ],
      ),
    );
  }
}

class _FeedbackMessage extends StatelessWidget {
  const _FeedbackMessage({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? const Color(0xFFFF9E9E) : _pairMint;
    final translucentFill = isError
        ? const Color(0x14FF9E9E)
        : const Color(0x1463E6BE);
    final translucentBorder = isError
        ? const Color(0x5AFF9E9E)
        : const Color(0x5A63E6BE);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: translucentFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: translucentBorder),
      ),
      child: Text(message, style: TextStyle(color: color, fontSize: 12)),
    );
  }
}

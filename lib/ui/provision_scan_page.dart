/// Paged QR scan page for HQ provisioning and family-card handoff.
///
/// A single QR rarely carries a full account payload, so the phone must scan
/// several. This page keeps a [ProvisionAssembler] open, shows live progress
/// (N OF M), and pops the assembled payload once its CRC32 checks out. A
/// single non-provision frame (e.g. a claim QR) is accepted immediately, so
/// the same page doubles as the plain scanner.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/provision_packet.dart';
import 'linux_qr_scan_page.dart';
import 'windows_qr_scan_page.dart';

class ProvisionScanPage extends StatefulWidget {
  const ProvisionScanPage({
    super.key,
    required this.label,
    this.hint = 'SCAN QR 1: HOLD STEADY',
    this.expectedType,
  });

  final String label;
  final String hint;

  /// When set, only envelopes of this type are accepted; wrong-type and
  /// expired payloads flash an error and keep the scanner alive.
  final ProvisionType? expectedType;

  @override
  State<ProvisionScanPage> createState() => _ProvisionScanPageState();
}

class _ProvisionScanPageState extends State<ProvisionScanPage> {
  final _assembler = ProvisionAssembler();
  bool _done = false;
  bool _cameraGranted = false;
  String? _error;
  int _received = 0;
  int? _total;

  @override
  void initState() {
    super.initState();
    _requestCamera();
  }

  Future<void> _requestCamera() async {
    if (defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows) {
      if (mounted) setState(() => _cameraGranted = true);
      return;
    }
    try {
      final status = await Permission.camera.request();
      if (!mounted) return;
      setState(() => _cameraGranted = status.isGranted);
    } catch (_) {
      if (mounted) setState(() => _cameraGranted = false);
    }
  }

  void _onScan(String raw) {
    if (_done) return;
    // A single non-provision frame (e.g. a claim QR) is accepted immediately,
    // but only when this page is not constrained to a provision type.
    if (_assembler.total == null && !isProvisionFrame(raw)) {
      if (widget.expectedType != null) {
        setState(() {
          _error = 'wrong QR type (expected '
              '${widget.expectedType!.tag}): scan the correct panel';
          _assembler.reset();
          _received = 0;
          _total = null;
        });
        return;
      }
      _done = true;
      Navigator.of(context).pop(raw);
      return;
    }
    final err = _assembler.add(raw);
    if (err != null) {
      setState(() {
        _error = err;
        _assembler.reset();
        _received = 0;
        _total = null;
      });
      return;
    }
    setState(() {
      _received = _assembler.received;
      _total = _assembler.total;
      _error = null;
    });
    if (_assembler.complete) {
      // A provision envelope must match the expected type and stay fresh.
      final parsed = parseProvisionEnvelope(
        _assembler.payload,
        requireType: widget.expectedType,
      );
      if (parsed.envelope == null) {
        setState(() {
          _error = parsed.error ?? 'malformed provision payload';
          _assembler.reset();
          _received = 0;
          _total = null;
        });
        return;
      }
      _done = true;
      Navigator.of(context).pop(_assembler.payload);
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total == null
        ? widget.hint
        : 'SCANNED ${_received.clamp(1, _total!)} OF $_total';
    final body = switch (defaultTargetPlatform) {
      TargetPlatform.linux => LinuxQrScanPage(onScan: _onScan),
      TargetPlatform.windows => WindowsQrScanPage(onScan: _onScan),
      _ => _MobileScan(onScan: _onScan, enabled: _cameraGranted),
    };
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.label)),
      body: Stack(
        children: [
          Positioned.fill(child: body),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black.withValues(alpha: 0.7),
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _error ?? progress,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _error != null ? Colors.redAccent : Colors.greenAccent,
                      fontFamily: 'monospace',
                      fontSize: 13,
                      letterSpacing: 1,
                    ),
                  ),
                  if (_total != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: _received / _total!,
                          minHeight: 4,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// mobile_scanner-backed live feed that forwards decoded frames.
class _MobileScan extends StatelessWidget {
  const _MobileScan({required this.onScan, required this.enabled});

  final ValueChanged<String> onScan;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return const Center(
        child: Text(
          'CAMERA PERMISSION REQUIRED',
          style: TextStyle(color: Colors.white54, fontFamily: 'monospace'),
        ),
      );
    }
    return MobileScanner(
      onDetect: (capture) {
        for (final b in capture.barcodes) {
          final raw = b.rawValue;
          if (raw != null) onScan(raw);
        }
      },
    );
  }
}
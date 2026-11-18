import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/utils/isbn.dart';

enum ScanMode { isbn, copyBarcode }

/// Full-screen camera scanner. Pops with the scanned value (String).
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key, required this.mode});
  final ScanMode mode;

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  late final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: widget.mode == ScanMode.isbn
        ? const [BarcodeFormat.ean13]
        : const [
            BarcodeFormat.code128,
            BarcodeFormat.code39,
            BarcodeFormat.code93,
            BarcodeFormat.codabar,
            BarcodeFormat.ean13,
            BarcodeFormat.ean8,
            BarcodeFormat.itf14,
            BarcodeFormat.qrCode,
          ],
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue?.trim();
      if (v == null || v.isEmpty) continue;
      if (widget.mode == ScanMode.isbn && !Isbn.isValid(v)) continue; // ignore non-ISBN EAN-13
      _done = true;
      HapticFeedback.mediumImpact();
      context.pop(v);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.mode == ScanMode.isbn ? 'Imbas ISBN' : 'Imbas Barcode Naskhah'),
        actions: [
          IconButton(
            tooltip: 'Lampu suluh',
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Kamera tidak dapat digunakan (${error.errorCode.name}). '
                  'Benarkan akses kamera dalam Tetapan Android, atau masukkan kod secara manual.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: Colors.black54,
              padding: const EdgeInsets.all(16),
              child: Text(
                widget.mode == ScanMode.isbn
                    ? 'Halakan kamera ke barcode ISBN (EAN-13) di belakang buku.'
                    : 'Halakan kamera ke label barcode naskhah.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

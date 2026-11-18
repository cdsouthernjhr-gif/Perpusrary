import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router/routes.dart';
import 'scanner_screen.dart';

/// Text field that accepts:
///  * typing,
///  * a physical USB/Bluetooth barcode scanner acting as a keyboard
///    ("keyboard wedge" — types the code then presses Enter → [onSubmitted]),
///  * the camera scanner (suffix button).
class ScanField extends StatelessWidget {
  const ScanField({
    super.key,
    required this.controller,
    required this.label,
    required this.mode,
    this.validator,
    this.onSubmitted,
    this.onScanned,
    this.enabled = true,
    this.autofocus = false,
    this.helperText,
    this.extraSuffix,
  });

  final TextEditingController controller;
  final String label;
  final ScanMode mode;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onScanned;
  final bool enabled;
  final bool autofocus;
  final String? helperText;
  final Widget? extraSuffix;

  Future<void> _openCamera(BuildContext context) async {
    final value = await context.push<String>(Routes.scanner, extra: mode);
    if (value == null) return;
    controller.text = value;
    onScanned?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      textInputAction: TextInputAction.done,
      keyboardType: mode == ScanMode.isbn ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ?extraSuffix,
            IconButton(
              tooltip: 'Imbas dengan kamera',
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: enabled ? () => _openCamera(context) : null,
            ),
          ],
        ),
      ),
      validator: validator,
      onFieldSubmitted: onSubmitted,
    );
  }
}

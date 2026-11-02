import 'package:flutter/material.dart';

/// Reveal state is local to this field and disappears when the form closes.
class PasswordField extends StatefulWidget {
  const PasswordField({
    required this.controller,
    required this.label,
    this.validator,
    this.enabled = true,
    this.maxLength,
    super.key,
  });
  final TextEditingController controller;
  final String label;
  final FormFieldValidator<String>? validator;
  final bool enabled;
  final int? maxLength;
  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _visible = false;
  @override
  Widget build(BuildContext context) => TextFormField(
    controller: widget.controller,
    enabled: widget.enabled,
    obscureText: !_visible,
    autocorrect: false,
    enableSuggestions: false,
    maxLength: widget.maxLength,
    validator: widget.validator,
    decoration: InputDecoration(
      labelText: widget.label,
      suffixIcon: IconButton(
        tooltip: '${_visible ? 'Ẩn' : 'Xem'} ${widget.label.toLowerCase()}',
        onPressed: widget.enabled
            ? () => setState(() => _visible = !_visible)
            : null,
        isSelected: _visible,
        icon: Icon(
          _visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
      ),
    ),
  );
}

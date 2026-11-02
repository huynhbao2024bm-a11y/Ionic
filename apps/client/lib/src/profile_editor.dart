import 'package:flutter/material.dart';
import 'account_avatar.dart';
import 'ionic_api.dart';

class ProfileEditor extends StatefulWidget {
  const ProfileEditor({
    required this.api,
    required this.profile,
    required this.onChanged,
    super.key,
  });
  final IonicApi api;
  final ApiProfile profile;
  final ValueChanged<ApiUser> onChanged;
  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  late final _name = TextEditingController(text: widget.profile.displayName);
  late final _bio = TextEditingController(text: widget.profile.bio);
  late String? _avatar = widget.profile.avatarMediaId;
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final user = await widget.api.updateProfile(
        _name.text.trim(),
        _bio.text.trim(),
      );
      widget.onChanged(user);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = apiErrorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('Chỉnh sửa hồ sơ'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AvatarEditor(
                api: widget.api,
                name: _name.text,
                mediaId: _avatar,
                onSaved: (id) async {
                  if (mounted) setState(() => _avatar = id);
                  final user = await widget.api.currentUser();
                  widget.onChanged(user);
                },
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _name,
                readOnly: _saving,
                maxLength: 48,
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Tên hiển thị'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _bio,
                readOnly: _saving,
                maxLength: 160,
                minLines: 2,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Tiểu sử',
                  alignLabelWithHint: true,
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Đóng'),
        ),
        FilledButton(
          onPressed:
              _saving ||
                  _name.text.trim().isEmpty ||
                  _name.text.runes.length > 48 ||
                  _bio.text.runes.length > 160
              ? null
              : _save,
          child: Text(_saving ? 'Đang lưu…' : 'Lưu thay đổi'),
        ),
      ],
    ),
  );
}

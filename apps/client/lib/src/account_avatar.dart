import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'ionic_api.dart';

/// Private media is fetched through the authenticated API, never a public URL.
class AccountAvatar extends StatefulWidget {
  const AccountAvatar({
    required this.api,
    required this.name,
    this.mediaId,
    this.size = 44,
    super.key,
  });
  final IonicApi? api;
  final String name;
  final String? mediaId;
  final double size;
  @override
  State<AccountAvatar> createState() => _AccountAvatarState();
}

class _AccountAvatarState extends State<AccountAvatar> {
  Future<Uint8List>? _bytes;
  void _load() {
    _bytes = widget.mediaId == null || widget.api == null
        ? null
        : widget.api!.mediaBytes(widget.mediaId!);
    _bytes?.ignore();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AccountAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaId != widget.mediaId || oldWidget.api != widget.api) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _bytes,
    builder: (context, result) => SizedBox(
      width: widget.size,
      height: widget.size,
      child: ClipOval(
        child: result.connectionState == ConnectionState.done && result.hasData
            ? Image.memory(
                result.data!,
                fit: BoxFit.cover,
                gaplessPlayback: false,
                cacheWidth:
                    (widget.size * MediaQuery.devicePixelRatioOf(context))
                        .round(),
                errorBuilder: (_, _, _) => _fallback(context),
              )
            : _fallback(context),
      ),
    ),
  );
  Widget _fallback(BuildContext context) => CircleAvatar(
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
    foregroundColor: Theme.of(context).colorScheme.onSurface,
    child: Text(
      widget.name.trim().isEmpty
          ? 'I'
          : widget.name.trim().characters.first.toUpperCase(),
      style: TextStyle(
        fontSize: widget.size * .38,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class AvatarEditor extends StatefulWidget {
  const AvatarEditor({
    required this.api,
    required this.name,
    required this.mediaId,
    required this.onSaved,
    super.key,
  });
  final IonicApi api;
  final String name;
  final String? mediaId;
  final Future<void> Function(String?) onSaved;
  @override
  State<AvatarEditor> createState() => _AvatarEditorState();
}

class _AvatarEditorState extends State<AvatarEditor> {
  bool _busy = false;
  String? _error;
  Future<void> _change({bool remove = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? staged;
    try {
      if (!remove) {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 1024,
          maxHeight: 1024,
        );
        if (picked == null || !mounted) return;
        if (await picked.length() > 24 * 1024 * 1024) {
          throw StateError('Ảnh quá lớn.');
        }
        final optimized = await compute(
          optimizeAvatar,
          await picked.readAsBytes(),
        );
        staged = (await widget.api.uploadAttachment(
          optimized,
          mediaType: 'image',
        )).id;
      }
      await widget.api.setAvatar(staged);
      if (mounted) await widget.onSaved(staged);
    } catch (e) {
      if (staged != null) {
        try {
          await widget.api.deleteStagedAttachment(staged);
        } catch (_) {}
      }
      if (mounted) {
        setState(
          () => _error = e is IonicApiException
              ? apiErrorText(e)
              : 'Không đổi được ảnh. Hãy chọn ảnh khác hoặc thử lại.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Semantics(
        label: 'Ảnh đại diện',
        child: AccountAvatar(
          api: widget.api,
          name: widget.name,
          mediaId: widget.mediaId,
          size: 80,
        ),
      ),
      Wrap(
        alignment: WrapAlignment.center,
        children: [
          TextButton.icon(
            onPressed: _busy ? null : _change,
            icon: const Icon(Icons.add_a_photo_outlined, size: 18),
            label: const Text('Đổi ảnh'),
          ),
          if (widget.mediaId != null)
            TextButton(
              onPressed: _busy ? null : () => _change(remove: true),
              child: const Text('Xóa ảnh'),
            ),
        ],
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_error != null)
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
    ],
  );
}

Uint8List optimizeAvatar(Uint8List input) {
  if (input.length > 24 * 1024 * 1024) throw StateError('Ảnh quá lớn.');
  final decoder = img.findDecoderForData(input);
  final info = decoder?.startDecode(input);
  if (info == null ||
      info.width < 1 ||
      info.height < 1 ||
      info.width * info.height > 16777216) {
    throw StateError('Ảnh không hợp lệ.');
  }
  final decoded = decoder!.decodeFrame(0);
  if (decoded == null) {
    throw StateError('Ảnh không hợp lệ.');
  }
  final square = img.copyResizeCropSquare(
    img.bakeOrientation(decoded),
    size: 512,
  );
  square.exif = img.ExifData();
  square.iccProfile = null;
  square.textData = null;
  return Uint8List.fromList(img.encodeJpg(square, quality: 85));
}

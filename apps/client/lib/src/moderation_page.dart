import 'package:flutter/material.dart';
import 'ionic_api.dart';
import 'screens.dart' show PostAttachments;
import 'dialogs.dart';

class ModerationPage extends StatefulWidget {
  const ModerationPage({required this.api, super.key});
  final IonicApi api;
  @override
  State<ModerationPage> createState() => _ModerationPageState();
}

class _ModerationPageState extends State<ModerationPage> {
  List<JsonMap> _items = [];
  String? _cursor, _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await widget.api.reviewQueue(cursor: more ? _cursor : null);
      if (mounted) {
        setState(() {
          _items = {
            for (final i in [
              ...(more ? _items : <JsonMap>[]),
              ...jsonItems(page),
            ])
              i['id']: i,
          }.values.toList();
          _cursor = jsonCursor(page);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = apiErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decide(JsonMap item, String action) async {
    final saved = await showIonicDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DecisionDialog(
        action: action,
        save: (reason) =>
            widget.api.resolveReport('${item['id']}', action, reason),
      ),
    );
    if (saved == true && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Kiểm duyệt nội dung')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: RefreshIndicator(
          onRefresh: () => _load(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Xem bài viết hoặc bình luận được báo cáo trước khi quyết định. Số lượng báo cáo không tự động làm nội dung bị gỡ.',
                ),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                ListTile(
                  title: Text(_error!),
                  trailing: TextButton(
                    onPressed: () => _load(),
                    child: const Text('Thử lại'),
                  ),
                ),
              if (!_busy && _error == null && _items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Chưa có báo cáo cần xử lý.'),
                ),
              for (final item in _items)
                Padding(
                  key: ValueKey(item['id']),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        item['replyId'] == null
                            ? 'Bài viết được báo cáo'
                            : 'Bình luận được báo cáo',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      SelectableText('${item['body']}'),
                      PostAttachments(
                        api: widget.api,
                        attachments: (item['attachments'] as List? ?? [])
                            .map(ApiAttachment.fromJson)
                            .toList(),
                      ),
                      const SizedBox(height: 12),
                      Text('Lý do: ${_reason('${item['reason']}')}'),
                      if ('${item['details'] ?? ''}'.isNotEmpty)
                        Text('Chi tiết: ${item['details']}'),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        children: [
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _decide(item, 'dismiss'),
                            child: const Text('Bỏ qua báo cáo'),
                          ),
                          FilledButton(
                            onPressed: _busy
                                ? null
                                : () => _decide(item, 'remove'),
                            child: const Text('Gỡ nội dung'),
                          ),
                        ],
                      ),
                      const Divider(height: 32),
                    ],
                  ),
                ),
              if (_cursor != null)
                TextButton(
                  onPressed: _busy ? null : () => _load(more: true),
                  child: const Text('Xem thêm báo cáo'),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

String _reason(String reason) => switch (reason) {
  'spam' => 'Spam',
  'harassment' => 'Quấy rối',
  'harmful' => 'Nội dung gây hại',
  'impersonation' => 'Mạo danh',
  _ => 'Lý do khác',
};

class _DecisionDialog extends StatefulWidget {
  const _DecisionDialog({required this.action, required this.save});
  final String action;
  final Future<void> Function(String) save;
  @override
  State<_DecisionDialog> createState() => _DecisionDialogState();
}

class _DecisionDialogState extends State<_DecisionDialog> {
  final _reason = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.save(_reason.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = apiErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(
        widget.action == 'remove' ? 'Gỡ nội dung?' : 'Bỏ qua báo cáo?',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Nhập lý do để lưu cùng quyết định kiểm duyệt.'),
            TextField(
              controller: _reason,
              readOnly: _busy,
              maxLength: 500,
              minLines: 2,
              maxLines: 5,
              onChanged: (_) => setState(() {}),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Hủy'),
        ),
        FilledButton(
          onPressed: _busy || _reason.text.trim().isEmpty ? null : _save,
          child: Text(_busy ? 'Đang lưu…' : 'Xác nhận'),
        ),
      ],
    ),
  );
}

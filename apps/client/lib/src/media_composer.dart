import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';

class IonicMediaDraft {
  const IonicMediaDraft({this.images = const [], this.voice});

  final List<Uint8List> images;
  final Uint8List? voice;

  bool get isEmpty => images.isEmpty && voice == null;
}

class MediaComposerControls extends StatefulWidget {
  const MediaComposerControls({
    required this.onChanged,
    this.onBusyChanged,
    super.key,
  });

  final ValueChanged<IonicMediaDraft> onChanged;
  final ValueChanged<bool>? onBusyChanged;

  @override
  State<MediaComposerControls> createState() => _MediaComposerControlsState();
}

class _MediaComposerControlsState extends State<MediaComposerControls> {
  static const _maximumImages = 4;
  static const _maximumRecordingSeconds = 60;
  static const _maximumPcmBytes = 16000 * 2 * _maximumRecordingSeconds;

  final _picker = ImagePicker();
  final _recorder = AudioRecorder();
  final List<Uint8List> _images = [];
  final List<int> _pcm = [];
  StreamSubscription<Uint8List>? _recordingSubscription;
  Timer? _recordingTimer;
  Uint8List? _voice;
  bool _recording = false;
  bool _processing = false;
  int _recordingSeconds = 0;
  String? _error;

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _recordingSubscription?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  void _notify() => widget.onChanged(
    IonicMediaDraft(images: List.unmodifiable(_images), voice: _voice),
  );

  Future<void> _pickImages() async {
    if (_recording || _processing || _voice != null) return;
    setState(() => _error = null);
    try {
      final picked = await _picker.pickMultiImage(
        limit: _maximumImages - _images.length,
        maxWidth: 2560,
        maxHeight: 2560,
        imageQuality: 94,
      );
      if (picked.isEmpty || !mounted) return;
      setState(() => _processing = true);
      widget.onBusyChanged?.call(true);
      for (final file in picked.take(_maximumImages - _images.length)) {
        final input = await file.readAsBytes();
        final optimized = await compute(_optimizeJpeg, input);
        if (optimized.length > 8 * 1024 * 1024) {
          throw StateError('Một ảnh vẫn vượt quá giới hạn 8 MB sau tối ưu.');
        }
        if (!mounted) return;
        setState(() => _images.add(optimized));
        _notify();
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Không thêm được ảnh: $error');
    } finally {
      if (mounted) {
        setState(() => _processing = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }

  Future<void> _toggleRecording() async {
    if (_processing) return;
    if (_recording) {
      await _stopRecording();
      return;
    }
    if (_images.isNotEmpty) return;
    setState(() => _error = null);
    try {
      if (!await _recorder.hasPermission()) {
        setState(() => _error = 'Cần quyền microphone để ghi voice.');
        return;
      }
      _pcm.clear();
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
        ),
      );
      _recordingSubscription = stream.listen(
        (chunk) {
          if (_pcm.length + chunk.length > _maximumPcmBytes) {
            unawaited(_stopRecording());
            return;
          }
          _pcm.addAll(chunk);
        },
        onError: (Object error) {
          if (mounted) setState(() => _error = 'Không nhận được âm thanh.');
          unawaited(_stopRecording(discard: true));
        },
      );
      setState(() {
        _recording = true;
        _recordingSeconds = 0;
      });
      widget.onBusyChanged?.call(true);
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _recordingSeconds++);
        if (_recordingSeconds >= _maximumRecordingSeconds) {
          unawaited(_stopRecording());
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Không bắt đầu ghi voice được: $error');
      }
    }
  }

  Future<void> _stopRecording({bool discard = false}) async {
    if (!_recording) return;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    setState(() {
      _recording = false;
      _processing = true;
    });
    try {
      await _recorder.stop();
      await _recordingSubscription?.cancel();
      _recordingSubscription = null;
      final usableBytes = _pcm.length - (_pcm.length % 2);
      if (!discard && usableBytes >= 16000 * 2) {
        _voice = _encodeWave(
          Uint8List.fromList(_pcm.take(usableBytes).toList()),
        );
        _notify();
      } else if (!discard && mounted) {
        setState(() => _error = 'Voice cần dài ít nhất một giây.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Không hoàn tất ghi voice: $error');
    } finally {
      _pcm.clear();
      if (mounted) {
        setState(() => _processing = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }

  void _removeImage(int index) {
    setState(() => _images.removeAt(index));
    _notify();
  }

  void _removeVoice() {
    setState(() => _voice = null);
    _notify();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (_images.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var index = 0; index < _images.length; index++)
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        _images[index],
                        width: 84,
                        height: 84,
                        cacheWidth: 168,
                        cacheHeight: 168,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      right: 3,
                      top: 3,
                      child: IconButton.filledTonal(
                        onPressed: () => _removeImage(index),
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Xóa ảnh',
                        icon: const Icon(Icons.close_rounded, size: 16),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      if (_voice != null)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.graphic_eq_rounded),
            title: const Text('Voice đã ghi'),
            subtitle: Text('${_voice!.lengthInBytes ~/ 32000} giây'),
            trailing: IconButton(
              tooltip: 'Xóa voice',
              onPressed: _removeVoice,
              icon: const Icon(Icons.close_rounded),
            ),
          ),
        ),
      Row(
        children: [
          IconButton(
            tooltip: 'Thêm ảnh',
            onPressed:
                _processing ||
                    _recording ||
                    _voice != null ||
                    _images.length >= _maximumImages
                ? null
                : _pickImages,
            icon: const Icon(Icons.image_outlined),
          ),
          IconButton(
            tooltip: _recording ? 'Dừng ghi voice' : 'Ghi voice',
            onPressed: _processing || _images.isNotEmpty || _voice != null
                ? null
                : _toggleRecording,
            icon: Icon(
              _recording ? Icons.stop_circle_rounded : Icons.mic_none_rounded,
              color: _recording ? Theme.of(context).colorScheme.error : null,
            ),
          ),
          if (_recording)
            Text('Đang ghi  $_recordingSeconds/$_maximumRecordingSeconds giây'),
          if (_processing)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          const Spacer(),
          Text(
            _voice != null
                ? '1 voice'
                : _images.isEmpty
                ? 'Thêm ảnh hoặc voice'
                : '${_images.length}/$_maximumImages ảnh',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ],
  );
}

Uint8List _optimizeJpeg(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw StateError('Tệp không phải ảnh được hỗ trợ.');
  final oriented = img.bakeOrientation(decoded);
  final resized = oriented.width > 2048 || oriented.height > 2048
      ? img.copyResize(
          oriented,
          width: oriented.width >= oriented.height ? 2048 : null,
          height: oriented.height > oriented.width ? 2048 : null,
        )
      : oriented;
  return Uint8List.fromList(img.encodeJpg(resized, quality: 86));
}

Uint8List _encodeWave(Uint8List pcm) {
  final result = Uint8List(44 + pcm.length);
  final data = ByteData.sublistView(result);
  void text(int start, String value) {
    result.setRange(start, start + value.length, value.codeUnits);
  }

  text(0, 'RIFF');
  data.setUint32(4, result.length - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, pcm.length, Endian.little);
  result.setRange(44, result.length, pcm);
  return result;
}

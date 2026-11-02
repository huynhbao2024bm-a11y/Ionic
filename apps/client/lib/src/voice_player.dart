// just_audio exposes its in-memory source API as experimental.
// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

class VoicePlayer extends StatefulWidget {
  const VoicePlayer({required this.load, required this.durationMs, super.key});
  final Future<Uint8List> Function() load;
  final int durationMs;
  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> with WidgetsBindingObserver {
  static AudioPlayer? _active;
  final _player = AudioPlayer();
  bool _loading = false;
  bool _loaded = false;
  bool _disposed = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_player.pause());
  }

  Future<void> _toggle() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!_loaded) {
        final bytes = await widget.load();
        if (_disposed) return;
        await _player
            .setAudioSource(_WaveSource(bytes))
            .timeout(const Duration(seconds: 20));
        _loaded = true;
      }
      if (_disposed) return;
      if (_player.playing &&
          _player.processingState != ProcessingState.completed) {
        await _player.pause();
      } else {
        if (_active != null && _active != _player) await _active!.pause();
        _active = _player;
        if (_player.processingState == ProcessingState.completed) {
          await _player.seek(Duration.zero);
        }
        if (_disposed ||
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.paused) {
          return;
        }
        unawaited(
          _player.play().catchError((Object _) {
            if (mounted) {
              setState(() {
                _loaded = false;
                _error = 'Không phát được âm thanh. Nhấn để thử lại.';
              });
            }
          }),
        );
      }
    } catch (_) {
      _loaded = false;
      if (mounted) {
        setState(() => _error = 'Không tải được âm thanh. Nhấn để thử lại.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    if (_active == _player) _active = null;
    unawaited(_player.dispose());
    super.dispose();
  }

  String _time(int ms) =>
      '${ms ~/ 60000}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) => StreamBuilder<PlayerState>(
    stream: _player.playerStateStream,
    builder: (context, state) => Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            IconButton(
              tooltip:
                  state.data?.playing == true &&
                      state.data?.processingState != ProcessingState.completed
                  ? 'Tạm dừng âm thanh'
                  : 'Phát âm thanh',
              onPressed: _loading ? null : _toggle,
              icon: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      state.data?.playing == true &&
                              state.data?.processingState !=
                                  ProcessingState.completed
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
            ),
            Expanded(
              child: _error != null
                  ? Text(_error!)
                  : StreamBuilder<Duration>(
                      stream: _player.positionStream,
                      builder: (context, position) {
                        final ms = (position.data?.inMilliseconds ?? 0).clamp(
                          0,
                          widget.durationMs,
                        );
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Slider(
                              value: ms.toDouble(),
                              max: widget.durationMs.toDouble().clamp(
                                1,
                                double.infinity,
                              ),
                              label: _time(ms),
                              onChanged: _loaded
                                  ? (v) => _player.seek(
                                      Duration(milliseconds: v.round()),
                                    )
                                  : null,
                            ),
                            Text(
                              '${_time(ms)} / ${_time(widget.durationMs)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _WaveSource extends StreamAudioSource {
  _WaveSource(this.bytes);
  final Uint8List bytes;
  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = (start ?? 0).clamp(0, bytes.length);
    final to = (end ?? bytes.length).clamp(from, bytes.length);
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: to - from,
      offset: from,
      stream: Stream.value(bytes.sublist(from, to)),
      contentType: 'audio/wav',
      rangeRequestsSupported: true,
    );
  }
}

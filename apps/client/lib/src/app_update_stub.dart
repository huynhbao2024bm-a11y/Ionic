import 'app_update_manifest.dart';

class AndroidUpdates {
  bool get supported => false;
  Future<AndroidRelease?> check() async => null;
  Future<bool> unmetered() async => false;
  Future<String> download(
    AndroidRelease release,
    void Function(double) progress,
  ) async => throw UnsupportedError('Android only');
  Future<String> install(String path) async =>
      throw UnsupportedError('Android only');
  Future<bool> canInstall() async => false;
  void cancel() {}
}

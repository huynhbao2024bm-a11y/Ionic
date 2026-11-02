import 'package:flutter/foundation.dart';

/// View state only. Scroll position never leaves this process.
class HomeSearchController extends ChangeNotifier {
  bool _compact = false;
  bool get compact => _compact;
  VoidCallback? open;
  void setCompact(bool value) {
    if (value == _compact) return;
    _compact = value;
    notifyListeners();
  }
}

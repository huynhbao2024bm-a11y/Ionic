/// Registration rules. Login/lookups retain syntax compatibility with accounts.
String? registrationHandleError(String handle) {
  if (!RegExp(r'^[a-z0-9_-]{3,24}$').hasMatch(handle)) {
    return 'Handle must use 3–24 lowercase ASCII letters, numbers, hyphens, or underscores.';
  }
  if (handle.contains('admin')) return 'This handle is reserved.';
  if (RegExp(r'[0-9]').allMatches(handle).length < 3) {
    return 'Handle must contain at least 3 digits.';
  }
  return null;
}

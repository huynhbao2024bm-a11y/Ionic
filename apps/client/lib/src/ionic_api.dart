import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'http_client_factory.dart';

typedef JsonMap = Map<String, Object?>;

JsonMap asJsonMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.map((key, value) => MapEntry('$key', value));
  return <String, Object?>{};
}

List<JsonMap> jsonItems(Object? value) {
  final items = asJsonMap(value)['items'];
  if (items is! List) return const [];
  return items.map(asJsonMap).toList(growable: false);
}

String? jsonCursor(Object? value) {
  final cursor = asJsonMap(value)['nextCursor'];
  return cursor is String && cursor.isNotEmpty ? cursor : null;
}

class IonicApiException implements Exception {
  const IonicApiException(
    this.statusCode,
    this.message, {
    this.code,
    this.retryAfterSeconds,
  });

  final int statusCode;
  final String message;
  final String? code;
  final int? retryAfterSeconds;

  @override
  String toString() => message;
}

String apiErrorText(Object error) {
  if (error is IonicApiException) {
    if (error.code == 'MEDIA_QUOTA_ACCOUNT') {
      return 'Tài khoản đã đạt giới hạn lưu trữ bản thử. Hãy xóa bớt bài hoặc tệp không cần thiết.';
    }
    if (error.code == 'MEDIA_QUOTA_TOTAL') {
      return 'Kho lưu trữ bản thử gần đầy. Chưa thể tải thêm tệp.';
    }
    if (error.code == 'MEDIA_CLEANUP_PENDING') {
      return 'Kho lưu trữ đang dọn tệp cũ. Vui lòng thử tải lên sau.';
    }
    final specific = switch (error.code) {
      'HANDLE_RESERVED' => 'Tên tài khoản này được dành riêng.',
      'HANDLE_DIGITS_REQUIRED' => 'Tên tài khoản cần ít nhất 3 chữ số.',
      'HANDLE_INVALID' =>
        'Dùng 3–24 ký tự chữ, số hoặc dấu gạch dưới cho tên tài khoản.',
      'DISPLAY_NAME_INVALID' => 'Tên hiển thị cần từ 1 đến 48 ký tự.',
      'PASSWORD_INVALID' => 'Mật khẩu cần từ 12 đến 128 ký tự.',
      'SIGNUP_DISABLED' => 'Máy chủ đang tạm dừng tạo tài khoản mới.',
      'SERVER_WAKING' =>
        'Máy chủ chưa sẵn sàng. Vui lòng đợi khoảng một phút rồi thử lại.',
      _ => null,
    };
    if (specific != null) return specific;
    if (error.code == 'LINK_NOT_ALLOWED') {
      return 'Không được thêm liên kết. Hãy xóa địa chỉ trang web và thử lại.';
    }
    switch (error.statusCode) {
      case 0:
        return 'Chưa kết nối được. Vui lòng thử lại sau ít giây.';
      case 400:
        return 'Dữ liệu chưa hợp lệ hoặc thao tác chưa được hỗ trợ.';
      case 401:
        return 'Phiên đăng nhập đã hết hạn. Hãy đăng nhập lại.';
      case 403:
        return 'Máy chủ từ chối thao tác này.';
      case 404:
        return 'Không tìm thấy tài khoản hoặc nội dung.';
      case 409:
        return 'Tên tài khoản này đã được sử dụng.';
      case 429:
        return error.retryAfterSeconds == null
            ? 'Có quá nhiều yêu cầu. Vui lòng đợi một lát.'
            : 'Có quá nhiều yêu cầu. Thử lại sau ${error.retryAfterSeconds} giây.';
      case 500:
      case 502:
      case 504:
        return 'Máy chủ chưa hoàn tất yêu cầu. Vui lòng thử lại; dữ liệu nhập vẫn được giữ.';
      case 503:
        if (error.code == 'FEED_BUSY') {
          return 'Bảng tin đang cập nhật. Vui lòng thử lại.';
        }
        return 'Máy chủ tạm thời chưa xử lý được. Vui lòng thử lại.';
    }
    return error.message;
  }
  return 'Không thể hoàn tất thao tác. Dữ liệu chưa được lưu.';
}

bool samePostSnapshot(FeedPost a, FeedPost b) =>
    a.body == b.body &&
    a.likeCount == b.likeCount &&
    a.replyCount == b.replyCount &&
    a.liked == b.liked &&
    a.saved == b.saved &&
    a.authorAvatarId == b.authorAvatarId &&
    a.displayName == b.displayName &&
    a.attachments.map((v) => v.id).join(',') ==
        b.attachments.map((v) => v.id).join(',');
FeedPost mergePostSnapshot(FeedPost old, FeedPost current) => FeedPost(
  id: current.id,
  authorId: current.authorId,
  handle: current.handle,
  displayName: current.displayName,
  body: current.body,
  createdAt: current.createdAt,
  likeCount: current.likeCount,
  replyCount: current.replyCount,
  liked: current.liked,
  saved: current.saved,
  attachments: current.attachments,
  kind: current.kind,
  mimeType: current.mimeType,
  authorAvatarId: current.authorAvatarId,
  receiptId: old.receiptId,
);

class ApiUser {
  const ApiUser({
    required this.id,
    required this.handle,
    required this.displayName,
    this.avatarMediaId,
  });

  final String id;
  final String handle;
  final String displayName;
  final String? avatarMediaId;

  factory ApiUser.fromJson(Object? value) {
    final map = asJsonMap(value);
    return ApiUser(
      id: '${map['id'] ?? ''}',
      handle: '${map['handle'] ?? ''}',
      displayName: '${map['displayName'] ?? map['handle'] ?? ''}',
      avatarMediaId: map['avatarMediaId'] as String?,
    );
  }
}

class FeedPost {
  const FeedPost({
    required this.id,
    required this.authorId,
    required this.handle,
    required this.displayName,
    required this.body,
    required this.createdAt,
    required this.likeCount,
    required this.replyCount,
    required this.liked,
    required this.saved,
    this.attachments = const [],
    this.kind = 'text',
    this.mimeType,
    this.receiptId,
    this.authorAvatarId,
  });

  final String id;
  final String authorId;
  final String handle;
  final String displayName;
  final String body;
  final String createdAt;
  final int likeCount;
  final int replyCount;
  final bool liked;
  final bool saved;
  final List<ApiAttachment> attachments;
  final String kind;
  final String? mimeType;
  final String? receiptId;
  final String? authorAvatarId;

  factory FeedPost.fromJson(Object? value) {
    final map = asJsonMap(value);
    return FeedPost(
      id: '${map['id'] ?? ''}',
      authorId: '${map['authorId'] ?? ''}',
      handle: '${map['authorHandle'] ?? ''}',
      displayName: '${map['authorDisplayName'] ?? 'Tài khoản'}',
      body: '${map['body'] ?? map['caption'] ?? ''}',
      createdAt: '${map['createdAt'] ?? ''}',
      likeCount: (map['likeCount'] as num?)?.toInt() ?? 0,
      replyCount: (map['replyCount'] as num?)?.toInt() ?? 0,
      liked: map['liked'] == true,
      saved: map['saved'] == true,
      attachments: map['attachments'] is List
          ? (map['attachments'] as List)
                .map(ApiAttachment.fromJson)
                .toList(growable: false)
          : const [],
      kind: '${map['kind'] ?? 'text'}',
      mimeType: map['mimeType'] as String?,
      receiptId: map['receiptId'] as String?,
      authorAvatarId: map['authorAvatarId'] as String?,
    );
  }
}

class ApiAttachment {
  const ApiAttachment({
    required this.id,
    required this.mediaType,
    required this.mimeType,
    required this.byteSize,
    this.width,
    this.height,
    this.durationMs,
  });

  final String id;
  final String mediaType;
  final String mimeType;
  final int byteSize;
  final int? width;
  final int? height;
  final int? durationMs;

  factory ApiAttachment.fromJson(Object? value) {
    final map = asJsonMap(value);
    return ApiAttachment(
      id: '${map['id'] ?? ''}',
      mediaType: '${map['mediaType'] ?? ''}',
      mimeType: '${map['mimeType'] ?? ''}',
      byteSize: (map['byteSize'] as num?)?.toInt() ?? 0,
      width: (map['width'] as num?)?.toInt(),
      height: (map['height'] as num?)?.toInt(),
      durationMs: (map['durationMs'] as num?)?.toInt(),
    );
  }
}

class ApiProfile {
  const ApiProfile({
    required this.handle,
    required this.displayName,
    this.avatarMediaId,
    required this.bio,
    required this.followerCount,
    required this.followingCount,
    required this.postCount,
    required this.isFollowing,
    required this.isMuted,
    required this.isSelf,
  });

  final String handle;
  final String displayName;
  final String? avatarMediaId;
  final String bio;
  final int followerCount;
  final int followingCount;
  final int postCount;
  final bool isFollowing;
  final bool isMuted;
  final bool isSelf;

  factory ApiProfile.fromJson(Object? value) {
    final map = asJsonMap(value);
    return ApiProfile(
      handle: '${map['handle'] ?? ''}',
      displayName: '${map['displayName'] ?? 'Tài khoản'}',
      avatarMediaId: map['avatarMediaId'] as String?,
      bio: '${map['bio'] ?? ''}',
      followerCount: (map['followerCount'] as num?)?.toInt() ?? 0,
      followingCount: (map['followingCount'] as num?)?.toInt() ?? 0,
      postCount: (map['postCount'] as num?)?.toInt() ?? 0,
      isFollowing: map['isFollowing'] == true,
      isMuted: map['isMuted'] == true,
      isSelf: map['isSelf'] == true,
    );
  }
}

class ApiConversation {
  const ApiConversation({
    required this.id,
    required this.partnerHandle,
    required this.partnerDisplayName,
    required this.lastMessage,
    required this.updatedAt,
    this.unreadCount = 0,
    this.partnerAvatarId,
  });

  final String id;
  final String partnerHandle;
  final String partnerDisplayName;
  final String lastMessage;
  final String updatedAt;
  final int unreadCount;
  final String? partnerAvatarId;

  factory ApiConversation.fromJson(Object? value) {
    final map = asJsonMap(value);
    return ApiConversation(
      id: '${map['id'] ?? ''}',
      partnerHandle: '${map['partnerHandle'] ?? ''}',
      partnerDisplayName: '${map['partnerDisplayName'] ?? 'Tài khoản'}',
      lastMessage: '${map['lastMessage'] ?? ''}',
      updatedAt: '${map['updatedAt'] ?? ''}',
      unreadCount: (map['unreadCount'] as num?)?.toInt() ?? 0,
      partnerAvatarId: map['partnerAvatarId'] as String?,
    );
  }
}

class ApiMessage {
  const ApiMessage({
    required this.id,
    required this.senderId,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final String senderId;
  final String body;
  final String createdAt;

  factory ApiMessage.fromJson(Object? value) {
    final map = asJsonMap(value);
    return ApiMessage(
      id: '${map['id'] ?? ''}',
      senderId: '${map['senderId'] ?? ''}',
      body: '${map['body'] ?? ''}',
      createdAt: '${map['createdAt'] ?? ''}',
    );
  }
}

class ApiVideo {
  const ApiVideo({
    required this.id,
    required this.caption,
    required this.mimeType,
    required this.state,
    required this.createdAt,
  });

  final String id;
  final String caption;
  final String mimeType;
  final String state;
  final String createdAt;

  factory ApiVideo.fromJson(Object? value) {
    final map = asJsonMap(value);
    return ApiVideo(
      id: '${map['id'] ?? ''}',
      caption: '${map['caption'] ?? ''}',
      mimeType: '${map['mimeType'] ?? 'video/mp4'}',
      state: '${map['state'] ?? 'pending_review'}',
      createdAt: '${map['createdAt'] ?? ''}',
    );
  }
}

class IonicApi {
  IonicApi({http.Client? client, String? baseUrl})
    : _client = client ?? createHttpClient(),
      _baseUrl =
          baseUrl ??
          const String.fromEnvironment('API_BASE_URL', defaultValue: '/api/v1');

  final http.Client _client;
  final String _baseUrl;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(_baseUrl);
    final root = base.hasScheme ? base : Uri.base.resolveUri(base);
    final normalized = root.toString().endsWith('/')
        ? root.toString()
        : '${root.toString()}/';
    final url = Uri.parse(
      '$normalized${path.replaceFirst(RegExp(r'^/+'), '')}',
    );
    return query == null ? url : url.replace(queryParameters: query);
  }

  Future<Object?> _request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    Map<String, String>? headers,
  }) async {
    final request = http.Request(method, _uri(path, query))
      ..headers.addAll(headers ?? const {})
      ..headers.putIfAbsent('Accept', () => 'application/json');
    if (body != null) {
      request.headers.putIfAbsent(
        'Content-Type',
        () => 'application/json; charset=utf-8',
      );
      request.body = jsonEncode(body);
    }
    try {
      final response = await (() async => http.Response.fromStream(
        await _client.send(request),
      ))().timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _exception(
          response.statusCode,
          response.body,
          retryAfter: response.headers['retry-after'],
        );
      }
      if (response.body.isEmpty) return null;
      return jsonDecode(response.body);
    } on IonicApiException {
      rethrow;
    } catch (_) {
      throw const IonicApiException(0, 'Không kết nối được máy chủ.');
    }
  }

  IonicApiException _exception(int status, String body, {String? retryAfter}) {
    var message = 'Yêu cầu thất bại.';
    String? code;
    try {
      final decoded = asJsonMap(jsonDecode(body));
      final candidate = decoded['message'];
      if (decoded['code'] is String) code = decoded['code'] as String;
      if (candidate is String) message = candidate;
      if (candidate is List && candidate.isNotEmpty) {
        message = candidate.join(' ');
      }
    } catch (_) {
      // Keep the stable local message when the server body isn't JSON.
    }
    final seconds = int.tryParse(retryAfter ?? '');
    return IonicApiException(
      status,
      message,
      code: code,
      retryAfterSeconds: seconds != null && seconds > 0 && seconds <= 3600
          ? seconds
          : null,
    );
  }

  Future<void> prepareAuthentication() async {
    // Retry only a safe readiness GET. Never repeat an uncertain auth write.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (asJsonMap(await _request('GET', 'health/ready'))['status'] ==
            'ready') {
          return;
        }
      } on IonicApiException catch (e) {
        if (!{0, 502, 503, 504}.contains(e.statusCode)) rethrow;
      }
      if (attempt < 2) await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw const IonicApiException(
      0,
      'Server is not ready.',
      code: 'SERVER_WAKING',
    );
  }

  Future<JsonMap> claimHeartbeat(String? token) async => asJsonMap(
    await _request(
      'POST',
      'health/heartbeat-lease',
      body: {'leaseToken': token},
    ),
  );
  Future<void> heartbeat(String? token) async =>
      _request('POST', 'health/heartbeat', body: {'leaseToken': token});
  Future<void> releaseHeartbeat(String? token) async =>
      _request('POST', 'health/heartbeat-release', body: {'leaseToken': token});

  final _mediaInFlight = <String, Future<Uint8List>>{};
  int _mediaEpoch = 0;
  String? _mediaAccount;
  Future<ApiUser> _account(Object? value) async {
    final user = ApiUser.fromJson(asJsonMap(value)['user']);
    if (_mediaAccount != user.id) {
      _mediaAccount = user.id;
      _mediaEpoch++;
      _mediaInFlight.clear();
    }
    return user;
  }

  Future<ApiUser> currentUser() async =>
      _account(await _request('GET', 'auth/me'));
  Future<ApiUser> register(
    String handle,
    String displayName,
    String password,
  ) async => _account(
    await _request(
      'POST',
      'auth/register',
      body: {
        'handle': handle,
        'displayName': displayName,
        'password': password,
      },
    ),
  );
  Future<ApiUser> login(String handle, String password) async => _account(
    await _request(
      'POST',
      'auth/login',
      body: {'handle': handle, 'password': password},
    ),
  );
  Future<void> logout() async {
    await _request('POST', 'auth/logout', body: const {});
    _mediaAccount = null;
    _mediaEpoch++;
    _mediaInFlight.clear();
  }

  Future<JsonMap> accountSettings() async =>
      asJsonMap(await _request('GET', 'auth/settings'));
  Future<JsonMap> exportAccount() async =>
      asJsonMap(await _request('GET', 'auth/export'));
  Future<JsonMap> updateAccountSettings(JsonMap changes) async =>
      asJsonMap(await _request('PATCH', 'auth/settings', body: changes));
  Future<List<JsonMap>> sessions() async =>
      jsonItems(await _request('GET', 'auth/sessions'));
  Future<void> revokeSession(String id) async =>
      _request('DELETE', 'auth/sessions/${Uri.encodeComponent(id)}');
  Future<void> logoutAll() async =>
      _request('POST', 'auth/logout-all', body: const {});
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async => _request(
    'POST',
    'auth/password',
    body: {'currentPassword': currentPassword, 'newPassword': newPassword},
  );
  Future<String> recoveryCode(String currentPassword) async =>
      '${asJsonMap(await _request('POST', 'auth/recovery-code', body: {'currentPassword': currentPassword}))['recoveryCode']}';
  Future<void> recover(String handle, String code, String password) async =>
      _request(
        'POST',
        'auth/recover',
        body: {
          'handle': handle.trim().toLowerCase(),
          'recoveryCode': code.trim(),
          'newPassword': password,
        },
      );
  Future<void> deleteAccount(String password) async => _request(
    'POST',
    'auth/delete-account',
    body: {'currentPassword': password, 'confirmation': 'DELETE'},
  );
  Future<void> editPost(String id, String body) async => _request(
    'PATCH',
    'posts/${Uri.encodeComponent(id)}',
    body: {'body': body},
  );
  Future<void> deletePost(String id) async =>
      _request('DELETE', 'posts/${Uri.encodeComponent(id)}');
  Future<FeedPost> post(String id) async => FeedPost.fromJson(
    await _request('GET', 'posts/${Uri.encodeComponent(id)}'),
  );
  Future<List<FeedPost>> syncReplies(String id, List<String> ids) async =>
      ids.isEmpty
      ? []
      : jsonItems(
          await _request(
            'POST',
            'posts/${Uri.encodeComponent(id)}/replies/sync',
            body: {'ids': ids},
          ),
        ).map(FeedPost.fromJson).toList();
  Future<List<FeedPost>> syncPosts(List<String> ids) async => ids.isEmpty
      ? []
      : jsonItems(
          await _request('POST', 'posts/sync', body: {'ids': ids}),
        ).map(FeedPost.fromJson).toList();
  Future<bool> reviewerPermission() async =>
      asJsonMap(await _request('GET', 'reports/reviewer'))['enabled'] == true;
  Future<JsonMap> reviewQueue({String? cursor}) async => asJsonMap(
    await _request(
      'GET',
      'reports/queue',
      query: cursor == null ? null : {'cursor': cursor},
    ),
  );
  Future<void> resolveReport(String id, String action, String reason) async =>
      _request(
        'POST',
        'reports/${Uri.encodeComponent(id)}/resolve',
        body: {'action': action, 'reason': reason},
      );
  Future<void> reportReply(
    String postId,
    String replyId,
    String reason,
    String details,
  ) async => _request(
    'POST',
    'reports',
    body: {
      'contentId': postId,
      'replyId': replyId,
      'reason': reason,
      'details': details,
    },
  );
  Future<FeedPage> savedPosts({String? cursor}) =>
      _feed('posts/saved', cursor: cursor);

  Future<FeedPage> forYou({String? cursor}) =>
      _feed('feed/for-you', cursor: cursor);
  Future<FeedPage> publicPosts({String? cursor}) =>
      _feed('posts/public', cursor: cursor);
  Future<FeedPage> following({String? cursor}) =>
      _feed('posts/following', cursor: cursor);
  Future<FeedPage> searchPosts(String query, {String? cursor}) =>
      _feed('posts/search', cursor: cursor, extra: {'q': query});
  Future<FeedPage> profilePosts(String handle, {String? cursor}) => _feed(
    'posts/author/${Uri.encodeComponent(_plainHandle(handle))}',
    cursor: cursor,
  );
  Future<FeedPage> myPosts({String? cursor}) =>
      _feed('posts/mine', limit: 50, cursor: cursor);

  Future<FeedPage> _feed(
    String path, {
    String? cursor,
    int limit = 20,
    Map<String, String>? extra,
  }) async {
    final query = <String, String>{'limit': '$limit', ...?extra};
    if (cursor != null) query['cursor'] = cursor;
    final value = await _request('GET', path, query: query);
    return FeedPage(
      jsonItems(value).map(FeedPost.fromJson).toList(growable: false),
      jsonCursor(value),
    );
  }

  Future<FeedPost> createPost(
    String body, {
    List<String> attachmentIds = const [],
    String? clientPublishId,
  }) async => FeedPost.fromJson(
    await _request(
      'POST',
      'posts',
      body: {
        'body': body,
        'attachmentIds': attachmentIds,
        'clientPublishId': ?clientPublishId,
      },
    ),
  );
  Future<JsonMap> setLike(String id, bool liked) async => asJsonMap(
    await _request(
      liked ? 'POST' : 'DELETE',
      'posts/${Uri.encodeComponent(id)}/like',
      body: liked ? const {} : null,
    ),
  );
  Future<JsonMap> setSaved(String id, bool saved) async => asJsonMap(
    await _request(
      saved ? 'POST' : 'DELETE',
      'posts/${Uri.encodeComponent(id)}/save',
      body: saved ? const {} : null,
    ),
  );
  Future<FeedPage> replies(String id, {String? cursor}) async {
    final value = await _request(
      'GET',
      'posts/${Uri.encodeComponent(id)}/replies',
      query: {'limit': '20', 'cursor': ?cursor},
    );
    return FeedPage(
      jsonItems(value).map(FeedPost.fromJson).toList(growable: false),
      jsonCursor(value),
    );
  }

  Future<FeedPost> createReply(
    String id,
    String body, {
    List<String> attachmentIds = const [],
    String? clientPublishId,
  }) async => FeedPost.fromJson(
    await _request(
      'POST',
      'posts/${Uri.encodeComponent(id)}/replies',
      body: {
        'body': body,
        'attachmentIds': attachmentIds,
        'clientPublishId': ?clientPublishId,
      },
    ),
  );

  Future<ApiAttachment> uploadAttachment(
    Uint8List bytes, {
    required String mediaType,
  }) async {
    if ((mediaType == 'image' && bytes.lengthInBytes > 8 * 1024 * 1024) ||
        (mediaType == 'audio' && bytes.lengthInBytes > 2 * 1024 * 1024) ||
        (mediaType != 'image' && mediaType != 'audio')) {
      throw const IonicApiException(413, 'Tệp đính kèm vượt quá giới hạn.');
    }
    final request = http.Request('POST', _uri('media/upload'))
      ..headers['Content-Type'] = 'application/octet-stream'
      ..headers['X-Ionic-Media-Type'] = mediaType
      ..headers['Accept'] = 'application/json'
      ..bodyBytes = bytes;
    try {
      final response = await (() async => http.Response.fromStream(
        await _client.send(request),
      ))().timeout(const Duration(seconds: 90));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _exception(response.statusCode, response.body);
      }
      return ApiAttachment.fromJson(jsonDecode(response.body));
    } on IonicApiException {
      rethrow;
    } catch (_) {
      throw const IonicApiException(0, 'Không tải được tệp đính kèm.');
    }
  }

  Future<void> deleteStagedAttachment(String id) async =>
      _request('DELETE', 'media/${Uri.encodeComponent(id)}/staged');

  Future<Uint8List> mediaBytes(String id) {
    final key = '$_mediaEpoch:$id';
    final pending = _mediaInFlight[key];
    if (pending != null) return pending;
    final work = _readMediaBytes(id);
    _mediaInFlight[key] = work;
    // Coalesce concurrent loads only. Every later read rechecks server ACL.
    unawaited(
      work.then<void>(
        (_) {
          if (identical(_mediaInFlight[key], work)) _mediaInFlight.remove(key);
        },
        onError: (Object _, StackTrace _) {
          if (identical(_mediaInFlight[key], work)) _mediaInFlight.remove(key);
        },
      ),
    );
    return work;
  }

  Future<Uint8List> _readMediaBytes(String id) async {
    final request = http.Request(
      'GET',
      _uri('media/${Uri.encodeComponent(id)}/file'),
    )..headers['Accept'] = '*/*';
    try {
      final response = await (() async => http.Response.fromStream(
        await _client.send(request),
      ))().timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _exception(response.statusCode, response.body);
      }
      return response.bodyBytes;
    } on IonicApiException {
      rethrow;
    } catch (_) {
      throw const IonicApiException(0, 'Không tải được nội dung đính kèm.');
    }
  }

  Future<ApiProfile> profile(String handle) async {
    final result = await _request(
      'GET',
      'profiles/${Uri.encodeComponent(_plainHandle(handle))}',
    );
    return ApiProfile.fromJson(asJsonMap(result)['profile']);
  }

  Future<void> setAvatar(String? id) async =>
      _request('PUT', 'profiles/me/avatar', body: {'mediaId': id});

  Future<JsonMap> connections(
    String handle,
    String kind, {
    String? cursor,
  }) async => asJsonMap(
    await _request(
      'GET',
      'profiles/${Uri.encodeComponent(_plainHandle(handle))}/$kind',
      query: {'cursor': ?cursor},
    ),
  );
  Future<void> removeFollower(String handle) async => _request(
    'DELETE',
    'profiles/me/followers/${Uri.encodeComponent(_plainHandle(handle))}',
  );

  Future<ApiUser> updateProfile(String displayName, String bio) async =>
      _account(
        await _request(
          'PATCH',
          'profiles/me',
          body: {'displayName': displayName, 'bio': bio},
        ),
      );
  Future<List<JsonMap>> searchProfiles(String query) async =>
      jsonItems(await _request('GET', 'profiles/search', query: {'q': query}));
  Future<void> follow(String handle, bool follow) async {
    await _request(
      follow ? 'POST' : 'DELETE',
      'profiles/${Uri.encodeComponent(_plainHandle(handle))}/follow',
      body: follow ? const {} : null,
    );
  }

  Future<void> mute(String handle, bool muted) async {
    await _request(
      muted ? 'POST' : 'DELETE',
      'profiles/${Uri.encodeComponent(_plainHandle(handle))}/mute',
      body: muted ? const {} : null,
    );
  }

  Future<void> block(String handle, bool blocked) async {
    await _request(
      blocked ? 'POST' : 'DELETE',
      'profiles/${Uri.encodeComponent(_plainHandle(handle))}/block',
      body: blocked ? const {} : null,
    );
  }

  Future<List<JsonMap>> blockedProfiles() async =>
      jsonItems(await _request('GET', 'profiles/blocked'));
  Future<List<JsonMap>> mutedProfiles() async =>
      jsonItems(await _request('GET', 'profiles/muted'));

  Future<void> setPreference(String id, String preference) async => _request(
    'POST',
    'feed/${Uri.encodeComponent(id)}/preference',
    body: {'preference': preference},
  );
  Future<void> hidePost(String id) async =>
      _request('POST', 'feed/${Uri.encodeComponent(id)}/hide', body: const {});
  Future<List<JsonMap>> hiddenPosts() async =>
      jsonItems(await _request('GET', 'feed/hidden'));
  Future<void> unhidePost(String id) async =>
      _request('DELETE', 'feed/${Uri.encodeComponent(id)}/hide');
  Future<void> recordVideoSignal(String id, String kind) async => _request(
    'POST',
    'feed/${Uri.encodeComponent(id)}/video-signal',
    body: {'eventId': newClientMessageId(), 'kind': kind},
  );
  Future<bool> feedPaused() async =>
      asJsonMap(await _request('GET', 'feed/settings'))['paused'] == true;
  Future<bool> recordAttention(List<Map<String, String>> items) async =>
      asJsonMap(
        await _request('POST', 'feed/attention', body: {'items': items}),
      )['status'] !=
      'paused';
  Future<void> pauseFeed(bool paused) async =>
      _request('PATCH', 'feed/settings', body: {'paused': paused});
  Future<void> resetFeed() async =>
      _request('POST', 'feed/reset', body: const {});
  Future<void> reportPost(String id, String reason, String details) async =>
      _request(
        'POST',
        'reports',
        body: {'contentId': id, 'reason': reason, 'details': details},
      );

  Future<List<ApiConversation>> conversations() async => jsonItems(
    await _request('GET', 'messages/conversations'),
  ).map(ApiConversation.fromJson).toList(growable: false);
  Future<ApiConversation> startConversation(String handle) async =>
      ApiConversation.fromJson(
        asJsonMap(
          await _request(
            'POST',
            'messages/conversations',
            body: {'handle': _plainHandle(handle)},
          ),
        )['conversation'],
      );
  Future<MessagePage> messages(String conversationId, {String? cursor}) async {
    final query = <String, String>{'limit': '50'};
    if (cursor != null) query['cursor'] = cursor;
    final value = await _request(
      'GET',
      'messages/conversations/${Uri.encodeComponent(conversationId)}',
      query: query,
    );
    return MessagePage(
      jsonItems(value).map(ApiMessage.fromJson).toList(growable: false),
      jsonCursor(value),
      partnerReadAt: asJsonMap(value)['partnerReadAt'] as String?,
      partnerReadMessageId: asJsonMap(value)['partnerReadMessageId'] as String?,
    );
  }

  Future<void> markConversationRead(String id, String messageId) async =>
      _request(
        'POST',
        'messages/conversations/${Uri.encodeComponent(id)}/read',
        body: {'lastMessageId': messageId},
      );

  Future<ApiMessage> sendMessage(
    String conversationId,
    String body,
    String clientMessageId,
  ) async => ApiMessage.fromJson(
    await _request(
      'POST',
      'messages/conversations/${Uri.encodeComponent(conversationId)}',
      body: {'body': body, 'clientMessageId': clientMessageId},
    ),
  );

  Future<List<ApiVideo>> videos() async => jsonItems(
    await _request('GET', 'videos'),
  ).map(ApiVideo.fromJson).toList(growable: false);
  Future<ApiVideo> uploadVideo(
    Uint8List bytes,
    String mimeType,
    String caption,
  ) async {
    if (bytes.lengthInBytes > 60 * 1024 * 1024) {
      throw const IonicApiException(400, 'Video vượt quá giới hạn 60 MB.');
    }
    final captionHex = utf8
        .encode(caption)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    final request = http.Request('POST', _uri('videos/upload'))
      ..headers['Content-Type'] = mimeType
      ..headers['X-Ionic-Caption'] = captionHex
      ..headers['Accept'] = 'application/json'
      ..bodyBytes = bytes;
    try {
      final response = await http.Response.fromStream(
        await _client.send(request),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _exception(response.statusCode, response.body);
      }
      return ApiVideo.fromJson(jsonDecode(response.body));
    } on IonicApiException {
      rethrow;
    } catch (_) {
      throw const IonicApiException(0, 'Không tải được video.');
    }
  }

  Uri videoUrl(String id) => _uri('videos/${Uri.encodeComponent(id)}/file');

  static String _plainHandle(String value) =>
      value.replaceFirst(RegExp(r'^@'), '');

  static String newClientMessageId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((item) => item.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

class FeedPage {
  const FeedPage(this.items, this.nextCursor);
  final List<FeedPost> items;
  final String? nextCursor;
}

class MessagePage {
  const MessagePage(
    this.items,
    this.nextCursor, {
    this.partnerReadAt,
    this.partnerReadMessageId,
  });
  final List<ApiMessage> items;
  final String? nextCursor;
  final String? partnerReadAt;
  final String? partnerReadMessageId;
}

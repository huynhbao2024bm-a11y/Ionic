import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import type { Observable } from 'rxjs';

export interface ApiUser {
  readonly id: string;
  readonly handle: string;
  readonly displayName: string;
}

export interface ApiPost {
  readonly id: string;
  readonly authorId: string;
  readonly body: string;
  readonly createdAt: string;
  readonly likeCount: number;
  readonly replyCount: number;
  readonly liked: boolean;
  readonly saved: boolean;
}

export interface ApiFeedPost extends ApiPost {
  readonly authorHandle: string;
  readonly authorDisplayName: string;
  readonly kind?: 'text' | 'short_video';
  readonly mimeType?: 'video/webm' | 'video/mp4';
}

export type ApiReportReason = 'spam' | 'harassment' | 'harmful' | 'impersonation' | 'other';

export interface ApiProfile {
  readonly handle: string;
  readonly displayName: string;
  readonly bio: string;
  readonly visibility: 'public' | 'private';
  readonly followerCount: number;
  readonly followingCount: number;
  readonly postCount: number;
  readonly isFollowing: boolean;
  readonly isMuted: boolean;
  readonly isSelf: boolean;
}

export interface ApiProfileSearchItem {
  readonly handle: string;
  readonly displayName: string;
  readonly bio: string;
  readonly isFollowing: boolean;
}

export interface ApiManagedProfile {
  readonly handle: string;
  readonly displayName: string;
  readonly bio: string;
}

export interface ApiFeedSettings {
  readonly paused: boolean;
}

export interface ApiPostReply {
  readonly id: string;
  readonly authorId: string;
  readonly authorHandle: string;
  readonly authorDisplayName: string;
  readonly body: string;
  readonly createdAt: string;
}

export interface ApiConversation {
  readonly id: string;
  readonly partnerId: string;
  readonly partnerHandle: string;
  readonly partnerDisplayName: string;
  readonly lastMessage: string;
  readonly updatedAt: string;
}

export interface ApiDirectMessage {
  readonly id: string;
  readonly senderId: string;
  readonly body: string;
  readonly createdAt: string;
}

export interface ApiVideoPost {
  readonly id: string;
  readonly authorId: string;
  readonly authorHandle: string;
  readonly authorDisplayName: string;
  readonly caption: string;
  readonly createdAt: string;
  readonly mimeType: 'video/webm' | 'video/mp4';
  readonly state: 'pending_review' | 'ready';
}

interface AccountResponse {
  readonly user: ApiUser;
}

@Injectable({ providedIn: 'root' })
export class IonicApiService {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = '/api/v1';
  private readonly credentials = { withCredentials: true } as const;

  currentUser(): Observable<AccountResponse> {
    return this.http.get<AccountResponse>(`${this.baseUrl}/auth/me`, this.credentials);
  }

  register(handle: string, displayName: string, password: string): Observable<AccountResponse> {
    return this.http.post<AccountResponse>(`${this.baseUrl}/auth/register`, { handle, displayName, password }, this.credentials);
  }

  login(handle: string, password: string): Observable<AccountResponse> {
    return this.http.post<AccountResponse>(`${this.baseUrl}/auth/login`, { handle, password }, this.credentials);
  }

  logout(): Observable<{ readonly status: 'signed_out' }> {
    return this.http.post<{ readonly status: 'signed_out' }>(`${this.baseUrl}/auth/logout`, {}, this.credentials);
  }

  createPost(body: string): Observable<ApiPost> {
    return this.http.post<ApiPost>(`${this.baseUrl}/posts`, { body }, this.credentials);
  }

  setPostLike(contentId: string, liked: boolean): Observable<{ readonly liked: boolean; readonly likeCount: number }> {
    const url = `${this.baseUrl}/posts/${encodeURIComponent(contentId)}/like`;
    return liked
      ? this.http.post<{ readonly liked: boolean; readonly likeCount: number }>(url, {}, this.credentials)
      : this.http.delete<{ readonly liked: boolean; readonly likeCount: number }>(url, this.credentials);
  }

  setPostSaved(contentId: string, saved: boolean): Observable<{ readonly saved: boolean }> {
    const url = `${this.baseUrl}/posts/${encodeURIComponent(contentId)}/save`;
    return saved
      ? this.http.post<{ readonly saved: boolean }>(url, {}, this.credentials)
      : this.http.delete<{ readonly saved: boolean }>(url, this.credentials);
  }

  replies(contentId: string): Observable<{ readonly items: readonly ApiPostReply[]; readonly nextCursor: string | null }> {
    return this.http.get<{ readonly items: readonly ApiPostReply[]; readonly nextCursor: string | null }>(
      `${this.baseUrl}/posts/${encodeURIComponent(contentId)}/replies?limit=20`, this.credentials,
    );
  }

  createReply(contentId: string, body: string): Observable<ApiPostReply & { readonly replyCount: number }> {
    return this.http.post<ApiPostReply & { readonly replyCount: number }>(
      `${this.baseUrl}/posts/${encodeURIComponent(contentId)}/replies`, { body }, this.credentials,
    );
  }

  myPosts(): Observable<{ readonly items: readonly ApiPost[]; readonly nextCursor: string | null }> {
    return this.http.get<{ readonly items: readonly ApiPost[]; readonly nextCursor: string | null }>(
      `${this.baseUrl}/posts/mine?limit=50`,
      this.credentials,
    );
  }

  followingPosts(cursor?: string): Observable<{ readonly items: readonly ApiFeedPost[]; readonly nextCursor: string | null }> {
    const params = new URLSearchParams({ limit: '20' });
    if (cursor) params.set('cursor', cursor);
    return this.http.get<{ readonly items: readonly ApiFeedPost[]; readonly nextCursor: string | null }>(
      `${this.baseUrl}/posts/following?${params.toString()}`,
      this.credentials,
    );
  }

  searchPosts(query: string, cursor?: string): Observable<{ readonly items: readonly ApiFeedPost[]; readonly nextCursor: string | null }> {
    const params = new URLSearchParams({ q: query, limit: '20' });
    if (cursor) params.set('cursor', cursor);
    return this.http.get<{ readonly items: readonly ApiFeedPost[]; readonly nextCursor: string | null }>(
      `${this.baseUrl}/posts/search?${params.toString()}`,
      this.credentials,
    );
  }

  reportPost(contentId: string, reason: ApiReportReason, details: string): Observable<{ readonly id: string; readonly status: 'received' | 'reviewing' | 'actioned' | 'dismissed'; readonly createdAt: string }> {
    return this.http.post<{ readonly id: string; readonly status: 'received' | 'reviewing' | 'actioned' | 'dismissed'; readonly createdAt: string }>(
      `${this.baseUrl}/reports`, { contentId, reason, details }, this.credentials,
    );
  }

  profilePosts(handle: string, cursor?: string): Observable<{ readonly items: readonly ApiPost[]; readonly nextCursor: string | null }> {
    const params = new URLSearchParams({ limit: '20' });
    if (cursor) params.set('cursor', cursor);
    return this.http.get<{ readonly items: readonly ApiPost[]; readonly nextCursor: string | null }>(
      `${this.baseUrl}/posts/author/${encodeURIComponent(handle.replace(/^@/, ''))}?${params.toString()}`,
      this.credentials,
    );
  }

  searchProfiles(query: string): Observable<{ readonly items: readonly ApiProfileSearchItem[] }> {
    const params = new URLSearchParams({ q: query });
    return this.http.get<{ readonly items: readonly ApiProfileSearchItem[] }>(
      `${this.baseUrl}/profiles/search?${params.toString()}`,
      this.credentials,
    );
  }

  profile(handle: string): Observable<{ readonly profile: ApiProfile }> {
    return this.http.get<{ readonly profile: ApiProfile }>(
      `${this.baseUrl}/profiles/${encodeURIComponent(handle.replace(/^@/, ''))}`,
      this.credentials,
    );
  }

  followingProfiles(): Observable<{ readonly items: readonly ApiProfileSearchItem[] }> {
    return this.http.get<{ readonly items: readonly ApiProfileSearchItem[] }>(`${this.baseUrl}/profiles/following`, this.credentials);
  }

  blockedProfiles(): Observable<{ readonly items: readonly ApiProfileSearchItem[] }> {
    return this.http.get<{ readonly items: readonly ApiProfileSearchItem[] }>(`${this.baseUrl}/profiles/blocked`, this.credentials);
  }

  mutedProfiles(): Observable<{ readonly items: readonly ApiManagedProfile[] }> {
    return this.http.get<{ readonly items: readonly ApiManagedProfile[] }>(`${this.baseUrl}/profiles/muted`, this.credentials);
  }

  forYouPosts(cursor?: string): Observable<{ readonly items: readonly ApiFeedPost[]; readonly nextCursor: string | null }> {
    const params = new URLSearchParams({ limit: '20' });
    if (cursor) params.set('cursor', cursor);
    return this.http.get<{ readonly items: readonly ApiFeedPost[]; readonly nextCursor: string | null }>(
      `${this.baseUrl}/feed/for-you?${params.toString()}`,
      this.credentials,
    );
  }

  feedSettings(): Observable<ApiFeedSettings> {
    return this.http.get<ApiFeedSettings>(`${this.baseUrl}/feed/settings`, this.credentials);
  }

  updateFeedSettings(paused: boolean): Observable<ApiFeedSettings> {
    return this.http.patch<ApiFeedSettings>(`${this.baseUrl}/feed/settings`, { paused }, this.credentials);
  }

  resetFeedPreferences(): Observable<{ readonly status: 'reset' }> {
    return this.http.post<{ readonly status: 'reset' }>(`${this.baseUrl}/feed/reset`, {}, this.credentials);
  }

  setPostPreference(contentId: string, preference: 'more' | 'less' | 'none'): Observable<{ readonly status: 'updated' }> {
    return this.http.post<{ readonly status: 'updated' }>(
      `${this.baseUrl}/feed/${encodeURIComponent(contentId)}/preference`, { preference }, this.credentials,
    );
  }

  hideFeedPost(contentId: string): Observable<{ readonly status: 'hidden' }> {
    return this.http.post<{ readonly status: 'hidden' }>(
      `${this.baseUrl}/feed/${encodeURIComponent(contentId)}/hide`, {}, this.credentials,
    );
  }

  recordVideoSignal(contentId: string, eventId: string, kind: 'active_view' | 'skip'): Observable<{ readonly status: 'recorded' | 'duplicate' | 'paused' }> {
    return this.http.post<{ readonly status: 'recorded' | 'duplicate' | 'paused' }>(
      `${this.baseUrl}/feed/${encodeURIComponent(contentId)}/video-signal`, { eventId, kind }, this.credentials,
    );
  }

  follow(handle: string): Observable<{ readonly status: 'following' }> {
    return this.http.post<{ readonly status: 'following' }>(
      `${this.baseUrl}/profiles/${encodeURIComponent(handle.replace(/^@/, ''))}/follow`, {}, this.credentials,
    );
  }

  unfollow(handle: string): Observable<{ readonly status: 'not_following' }> {
    return this.http.delete<{ readonly status: 'not_following' }>(
      `${this.baseUrl}/profiles/${encodeURIComponent(handle.replace(/^@/, ''))}/follow`, this.credentials,
    );
  }

  block(handle: string): Observable<{ readonly status: 'blocked' }> {
    return this.http.post<{ readonly status: 'blocked' }>(
      `${this.baseUrl}/profiles/${encodeURIComponent(handle.replace(/^@/, ''))}/block`, {}, this.credentials,
    );
  }

  unblock(handle: string): Observable<{ readonly status: 'unblocked' }> {
    return this.http.delete<{ readonly status: 'unblocked' }>(
      `${this.baseUrl}/profiles/${encodeURIComponent(handle.replace(/^@/, ''))}/block`, this.credentials,
    );
  }

  mute(handle: string): Observable<{ readonly status: 'muted' }> {
    return this.http.post<{ readonly status: 'muted' }>(
      `${this.baseUrl}/profiles/${encodeURIComponent(handle.replace(/^@/, ''))}/mute`, {}, this.credentials,
    );
  }

  unmute(handle: string): Observable<{ readonly status: 'unmuted' }> {
    return this.http.delete<{ readonly status: 'unmuted' }>(
      `${this.baseUrl}/profiles/${encodeURIComponent(handle.replace(/^@/, ''))}/mute`, this.credentials,
    );
  }

  conversations(): Observable<{ readonly items: readonly ApiConversation[] }> {
    return this.http.get<{ readonly items: readonly ApiConversation[] }>(`${this.baseUrl}/messages/conversations`, this.credentials);
  }

  startConversation(handle: string): Observable<{ readonly conversation: ApiConversation }> {
    return this.http.post<{ readonly conversation: ApiConversation }>(`${this.baseUrl}/messages/conversations`, { handle }, this.credentials);
  }

  conversationMessages(conversationId: string, cursor?: string): Observable<{
    readonly items: readonly ApiDirectMessage[];
    readonly nextCursor: string | null;
  }> {
    const params = new URLSearchParams({ limit: '50' });
    if (cursor) params.set('cursor', cursor);
    return this.http.get<{ readonly items: readonly ApiDirectMessage[]; readonly nextCursor: string | null }>(
      `${this.baseUrl}/messages/conversations/${encodeURIComponent(conversationId)}?${params.toString()}`, this.credentials,
    );
  }

  sendMessage(conversationId: string, body: string, clientMessageId: string): Observable<ApiDirectMessage> {
    return this.http.post<ApiDirectMessage>(
      `${this.baseUrl}/messages/conversations/${encodeURIComponent(conversationId)}`,
      { body, clientMessageId }, this.credentials,
    );
  }

  videos(): Observable<{ readonly items: readonly ApiVideoPost[] }> {
    return this.http.get<{ readonly items: readonly ApiVideoPost[] }>(`${this.baseUrl}/videos`, this.credentials);
  }

  uploadVideo(file: File, caption: string): Observable<ApiVideoPost> {
    const captionHeader = Array.from(new TextEncoder().encode(caption), (byte) => byte.toString(16).padStart(2, '0')).join('');
    return this.http.post<ApiVideoPost>(
      `${this.baseUrl}/videos/upload`,
      file,
      { ...this.credentials, headers: { 'Content-Type': file.type, 'X-Ionic-Caption': captionHeader } },
    );
  }

  videoFileUrl(contentId: string): string {
    return `${this.baseUrl}/videos/${encodeURIComponent(contentId)}/file`;
  }
}

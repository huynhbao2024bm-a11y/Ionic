import { ChangeDetectionStrategy, Component, computed, signal } from '@angular/core';
import { HttpErrorResponse } from '@angular/common/http';
import { IonApp, IonIcon, IonModal } from '@ionic/angular';
import { FeedVideoSignalDirective } from './feed-video-signal.directive';
import { ApiConversation, ApiDirectMessage, ApiFeedPost, ApiManagedProfile, ApiPost, ApiPostReply, ApiProfile, ApiProfileSearchItem, ApiReportReason, ApiUser, ApiVideoPost, IonicApiService } from './ionic-api.service';

type FeedMode = 'for-you' | 'following';
type Page = 'home' | 'video' | 'messages' | 'profile';

interface DemoPost {
  id: string;
  author: string;
  handle: string;
  initials: string;
  time: string;
  text: string;
  kind?: 'text' | 'short_video';
  mimeType?: 'video/webm' | 'video/mp4';
  topicLabels: string[];
  likes: number;
  replies: number;
  liked: boolean;
  saved: boolean;
  followed: boolean;
  replyMessages: string[];
}

function toDemoPost(post: ApiPost, user: ApiUser): DemoPost {
  const elapsedMinutes = Math.max(0, Math.floor((Date.now() - Date.parse(post.createdAt)) / 60_000));
  const time = elapsedMinutes < 1
    ? 'vừa xong'
    : elapsedMinutes < 60
      ? `${elapsedMinutes} phút`
      : elapsedMinutes < 1_440
        ? `${Math.floor(elapsedMinutes / 60)} giờ`
        : `${Math.floor(elapsedMinutes / 1_440)} ngày`;
  return {
    id: post.id,
    author: user.displayName,
    handle: `@${user.handle}`,
    initials: user.displayName.slice(0, 1).toLocaleUpperCase('vi'),
    time,
    text: post.body,
    kind: 'text',
    topicLabels: [],
    likes: post.likeCount ?? 0,
    replies: post.replyCount ?? 0,
    liked: post.liked ?? false,
    saved: post.saved ?? false,
    followed: true,
    replyMessages: [],
  };
}

function toFollowingDemoPost(post: ApiFeedPost): DemoPost {
  const user: ApiUser = {
    id: post.authorId,
    handle: post.authorHandle,
    displayName: post.authorDisplayName,
  };
  return {
    ...toDemoPost(post, user),
    kind: post.kind ?? 'text',
    ...(post.mimeType ? { mimeType: post.mimeType } : {}),
  };
}

function toProfileDemoPost(post: ApiPost, profile: ApiProfile): DemoPost {
  return toDemoPost(post, { id: '', handle: profile.handle, displayName: profile.displayName });
}

function apiFailureMessage(error: unknown): string {
  if (error instanceof HttpErrorResponse) {
    if (error.status === 0) return 'Không kết nối được máy chủ. Hãy kiểm tra API và PostgreSQL đang chạy.';
    if (error.status === 503) return 'Cơ sở dữ liệu chưa sẵn sàng. Bài viết chưa được lưu.';
    if (error.status === 400) return 'Dữ liệu chưa hợp lệ hoặc thao tác chưa được hỗ trợ.';
    if (error.status === 401) return 'Phiên đăng nhập đã hết hạn. Hãy đăng nhập lại.';
    if (error.status === 409) return 'Tên tài khoản này đã được sử dụng.';
    if (error.status === 403) return 'Máy chủ từ chối thao tác này. Hãy kiểm tra quyền truy cập.';
    if (error.status === 404) return 'Không tìm thấy tài khoản hoặc nội dung này.';
  }
  return 'Không thể hoàn tất thao tác. Dữ liệu chưa được lưu.';
}

@Component({
  selector: 'ionic-root',
  standalone: true,
  imports: [IonApp, IonIcon, IonModal, FeedVideoSignalDirective],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AppComponent {
  readonly page = signal<Page>('home');
  readonly feedMode = signal<FeedMode>('for-you');
  readonly searchOpen = signal(false);
  readonly query = signal('');
  readonly composerOpen = signal(false);
  readonly authDialogOpen = signal(false);
  readonly authMode = signal<'register' | 'login'>('register');
  readonly authHandle = signal('');
  readonly authDisplayName = signal('');
  readonly authPassword = signal('');
  readonly authError = signal('');
  readonly authBusy = signal(false);
  readonly isSavingPost = signal(false);
  readonly currentUser = signal<ApiUser | null>(null);
  readonly currentProfile = signal<ApiProfile | null>(null);
  readonly viewedProfile = signal<ApiProfile | null>(null);
  readonly viewedProfilePosts = signal<DemoPost[]>([]);
  readonly viewedProfileBusy = signal(false);
  readonly viewedProfileError = signal('');
  readonly viewedProfileNextCursor = signal<string | null>(null);
  readonly accountPosts = signal<DemoPost[]>([]);
  readonly followingPosts = signal<DemoPost[]>([]);
  readonly followingBusy = signal(false);
  readonly followingError = signal('');
  readonly followingNextCursor = signal<string | null>(null);
  readonly forYouPosts = signal<DemoPost[]>([]);
  readonly forYouBusy = signal(false);
  readonly forYouError = signal('');
  readonly forYouNextCursor = signal<string | null>(null);
  readonly personalizationBusy = signal(false);
  readonly liveProfiles = signal<readonly ApiProfileSearchItem[]>([]);
  readonly postSearchResults = signal<DemoPost[]>([]);
  readonly postSearchBusy = signal(false);
  readonly postSearchError = signal('');
  readonly postSearchNextCursor = signal<string | null>(null);
  readonly reportDialogOpen = signal(false);
  readonly reportContentId = signal<string | null>(null);
  readonly reportReason = signal<ApiReportReason>('other');
  readonly reportDetails = signal('');
  readonly reportBusy = signal(false);
  readonly reportError = signal('');
  readonly blockedProfiles = signal<readonly ApiProfileSearchItem[]>([]);
  readonly mutedProfiles = signal<readonly ApiManagedProfile[]>([]);
  readonly followBusyHandles = signal(new Set<string>());
  readonly muteBusyHandles = signal(new Set<string>());
  readonly preferencesOpen = signal(false);
  readonly composeText = signal('');
  readonly showToast = signal('');
  readonly activeMenuId = signal<string | null>(null);
  readonly activeReplyId = signal<string | null>(null);
  readonly replyText = signal('');
  readonly replyBusy = signal(false);
  readonly replyError = signal('');
  readonly postActionBusy = signal(new Set<string>());
  readonly conversationId = signal<string | null>(null);
  readonly messageCursor = signal<string | null>(null);
  readonly messageText = signal('');
  readonly conversations = signal<readonly ApiConversation[]>([]);
  readonly conversationMessages = signal<readonly ApiDirectMessage[]>([]);
  readonly conversationsBusy = signal(false);
  readonly messagesBusy = signal(false);
  readonly messageSendBusy = signal(false);
  readonly conversationsError = signal('');
  readonly messagesError = signal('');
  readonly videoItems = signal<readonly ApiVideoPost[]>([]);
  readonly videoBusy = signal(false);
  readonly videoError = signal('');
  readonly videoCaption = signal('');
  readonly videoFile = signal<File | null>(null);
  readonly videoPreviewUrl = signal<string | null>(null);
  readonly videoRecording = signal(false);
  readonly videoInspecting = signal(false);
  readonly videoPublishing = signal(false);
  readonly personalizationPaused = signal(false);
  readonly followedHandles = signal(new Set(['@linh.pham', '@minh.tran']));
  // Internal demo-ranking features only. Never expose taxonomy labels in the interface.
  readonly lessTopics = signal(new Set<string>());
  readonly preferredTopics = signal(new Set<string>());

  readonly posts = signal<DemoPost[]>([
    {
      id: 'post-linh-1',
      author: 'Linh Phạm',
      handle: '@linh.pham',
      initials: 'L',
      time: '2 giờ',
      text: 'Mình bắt đầu ghi lại một điều học được mỗi ngày. Phần thú vị nhất là những câu hỏi mới mình đặt ra.',
      topicLabels: ['thiết kế', 'thói quen'],
      likes: 68,
      replies: 12,
      liked: false,
      saved: false,
      followed: true,
      replyMessages: [],
    },
    {
      id: 'post-minh-1',
      author: 'Minh Trần',
      handle: '@minh.tran',
      initials: 'M',
      time: '4 giờ',
      text: 'Một mẹo cho trang thông tin dài: chia tiêu đề theo câu hỏi người đọc muốn tìm câu trả lời.',
      topicLabels: ['viết', 'sản phẩm'],
      likes: 31,
      replies: 8,
      liked: false,
      saved: false,
      followed: true,
      replyMessages: [],
    },
    {
      id: 'post-thao-1',
      author: 'Thảo Lê',
      handle: '@thao.le',
      initials: 'T',
      time: '5 giờ',
      text: 'Tụi mình thử rút gọn phần đăng ký còn ba bước. Mọi người hoàn tất nhiều hơn, nhưng phản hồi về lỗi nhập liệu mới là điều đáng học.',
      topicLabels: ['trải nghiệm', 'sản phẩm'],
      likes: 24,
      replies: 5,
      liked: false,
      saved: false,
      followed: false,
      replyMessages: [],
    },
    {
      id: 'post-an-1',
      author: 'An Nguyễn',
      handle: '@an.nguyen',
      initials: 'A',
      time: '6 giờ',
      text: 'Một ghi chú nhỏ sau buổi đi bộ: khi bí ý tưởng, đổi câu hỏi thường dễ hơn cố nghĩ thêm câu trả lời.',
      topicLabels: ['thói quen', 'sáng tạo'],
      likes: 19,
      replies: 3,
      liked: false,
      saved: false,
      followed: false,
      replyMessages: [],
    },
  ]);

  readonly suggestions = [
    { name: 'An Nguyễn', handle: '@an.nguyen', initials: 'A' },
    { name: 'Thảo Lê', handle: '@thao.le', initials: 'T' },
    { name: 'Khánh Vũ', handle: '@khanh.vu', initials: 'K' },
  ];

  readonly visiblePosts = computed(() => {
    const followed = this.followedHandles();
    const ignored = this.lessTopics();
    const query = this.query().trim().toLocaleLowerCase('vi');
    let result = this.currentUser()
      ? (this.feedMode() === 'following' ? this.followingPosts() : this.forYouPosts())
      : this.posts();

    if (this.currentUser() && query.length > 0) {
      return query.length >= 2 ? this.postSearchResults() : [];
    }

    if (this.feedMode() === 'following') {
      result = result.filter((post) => followed.has(post.handle));
    } else if (!this.personalizationPaused()) {
      const preferred = this.preferredTopics();
      result = [...result].sort((left, right) => {
        const leftScore = left.topicLabels.filter((label) => preferred.has(label)).length
          - left.topicLabels.filter((label) => ignored.has(label)).length;
        const rightScore = right.topicLabels.filter((label) => preferred.has(label)).length
          - right.topicLabels.filter((label) => ignored.has(label)).length;
        return rightScore - leftScore;
      });
    }

    if (query) {
      result = result.filter((post) =>
        [post.author, post.handle, post.text].some((value) => value.toLocaleLowerCase('vi').includes(query)),
      );
    }

    return result;
  });

  readonly currentConversation = computed(() => {
    const selectedId = this.conversationId();
    return this.conversations().find((conversation) => conversation.id === selectedId) ?? null;
  });

  readonly searchSuggestions = computed(() => {
    const query = this.query().trim().toLocaleLowerCase('vi');
    if (!query) return [];
    if (this.currentUser()) {
      return this.liveProfiles().map((person) => ({
        name: person.displayName,
        handle: `@${person.handle}`,
        initials: person.displayName.slice(0, 1).toLocaleUpperCase('vi'),
        isFollowing: person.isFollowing,
        isLive: true,
      }));
    }
    return this.suggestions.filter((person) =>
      [person.name, person.handle].some((value) => value.toLocaleLowerCase('vi').includes(query)),
    ).map((person) => ({ ...person, isFollowing: this.followedHandles().has(person.handle), isLive: false }));
  });

  readonly ownPosts = computed(() => this.accountPosts());

  private continueComposeAfterAuth = false;
  private searchTimer: number | null = null;
  private postSearchRevision = 0;
  private forYouRequestRevision = 0;
  private followingRequestRevision = 0;
  private replyRequestRevision = 0;
  private relationshipMutationRevision = 0;
  private blockMutationRevision = 0;
  private messageRefreshTimer: number | null = null;
  private videoRecorder: MediaRecorder | null = null;
  private videoStream: MediaStream | null = null;
  private videoChunks: BlobPart[] = [];
  private videoStopTimer: number | null = null;

  constructor(private readonly api: IonicApiService) {
    this.api.currentUser().subscribe({
      next: ({ user }) => this.activateAccount(user),
      error: () => undefined,
    });
  }

  navigate(page: Page): void {
    this.stopMessageRefresh();
    if (page !== 'video' && this.videoRecording()) this.stopVideoRecording();
    this.page.set(page);
    if (page !== 'profile') {
      this.viewedProfile.set(null);
      this.viewedProfilePosts.set([]);
      this.viewedProfileBusy.set(false);
      this.viewedProfileError.set('');
      this.viewedProfileNextCursor.set(null);
    }
    this.conversationId.set(null);
    this.conversationMessages.set([]);
    this.messageCursor.set(null);
    this.activeMenuId.set(null);
    const behavior = window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth';
    window.scrollTo({ top: 0, behavior });
    if (page === 'messages' && this.currentUser()) this.loadConversations();
    if (page === 'video' && this.currentUser()) this.loadVideos();
  }

  openOwnProfile(): void {
    this.viewedProfile.set(null);
    this.viewedProfilePosts.set([]);
    this.viewedProfileBusy.set(false);
    this.viewedProfileError.set('');
    this.viewedProfileNextCursor.set(null);
    this.navigate('profile');
  }

  clearSearch(): void {
    if (this.searchTimer !== null) window.clearTimeout(this.searchTimer);
    this.postSearchRevision += 1;
    this.query.set('');
    this.liveProfiles.set([]);
    this.postSearchResults.set([]);
    this.postSearchBusy.set(false);
    this.postSearchError.set('');
    this.postSearchNextCursor.set(null);
  }

  toggleSearch(): void {
    this.searchOpen.update((open) => !open);
  }

  setFeed(mode: FeedMode): void {
    this.feedMode.set(mode);
    if (!this.currentUser()) return;
    if (mode === 'following') this.loadFollowing();
    else this.loadForYou();
  }

  updateSearch(event: Event): void {
    const query = (event.target as HTMLInputElement).value;
    this.query.set(query);
    if (this.searchTimer !== null) window.clearTimeout(this.searchTimer);
    if (!this.currentUser() || query.trim().replace(/^@/, '').length < 2) {
      this.liveProfiles.set([]);
      this.postSearchRevision += 1;
      this.postSearchResults.set([]);
      this.postSearchNextCursor.set(null);
      this.postSearchBusy.set(false);
      this.postSearchError.set('');
      return;
    }
    this.postSearchRevision += 1;
    this.postSearchResults.set([]);
    this.postSearchNextCursor.set(null);
    this.postSearchBusy.set(true);
    this.postSearchError.set('');
    this.searchTimer = window.setTimeout(() => {
      this.loadProfileSearch(query);
      this.loadPostSearch(query);
    }, 220);
  }

  toggleFollow(handle: string): void {
    const account = this.currentUser();
    if (account) {
      const normalizedHandle = handle.replace(/^@/, '').toLowerCase();
      const busy = this.followBusyHandles();
      if (busy.has(normalizedHandle)) return;
      this.followBusyHandles.set(new Set(busy).add(normalizedHandle));
      const isFollowing = this.followedHandles().has(`@${normalizedHandle}`);
      const onSuccess = () => {
        if (this.currentUser()?.id !== account.id) return;
        this.relationshipMutationRevision += 1;
        this.followedHandles.update((current) => {
          const next = new Set(current);
          if (isFollowing) next.delete(`@${normalizedHandle}`);
          else next.add(`@${normalizedHandle}`);
          return next;
        });
        this.liveProfiles.update((items) => items.map((person) => person.handle === normalizedHandle
          ? { ...person, isFollowing: !isFollowing }
          : person,
        ));
        const viewed = this.viewedProfile();
        if (viewed?.handle === normalizedHandle) this.viewedProfile.set({ ...viewed, isFollowing: !isFollowing });
        this.followBusyHandles.update((current) => {
          const next = new Set(current);
          next.delete(normalizedHandle);
          return next;
        });
        this.loadFollowing();
        this.loadForYou();
        this.notify(isFollowing ? `Đã bỏ theo dõi @${normalizedHandle}.` : `Đã theo dõi @${normalizedHandle}.`);
      };
      const onFailure = (error: unknown) => {
        if (this.currentUser()?.id !== account.id) return;
        this.followBusyHandles.update((current) => {
          const next = new Set(current);
          next.delete(normalizedHandle);
          return next;
        });
        this.notify(apiFailureMessage(error));
      };
      if (isFollowing) this.api.unfollow(normalizedHandle).subscribe({ next: onSuccess, error: onFailure });
      else this.api.follow(normalizedHandle).subscribe({ next: onSuccess, error: onFailure });
      return;
    }
    this.followedHandles.update((current) => {
      const next = new Set(current);
      if (next.has(handle)) next.delete(handle);
      else next.add(handle);
      return next;
    });
    const following = this.followedHandles().has(handle);
    this.notify(following ? `Đã theo dõi ${handle} trong phiên demo.` : `Đã bỏ theo dõi ${handle} trong phiên demo.`);
  }

  openProfile(handle: string): void {
    const viewer = this.currentUser();
    if (!viewer) return;
    const normalizedHandle = handle.replace(/^@/, '').toLowerCase();
    this.api.profile(normalizedHandle).subscribe({
      next: ({ profile }) => {
        if (this.currentUser()?.id !== viewer.id) return;
        this.viewedProfile.set(profile.isSelf ? null : profile);
        this.currentProfile.set(profile.isSelf ? profile : this.currentProfile());
        this.navigate('profile');
        if (profile.isSelf) {
          this.viewedProfilePosts.set([]);
          this.viewedProfileNextCursor.set(null);
          this.viewedProfileBusy.set(false);
          this.viewedProfileError.set('');
        } else {
          this.viewedProfilePosts.set([]);
          this.viewedProfileNextCursor.set(null);
          this.loadViewedProfilePosts(profile);
        }
      },
      error: (error: unknown) => {
        if (this.currentUser()?.id === viewer.id) this.notify(apiFailureMessage(error));
      },
    });
  }

  blockViewedProfile(): void {
    const profile = this.viewedProfile();
    const viewerId = this.currentUser()?.id;
    if (!profile || profile.isSelf || !viewerId) return;
    this.api.block(profile.handle).subscribe({
      next: () => {
        if (this.currentUser()?.id !== viewerId) return;
        this.relationshipMutationRevision += 1;
        this.blockMutationRevision += 1;
        this.followedHandles.update((current) => {
          const next = new Set(current);
          next.delete(`@${profile.handle}`);
          return next;
        });
        this.viewedProfile.set(null);
        this.viewedProfilePosts.set([]);
        this.loadFollowing();
        this.loadForYou();
        this.loadBlockedProfiles();
        this.navigate('home');
        this.notify(`Đã chặn @${profile.handle}.`);
      },
      error: (error: unknown) => { if (this.currentUser()?.id === viewerId) this.notify(apiFailureMessage(error)); },
    });
  }

  loadMoreFollowing(): void {
    const cursor = this.followingNextCursor();
    if (cursor && !this.followingBusy()) this.loadFollowing(cursor);
  }

  loadMoreForYou(): void {
    const cursor = this.forYouNextCursor();
    if (cursor && !this.forYouBusy()) this.loadForYou(cursor);
  }

  loadMoreProfilePosts(): void {
    const cursor = this.viewedProfileNextCursor();
    const profile = this.viewedProfile();
    if (cursor && profile && !this.viewedProfileBusy()) this.loadViewedProfilePosts(profile, cursor);
  }

  unblockAccount(handle: string): void {
    const viewerId = this.currentUser()?.id;
    if (!viewerId) return;
    this.api.unblock(handle).subscribe({
      next: () => {
        if (this.currentUser()?.id !== viewerId) return;
        this.relationshipMutationRevision += 1;
        this.blockMutationRevision += 1;
        this.blockedProfiles.update((items) => items.filter((profile) => profile.handle !== handle));
        this.loadFollowing();
        this.loadForYou();
        this.notify(`Đã bỏ chặn @${handle}.`);
      },
      error: (error: unknown) => { if (this.currentUser()?.id === viewerId) this.notify(apiFailureMessage(error)); },
    });
  }

  toggleMuteViewedProfile(): void {
    const profile = this.viewedProfile();
    if (!profile || profile.isSelf || !this.currentUser() || this.muteBusyHandles().has(profile.handle)) return;
    const viewerId = this.currentUser()!.id;
    const muting = !profile.isMuted;
    this.muteBusyHandles.update((current) => new Set(current).add(profile.handle));
    const onSuccess = () => {
      if (this.currentUser()?.id !== viewerId) return;
      this.viewedProfile.update((current) => current?.handle === profile.handle ? { ...current, isMuted: muting } : current);
      this.muteBusyHandles.update((current) => { const next = new Set(current); next.delete(profile.handle); return next; });
      this.loadMutedProfiles();
      this.refreshFeedsAfterMute(muting ? profile.handle : null);
      this.notify(muting ? `Đã tắt tiếng @${profile.handle} trong bảng tin.` : `Đã bật lại bài viết từ @${profile.handle}.`);
    };
    const onFailure = (error: unknown) => {
      if (this.currentUser()?.id !== viewerId) return;
      this.muteBusyHandles.update((current) => { const next = new Set(current); next.delete(profile.handle); return next; });
      this.notify(apiFailureMessage(error));
    };
    if (muting) this.api.mute(profile.handle).subscribe({ next: onSuccess, error: onFailure });
    else this.api.unmute(profile.handle).subscribe({ next: onSuccess, error: onFailure });
  }

  unmuteAccount(handle: string): void {
    const viewerId = this.currentUser()?.id;
    if (!viewerId || this.muteBusyHandles().has(handle)) return;
    this.muteBusyHandles.update((current) => new Set(current).add(handle));
    this.api.unmute(handle).subscribe({
      next: () => {
        if (this.currentUser()?.id !== viewerId) return;
        this.muteBusyHandles.update((current) => { const next = new Set(current); next.delete(handle); return next; });
        this.viewedProfile.update((current) => current?.handle === handle ? { ...current, isMuted: false } : current);
        this.loadMutedProfiles();
        this.refreshFeedsAfterMute(null);
        this.notify(`Đã bật lại bài viết từ @${handle}.`);
      },
      error: (error: unknown) => {
        if (this.currentUser()?.id !== viewerId) return;
        this.muteBusyHandles.update((current) => { const next = new Set(current); next.delete(handle); return next; });
        this.notify(apiFailureMessage(error));
      },
    });
  }

  mutePostAuthor(post: DemoPost): void {
    if (!this.currentUser() || post.handle === `@${this.currentUser()?.handle}` || this.muteBusyHandles().has(post.handle.slice(1))) return;
    const viewerId = this.currentUser()!.id;
    const handle = post.handle.slice(1);
    this.muteBusyHandles.update((current) => new Set(current).add(handle));
    this.api.mute(handle).subscribe({
      next: () => {
        if (this.currentUser()?.id !== viewerId) return;
        this.muteBusyHandles.update((current) => { const next = new Set(current); next.delete(handle); return next; });
        this.activeMenuId.set(null);
        this.loadMutedProfiles();
        this.refreshFeedsAfterMute(handle);
        this.notify(`Đã tắt tiếng @${handle} trong bảng tin.`);
      },
      error: (error: unknown) => {
        if (this.currentUser()?.id !== viewerId) return;
        this.muteBusyHandles.update((current) => { const next = new Set(current); next.delete(handle); return next; });
        this.notify(apiFailureMessage(error));
      },
    });
  }

  toggleLike(postId: string): void {
    const post = this.findPost(postId);
    if (!post || this.postActionBusy().has(`like:${postId}`)) return;
    const liked = !post.liked;
    if (this.currentUser()) {
      this.setPostActionBusy(`like:${postId}`, true);
      this.api.setPostLike(postId, liked).subscribe({
        next: (state) => {
          this.updatePost(postId, (item) => ({ ...item, liked: state.liked, likes: state.likeCount }));
          this.setPostActionBusy(`like:${postId}`, false);
        },
        error: (error: unknown) => {
          this.setPostActionBusy(`like:${postId}`, false);
          this.notify(apiFailureMessage(error));
        },
      });
      return;
    }
    this.updatePost(postId, (item) => ({ ...item, liked, likes: Math.max(0, item.likes + (liked ? 1 : -1)) }));
  }

  toggleSave(postId: string): void {
    const post = this.findPost(postId);
    if (!post || this.postActionBusy().has(`save:${postId}`)) return;
    const saved = !post.saved;
    if (this.currentUser()) {
      this.setPostActionBusy(`save:${postId}`, true);
      this.api.setPostSaved(postId, saved).subscribe({
        next: (state) => {
          this.updatePost(postId, (item) => ({ ...item, saved: state.saved }));
          this.setPostActionBusy(`save:${postId}`, false);
          this.notify(state.saved ? 'Đã lưu bài viết.' : 'Đã bỏ lưu bài viết.');
        },
        error: (error: unknown) => {
          this.setPostActionBusy(`save:${postId}`, false);
          this.notify(apiFailureMessage(error));
        },
      });
      return;
    }
    this.updatePost(postId, (item) => ({ ...item, saved }));
    this.notify(saved ? 'Đã lưu trong phiên demo.' : 'Đã bỏ lưu trong phiên demo.');
  }

  toggleMenu(postId: string): void {
    this.activeMenuId.update((current) => current === postId ? null : postId);
  }

  hidePost(postId: string): void {
    if (this.currentUser()) {
      this.api.hideFeedPost(postId).subscribe({
        next: () => {
          this.forYouPosts.update((items) => items.filter((post) => post.id !== postId));
          this.followingPosts.update((items) => items.filter((post) => post.id !== postId));
          this.activeMenuId.set(null);
          this.notify('Đã ẩn bài viết khỏi bảng tin của bạn.');
        },
        error: (error: unknown) => this.notify(apiFailureMessage(error)),
      });
      return;
    }
    this.posts.update((items) => items.filter((post) => post.id !== postId));
    this.activeMenuId.set(null);
    this.notify('Đã ẩn bài viết khỏi bảng tin demo.');
  }

  reportPost(contentId: string): void {
    this.activeMenuId.set(null);
    if (!this.currentUser()) {
      this.notify('Đăng nhập để gửi báo cáo nội dung.');
      return;
    }
    this.reportContentId.set(contentId);
    this.reportReason.set('other');
    this.reportDetails.set('');
    this.reportError.set('');
    this.reportDialogOpen.set(true);
  }

  closeReportDialog(): void {
    this.reportDialogOpen.set(false);
    this.reportContentId.set(null);
    this.reportError.set('');
  }

  updateReportReason(event: Event): void {
    const value = (event.target as HTMLSelectElement).value;
    if (['spam', 'harassment', 'harmful', 'impersonation', 'other'].includes(value)) {
      this.reportReason.set(value as ApiReportReason);
    }
  }

  updateReportDetails(event: Event): void {
    this.reportDetails.set((event.target as HTMLTextAreaElement).value);
  }

  submitContentReport(): void {
    const contentId = this.reportContentId();
    if (!contentId || this.reportBusy()) return;
    this.reportBusy.set(true);
    this.reportError.set('');
    this.api.reportPost(contentId, this.reportReason(), this.reportDetails()).subscribe({
      next: () => {
        this.reportBusy.set(false);
        this.closeReportDialog();
        this.notify('Đã nhận báo cáo. Cảm ơn bạn đã cho chúng tôi biết.');
      },
      error: (error: unknown) => {
        this.reportBusy.set(false);
        this.reportError.set(apiFailureMessage(error));
      },
    });
  }

  updateContentPreference(post: DemoPost, preference: 'more' | 'less'): void {
    if (this.currentUser()) {
      this.api.setPostPreference(post.id, preference).subscribe({
        next: () => {
          this.activeMenuId.set(null);
          this.loadForYou();
          this.notify('Đã cập nhật tùy chọn bảng tin của bạn.');
        },
        error: (error: unknown) => this.notify(apiFailureMessage(error)),
      });
      return;
    }
    const currentPreferred = new Set(this.preferredTopics());
    const currentIgnored = new Set(this.lessTopics());
    for (const label of post.topicLabels) {
      if (preference === 'more') {
        currentPreferred.add(label);
        currentIgnored.delete(label);
      } else {
        currentIgnored.add(label);
        currentPreferred.delete(label);
      }
    }
    this.preferredTopics.set(currentPreferred);
    this.lessTopics.set(currentIgnored);
    this.activeMenuId.set(null);
    const pausedNote = this.personalizationPaused() ? ' Bật lại cá nhân hóa để áp dụng.' : '';
    this.notify(preference === 'more'
      ? `Đã ghi nhận. Bảng tin demo sẽ xếp nội dung tương tự cao hơn.${pausedNote}`
      : `Đã ghi nhận. Bảng tin demo sẽ xếp nội dung tương tự thấp hơn.${pausedNote}`,
    );
  }

  openReplies(postId: string): void {
    const closing = this.activeReplyId() === postId;
    this.activeReplyId.set(closing ? null : postId);
    this.replyText.set('');
    this.replyError.set('');
    const requestRevision = ++this.replyRequestRevision;
    this.replyBusy.set(false);
    if (closing || !this.currentUser()) return;
    this.replyBusy.set(true);
    this.api.replies(postId).subscribe({
      next: ({ items }) => {
        if (this.replyRequestRevision !== requestRevision || this.activeReplyId() !== postId) return;
        this.updatePost(postId, (item) => ({
          ...item,
          replyMessages: items.map((reply) => `${reply.authorDisplayName}: ${reply.body}`),
          replies: Math.max(item.replies, items.length),
        }));
        this.replyBusy.set(false);
      },
      error: (error: unknown) => {
        if (this.replyRequestRevision !== requestRevision || this.activeReplyId() !== postId) return;
        this.replyBusy.set(false);
        this.replyError.set(apiFailureMessage(error));
      },
    });
  }

  submitReply(post: DemoPost): void {
    const text = this.replyText().trim();
    if (!text || this.replyBusy()) return;
    if (this.currentUser()) {
      this.replyBusy.set(true);
      this.replyError.set('');
      this.api.createReply(post.id, text).subscribe({
        next: (reply) => {
          this.updatePost(post.id, (item) => ({
            ...item,
            replies: reply.replyCount,
            replyMessages: [`${reply.authorDisplayName}: ${reply.body}`, ...item.replyMessages],
          }));
          this.replyBusy.set(false);
          this.replyText.set('');
          this.activeReplyId.set(null);
        },
        error: (error: unknown) => {
          this.replyBusy.set(false);
          this.replyError.set(apiFailureMessage(error));
        },
      });
      return;
    }
    this.updatePost(post.id, (item) => ({ ...item, replies: item.replies + 1, replyMessages: [...item.replyMessages, text] }));
    this.replyText.set('');
    this.activeReplyId.set(null);
    this.notify('Phản hồi được thêm vào bản demo trong phiên này.');
  }

  async sharePost(post: DemoPost): Promise<void> {
    try {
      await navigator.clipboard.writeText(`${post.author}: ${post.text}`);
      this.notify('Đã sao chép nội dung bài viết.');
    } catch {
      this.notify('Trình duyệt chưa cho phép sao chép tại đây.');
    }
  }

  openComposer(): void {
    if (!this.currentUser()) {
      this.continueComposeAfterAuth = true;
      this.openAuth('register');
      return;
    }
    this.showComposer();
  }

  private showComposer(): void {
    this.composeText.set('');
    this.composerOpen.set(true);
  }

  focusComposeInput(): void {
    document.getElementById('compose-input')?.focus();
  }

  closeComposer(): void {
    this.composerOpen.set(false);
  }

  publishPost(): void {
    const text = this.composeText().trim();
    if (!text || text.length > 280 || this.isSavingPost()) return;
    const user = this.currentUser();
    if (!user) {
      this.closeComposer();
      this.openComposer();
      return;
    }

    this.isSavingPost.set(true);
    this.api.createPost(text).subscribe({
      next: (post) => {
        const savedPost = toDemoPost(post, user);
        this.accountPosts.update((items) => [savedPost, ...items.filter((item) => item.id !== post.id)]);
        this.posts.update((items) => [savedPost, ...items.filter((item) => item.id !== post.id)]);
        this.feedMode.set('for-you');
        this.page.set('home');
        this.loadForYou();
        this.closeComposer();
        this.isSavingPost.set(false);
        this.notify('Bài viết đã được lưu vào tài khoản.');
      },
      error: (error: unknown) => {
        this.isSavingPost.set(false);
        this.notify(apiFailureMessage(error));
      },
    });
  }

  openAuth(mode: 'register' | 'login' = 'register'): void {
    this.authMode.set(mode);
    this.authError.set('');
    this.authDialogOpen.set(true);
  }

  closeAuth(): void {
    this.authDialogOpen.set(false);
    this.authPassword.set('');
    this.continueComposeAfterAuth = false;
  }

  setAuthMode(mode: 'register' | 'login'): void {
    this.authMode.set(mode);
    this.authError.set('');
  }

  updateAuthHandle(event: Event): void {
    this.authHandle.set((event.target as HTMLInputElement).value);
  }

  updateAuthDisplayName(event: Event): void {
    this.authDisplayName.set((event.target as HTMLInputElement).value);
  }

  updateAuthPassword(event: Event): void {
    this.authPassword.set((event.target as HTMLInputElement).value);
  }

  submitAuth(): void {
    if (this.authBusy()) return;
    this.authBusy.set(true);
    this.authError.set('');
    const request = this.authMode() === 'register'
      ? this.api.register(this.authHandle(), this.authDisplayName(), this.authPassword())
      : this.api.login(this.authHandle(), this.authPassword());
    request.subscribe({
      next: ({ user }) => {
        const shouldCompose = this.continueComposeAfterAuth;
        this.authBusy.set(false);
        this.authDialogOpen.set(false);
        this.authPassword.set('');
        this.activateAccount(user);
        this.notify('Đã đăng nhập. Bài viết mới sẽ được lưu trong tài khoản.');
        if (shouldCompose) {
          this.continueComposeAfterAuth = false;
          this.showComposer();
        }
      },
      error: (error: unknown) => {
        this.authBusy.set(false);
        this.authError.set(error instanceof HttpErrorResponse && error.status === 401
          ? 'Tên tài khoản hoặc mật khẩu chưa đúng.'
          : apiFailureMessage(error));
      },
    });
  }

  signOut(): void {
    this.api.logout().subscribe({
      next: () => {
        const accountHandle = this.currentUser()?.handle;
        this.currentUser.set(null);
        this.clearAccountScopedState(accountHandle);
        this.notify('Đã đăng xuất.');
      },
      error: (error: unknown) => this.notify(apiFailureMessage(error)),
    });
  }

  private clearAccountScopedState(accountHandle?: string): void {
    this.stopMessageRefresh();
    this.relationshipMutationRevision += 1;
    this.blockMutationRevision += 1;
    this.postSearchRevision += 1;
    this.forYouRequestRevision += 1;
    this.followingRequestRevision += 1;
    this.replyRequestRevision += 1;
    if (this.searchTimer !== null) window.clearTimeout(this.searchTimer);
    this.searchTimer = null;

    this.searchOpen.set(false);
    this.query.set('');
    this.authHandle.set('');
    this.authDisplayName.set('');
    this.authPassword.set('');
    this.postSearchResults.set([]);
    this.postSearchBusy.set(false);
    this.postSearchError.set('');
    this.postSearchNextCursor.set(null);
    this.liveProfiles.set([]);

    this.currentProfile.set(null);
    this.viewedProfile.set(null);
    this.viewedProfilePosts.set([]);
    this.viewedProfileBusy.set(false);
    this.viewedProfileError.set('');
    this.viewedProfileNextCursor.set(null);
    this.accountPosts.set([]);
    this.followingPosts.set([]);
    this.followingBusy.set(false);
    this.followingError.set('');
    this.followingNextCursor.set(null);
    this.forYouPosts.set([]);
    this.forYouBusy.set(false);
    this.forYouError.set('');
    this.forYouNextCursor.set(null);

    this.conversations.set([]);
    this.conversationsBusy.set(false);
    this.conversationsError.set('');
    this.conversationId.set(null);
    this.conversationMessages.set([]);
    this.messageCursor.set(null);
    this.messageText.set('');
    this.messagesBusy.set(false);
    this.messageSendBusy.set(false);
    this.messagesError.set('');

    this.videoChunks = [];
    this.stopVideoRecording();
    this.videoItems.set([]);
    this.videoBusy.set(false);
    this.videoError.set('');
    this.videoCaption.set('');
    this.clearVideoSelection();

    this.reportDialogOpen.set(false);
    this.reportContentId.set(null);
    this.reportDetails.set('');
    this.reportBusy.set(false);
    this.reportError.set('');
    this.replyText.set('');
    this.activeReplyId.set(null);
    this.replyBusy.set(false);
    this.replyError.set('');
    this.composeText.set('');
    this.composerOpen.set(false);

    this.postActionBusy.set(new Set());
    this.followBusyHandles.set(new Set());
    this.blockedProfiles.set([]);
    this.mutedProfiles.set([]);
    this.muteBusyHandles.set(new Set());
    this.followedHandles.set(new Set(['@linh.pham', '@minh.tran']));
    this.personalizationPaused.set(false);
    this.personalizationBusy.set(false);
    this.lessTopics.set(new Set());
    this.preferredTopics.set(new Set());
    this.activeMenuId.set(null);
    this.reportReason.set('other');
    if (accountHandle) this.posts.update((items) => items.filter((post) => post.handle !== `@${accountHandle}`));
  }

  private activateAccount(user: ApiUser): void {
    const previousUser = this.currentUser();
    if (previousUser && previousUser.id !== user.id) {
      this.clearAccountScopedState(previousUser.handle);
    }
    this.currentUser.set(user);
    this.personalizationPaused.set(false);
    this.relationshipMutationRevision += 1;
    this.blockMutationRevision += 1;
    const revision = this.relationshipMutationRevision;
    this.viewedProfile.set(null);
    this.followedHandles.set(new Set());
    this.api.profile(user.handle).subscribe({
      next: ({ profile }) => { if (this.currentUser()?.id === user.id) this.currentProfile.set(profile); },
      error: () => { if (this.currentUser()?.id === user.id) this.notify('Không tải được hồ sơ tài khoản.'); },
    });
    this.api.followingProfiles().subscribe({
      next: ({ items }) => {
        if (this.currentUser()?.id === user.id && this.relationshipMutationRevision === revision) {
          this.followedHandles.set(new Set(items.map((person) => `@${person.handle}`)));
        }
      },
      error: () => { if (this.currentUser()?.id === user.id) this.notify('Không tải được danh sách đang theo dõi.'); },
    });
    this.loadBlockedProfiles();
    this.loadMutedProfiles();
    this.loadConversations();
    if (this.page() === 'video') this.loadVideos();
    this.api.feedSettings().subscribe({
      next: ({ paused }) => { if (this.currentUser()?.id === user.id) this.personalizationPaused.set(paused); },
      error: () => { if (this.currentUser()?.id === user.id) this.notify('Không tải được tùy chỉnh bảng tin.'); },
    });
    this.api.myPosts().subscribe({
      next: ({ items }) => {
        if (this.currentUser()?.id !== user.id) return;
        const mapped = items.map((post) => toDemoPost(post, user));
        this.accountPosts.set(mapped);
        const savedIds = new Set(mapped.map((post) => post.id));
        this.posts.update((posts) => [...mapped, ...posts.filter((post) => !savedIds.has(post.id))]);
      },
      error: () => { if (this.currentUser()?.id === user.id) this.notify('Không tải được bài viết trong tài khoản.'); },
    });
    if (this.feedMode() === 'following') this.loadFollowing();
    else this.loadForYou();
  }

  private loadProfileSearch(query: string): void {
    const normalizedQuery = query.trim();
    if (!this.currentUser() || normalizedQuery.replace(/^@/, '').length < 2) return;
    this.api.searchProfiles(normalizedQuery).subscribe({
      next: ({ items }) => {
        if (this.currentUser() && this.query().trim() === normalizedQuery) this.liveProfiles.set(items);
      },
      error: () => {
        if (this.currentUser() && this.query().trim() === normalizedQuery) this.liveProfiles.set([]);
      },
    });
  }

  loadMorePostSearch(): void {
    const cursor = this.postSearchNextCursor();
    const query = this.query().trim();
    if (!cursor || this.postSearchBusy() || query.length < 2) return;
    this.postSearchBusy.set(true);
    this.loadPostSearch(query, cursor);
  }

  private loadPostSearch(query: string, cursor?: string): void {
    const normalizedQuery = query.trim();
    const viewerId = this.currentUser()?.id;
    if (!viewerId || normalizedQuery.length < 2) return;
    const revision = this.postSearchRevision;
    this.api.searchPosts(normalizedQuery, cursor).subscribe({
      next: ({ items, nextCursor }) => {
        if (this.currentUser()?.id !== viewerId || this.postSearchRevision !== revision || this.query().trim() !== normalizedQuery) return;
        const mapped = items.map(toFollowingDemoPost);
        this.postSearchResults.update((current) => cursor ? [...current, ...mapped] : mapped);
        this.postSearchNextCursor.set(nextCursor);
        this.postSearchBusy.set(false);
        this.postSearchError.set('');
      },
      error: (error: unknown) => {
        if (this.currentUser()?.id !== viewerId || this.postSearchRevision !== revision || this.query().trim() !== normalizedQuery) return;
        this.postSearchBusy.set(false);
        this.postSearchError.set(apiFailureMessage(error));
      },
    });
  }

  private loadFollowing(cursor?: string): void {
    const viewerId = this.currentUser()?.id;
    if (!viewerId) return;
    const requestRevision = ++this.followingRequestRevision;
    this.followingBusy.set(true);
    this.followingError.set('');
    this.api.followingPosts(cursor).subscribe({
      next: ({ items, nextCursor }) => {
        if (this.currentUser()?.id !== viewerId || this.followingRequestRevision !== requestRevision) return;
        const mapped = items.map(toFollowingDemoPost);
        this.followingPosts.update((current) => cursor ? [...current, ...mapped] : mapped);
        this.followingNextCursor.set(nextCursor);
        this.followingBusy.set(false);
      },
      error: (error: unknown) => {
        if (this.currentUser()?.id !== viewerId || this.followingRequestRevision !== requestRevision) return;
        this.followingBusy.set(false);
        this.followingError.set(apiFailureMessage(error));
      },
    });
  }

  private loadForYou(cursor?: string): void {
    const viewerId = this.currentUser()?.id;
    if (!viewerId) return;
    const requestRevision = ++this.forYouRequestRevision;
    this.forYouBusy.set(true);
    this.forYouError.set('');
    this.api.forYouPosts(cursor).subscribe({
      next: ({ items, nextCursor }) => {
        if (this.currentUser()?.id !== viewerId || this.forYouRequestRevision !== requestRevision) return;
        const mapped = items.map(toFollowingDemoPost);
        this.forYouPosts.update((current) => cursor ? [...current, ...mapped] : mapped);
        this.forYouNextCursor.set(nextCursor);
        this.forYouBusy.set(false);
      },
      error: (error: unknown) => {
        if (this.currentUser()?.id !== viewerId || this.forYouRequestRevision !== requestRevision) return;
        this.forYouBusy.set(false);
        if (cursor && error instanceof HttpErrorResponse && error.status === 400) {
          this.forYouPosts.set([]);
          this.forYouNextCursor.set(null);
          this.loadForYou();
          return;
        }
        this.forYouError.set(apiFailureMessage(error));
      },
    });
  }

  private loadBlockedProfiles(): void {
    const viewerId = this.currentUser()?.id;
    if (!viewerId) return;
    const revision = this.blockMutationRevision;
    this.api.blockedProfiles().subscribe({
      next: ({ items }) => {
        if (this.currentUser()?.id === viewerId && this.blockMutationRevision === revision) this.blockedProfiles.set(items);
      },
      error: () => { if (this.currentUser()?.id === viewerId) this.notify('Không tải được danh sách đã chặn.'); },
    });
  }

  private loadMutedProfiles(): void {
    const viewerId = this.currentUser()?.id;
    if (!viewerId) return;
    this.api.mutedProfiles().subscribe({
      next: ({ items }) => { if (this.currentUser()?.id === viewerId) this.mutedProfiles.set(items); },
      error: () => { if (this.currentUser()?.id === viewerId) this.notify('Không tải được danh sách tài khoản đã tắt tiếng.'); },
    });
  }

  private refreshFeedsAfterMute(mutedHandle: string | null): void {
    if (mutedHandle) {
      const feedHandle = `@${mutedHandle}`;
      this.forYouPosts.update((items) => items.filter((post) => post.handle !== feedHandle));
      this.followingPosts.update((items) => items.filter((post) => post.handle !== feedHandle));
    }
    this.loadFollowing();
    this.loadForYou();
  }

  private loadViewedProfilePosts(profile: ApiProfile, cursor?: string): void {
    const viewerId = this.currentUser()?.id;
    if (!viewerId) return;
    this.viewedProfileBusy.set(true);
    this.viewedProfileError.set('');
    this.api.profilePosts(profile.handle, cursor).subscribe({
      next: ({ items, nextCursor }) => {
        if (this.currentUser()?.id !== viewerId || this.viewedProfile()?.handle !== profile.handle) return;
        const mapped = items.map((post) => toProfileDemoPost(post, profile));
        this.viewedProfilePosts.update((current) => cursor ? [...current, ...mapped] : mapped);
        this.viewedProfileNextCursor.set(nextCursor);
        this.viewedProfileBusy.set(false);
      },
      error: (error: unknown) => {
        if (this.currentUser()?.id !== viewerId || this.viewedProfile()?.handle !== profile.handle) return;
        this.viewedProfileError.set(apiFailureMessage(error));
        this.viewedProfileBusy.set(false);
      },
    });
  }

  updateComposeText(event: Event): void {
    this.composeText.set((event.target as HTMLTextAreaElement).value);
  }

  updateReplyText(event: Event): void {
    this.replyText.set((event.target as HTMLInputElement).value);
  }

  startConversation(conversationId: string): void {
    this.conversationId.set(conversationId);
    this.conversationMessages.set([]);
    this.messageCursor.set(null);
    this.messagesError.set('');
    this.loadConversationMessages(conversationId);
    this.stopMessageRefresh();
    this.messageRefreshTimer = window.setInterval(() => {
      if (this.page() === 'messages' && this.conversationId() === conversationId && document.visibilityState === 'visible') {
        this.loadConversationMessages(conversationId, true);
      }
    }, 4000);
  }

  closeConversation(): void {
    this.stopMessageRefresh();
    this.conversationId.set(null);
    this.conversationMessages.set([]);
    this.messageCursor.set(null);
    this.messagesError.set('');
    this.loadConversations();
  }

  updateMessageText(event: Event): void {
    this.messageText.set((event.target as HTMLInputElement).value);
  }

  sendMessage(): void {
    const text = this.messageText().trim();
    const selectedId = this.conversationId();
    const user = this.currentUser();
    if (!text || !selectedId || !user || this.messageSendBusy()) return;
    const id = crypto.randomUUID();
    const optimistic: ApiDirectMessage = { id, senderId: user.id, body: text, createdAt: new Date().toISOString() };
    this.conversationMessages.update((items) => [...items, optimistic]);
    this.messageText.set('');
    this.messageSendBusy.set(true);
    this.messagesError.set('');
    this.api.sendMessage(selectedId, text, id).subscribe({
      next: (message) => {
        if (this.conversationId() !== selectedId || this.currentUser()?.id !== user.id) return;
        this.conversationMessages.update((items) => items.map((item) => item.id === id ? message : item));
        this.conversations.update((items) => items.map((item) => item.id === selectedId
          ? { ...item, lastMessage: message.body, updatedAt: message.createdAt }
          : item,
        ).sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt)));
        this.messageSendBusy.set(false);
      },
      error: (error: unknown) => {
        if (this.currentUser()?.id !== user.id) return;
        this.conversationMessages.update((items) => items.filter((item) => item.id !== id));
        this.messageText.set(text);
        this.messageSendBusy.set(false);
        this.messagesError.set(apiFailureMessage(error));
      },
    });
  }

  startConversationWithProfile(): void {
    const profile = this.viewedProfile();
    if (!profile || !this.currentUser()) return;
    this.api.startConversation(profile.handle).subscribe({
      next: ({ conversation }) => {
        this.conversations.update((items) => [conversation, ...items.filter((item) => item.id !== conversation.id)]);
        this.page.set('messages');
        this.viewedProfile.set(null);
        this.startConversation(conversation.id);
      },
      error: (error: unknown) => this.notify(apiFailureMessage(error)),
    });
  }

  conversationTime(timestamp: string): string {
    const elapsed = Math.max(0, Math.floor((Date.now() - Date.parse(timestamp)) / 60_000));
    if (elapsed < 1) return 'vừa xong';
    if (elapsed < 60) return `${elapsed} phút`;
    if (elapsed < 1_440) return `${Math.floor(elapsed / 60)} giờ`;
    return `${Math.floor(elapsed / 1_440)} ngày`;
  }

  private loadConversations(): void {
    const viewerId = this.currentUser()?.id;
    if (!viewerId) return;
    this.conversationsBusy.set(true);
    this.conversationsError.set('');
    this.api.conversations().subscribe({
      next: ({ items }) => {
        if (this.currentUser()?.id !== viewerId) return;
        this.conversations.set(items);
        this.conversationsBusy.set(false);
      },
      error: (error: unknown) => {
        if (this.currentUser()?.id !== viewerId) return;
        this.conversationsError.set(apiFailureMessage(error));
        this.conversationsBusy.set(false);
      },
    });
  }

  private loadConversationMessages(conversationId: string, quiet = false): void {
    const viewerId = this.currentUser()?.id;
    if (!viewerId || (quiet && (this.messageSendBusy() || this.messagesBusy()))) return;
    if (!quiet) {
      this.messagesBusy.set(true);
      this.messagesError.set('');
    }
    this.api.conversationMessages(conversationId).subscribe({
      next: ({ items, nextCursor }) => {
        if (this.currentUser()?.id !== viewerId || this.conversationId() !== conversationId) return;
        if (quiet) {
          const merged = new Map([...this.conversationMessages(), ...items].map((item) => [item.id, item]));
          this.conversationMessages.set([...merged.values()].sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt) || a.id.localeCompare(b.id)));
        } else {
          this.conversationMessages.set(items);
          this.messageCursor.set(nextCursor);
        }
        this.messagesBusy.set(false);
      },
      error: (error: unknown) => {
        if (this.currentUser()?.id !== viewerId || this.conversationId() !== conversationId) return;
        if (!quiet) this.messagesError.set(apiFailureMessage(error));
        this.messagesBusy.set(false);
      },
    });
  }

  loadOlderMessages(): void {
    const conversationId = this.conversationId();
    const cursor = this.messageCursor();
    const viewerId = this.currentUser()?.id;
    if (!conversationId || !cursor || !viewerId || this.messagesBusy()) return;
    this.messagesBusy.set(true);
    this.api.conversationMessages(conversationId, cursor).subscribe({
      next: ({ items, nextCursor }) => {
        if (this.currentUser()?.id !== viewerId || this.conversationId() !== conversationId) return;
        const merged = new Map([...items, ...this.conversationMessages()].map((item) => [item.id, item]));
        this.conversationMessages.set([...merged.values()].sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt) || a.id.localeCompare(b.id)));
        this.messageCursor.set(nextCursor);
        this.messagesBusy.set(false);
      },
      error: (error: unknown) => {
        if (this.currentUser()?.id !== viewerId || this.conversationId() !== conversationId) return;
        this.messagesError.set(apiFailureMessage(error));
        this.messagesBusy.set(false);
      },
    });
  }

  private stopMessageRefresh(): void {
    if (this.messageRefreshTimer !== null) window.clearInterval(this.messageRefreshTimer);
    this.messageRefreshTimer = null;
  }

  async startVideoRecording(): Promise<void> {
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') {
      this.videoError.set('Thiết bị hoặc trình duyệt này chưa hỗ trợ quay video trong Ionic.');
      return;
    }
    this.videoError.set('');
    this.clearVideoSelection();
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: true,
        video: { facingMode: { ideal: 'environment' }, width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 30, max: 30 } },
      });
      if (this.page() !== 'video') {
        stream.getTracks().forEach((track) => track.stop());
        return;
      }
      this.videoStream = stream;
      this.videoChunks = [];
      const mimeType = ['video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm']
        .find((candidate) => MediaRecorder.isTypeSupported(candidate));
      this.videoRecorder = new MediaRecorder(stream, {
        ...(mimeType ? { mimeType } : {}),
        videoBitsPerSecond: 2_000_000,
        audioBitsPerSecond: 96_000,
      });
      this.videoRecorder.ondataavailable = (event: BlobEvent) => {
        if (event.data.size) this.videoChunks.push(event.data);
      };
      this.videoRecorder.onstop = () => {
        if (this.videoStopTimer !== null) window.clearTimeout(this.videoStopTimer);
        this.videoStopTimer = null;
        const chunks = this.videoChunks;
        this.videoChunks = [];
        const type = this.videoRecorder?.mimeType || 'video/webm';
        this.videoStream?.getTracks().forEach((track) => track.stop());
        this.videoStream = null;
        const cameraPreview = document.getElementById('ionic-camera-preview') as HTMLVideoElement | null;
        if (cameraPreview) cameraPreview.srcObject = null;
        this.videoRecorder = null;
        this.videoRecording.set(false);
        if (chunks.length) this.showVideoFile(new File([new Blob(chunks, { type })], `ionic-${Date.now()}.webm`, { type }));
      };
      this.videoRecorder.start(1000);
      this.videoRecording.set(true);
      window.requestAnimationFrame(() => {
        const preview = document.getElementById('ionic-camera-preview') as HTMLVideoElement | null;
        if (!preview || this.videoStream !== stream) return;
        preview.srcObject = stream;
        void preview.play().catch(() => undefined);
      });
      this.videoStopTimer = window.setTimeout(() => this.stopVideoRecording(), 60_000);
    } catch {
      this.videoStream?.getTracks().forEach((track) => track.stop());
      this.videoStream = null;
      this.videoRecording.set(false);
      this.videoError.set('Không thể mở camera hoặc micro. Hãy cấp quyền thiết bị rồi thử lại.');
    }
  }

  stopVideoRecording(): void {
    if (this.videoStopTimer !== null) window.clearTimeout(this.videoStopTimer);
    this.videoStopTimer = null;
    if (this.videoRecorder?.state === 'recording') this.videoRecorder.stop();
    else {
      this.videoStream?.getTracks().forEach((track) => track.stop());
      this.videoStream = null;
      this.videoRecording.set(false);
    }
  }

  selectVideoFile(event: Event): void {
    const input = event.target as HTMLInputElement;
    const file = input.files?.[0];
    input.value = '';
    if (!file) return;
    if (!['video/webm', 'video/mp4'].includes(file.type)) {
      this.videoError.set('Chọn tệp video WebM hoặc MP4.');
      return;
    }
    if (file.size > 60 * 1024 * 1024) {
      this.videoError.set('Video vượt quá giới hạn tải lên 60 MB.');
      return;
    }
    this.videoInspecting.set(true);
    const probeUrl = URL.createObjectURL(file);
    const probe = document.createElement('video');
    probe.preload = 'metadata';
    probe.onloadedmetadata = () => {
      URL.revokeObjectURL(probeUrl);
      this.videoInspecting.set(false);
      if (!Number.isFinite(probe.duration) || probe.duration > 60) {
        this.videoError.set('Video cần có thời lượng từ 60 giây trở xuống.');
        return;
      }
      this.videoError.set('');
      this.showVideoFile(file);
    };
    probe.onerror = () => {
      URL.revokeObjectURL(probeUrl);
      this.videoInspecting.set(false);
      this.videoError.set('Không đọc được video này. Hãy chọn tệp WebM hoặc MP4 khác.');
    };
    probe.src = probeUrl;
  }

  setVideoCaption(event: Event): void {
    this.videoCaption.set((event.target as HTMLTextAreaElement).value);
  }

  uploadVideo(): void {
    const file = this.videoFile();
    const caption = this.videoCaption().trim();
    if (!file || !caption || caption.length > 280 || this.videoPublishing()) return;
    this.videoPublishing.set(true);
    this.videoError.set('');
    this.api.uploadVideo(file, caption).subscribe({
      next: (video) => {
        this.videoItems.update((items) => [video, ...items.filter((item) => item.id !== video.id)]);
        this.videoPublishing.set(false);
        this.clearVideoSelection();
        this.videoCaption.set('');
        this.notify('Video đã được lưu riêng tư trong tài khoản của bạn.');
      },
      error: (error: unknown) => {
        this.videoPublishing.set(false);
        this.videoError.set(apiFailureMessage(error));
      },
    });
  }

  videoPlaybackUrl(contentId: string): string {
    return this.api.videoFileUrl(contentId);
  }

  clearVideoSelection(): void {
    const current = this.videoPreviewUrl();
    if (current) URL.revokeObjectURL(current);
    this.videoPreviewUrl.set(null);
    this.videoFile.set(null);
  }

  private showVideoFile(file: File): void {
    this.clearVideoSelection();
    this.videoFile.set(file);
    this.videoPreviewUrl.set(URL.createObjectURL(file));
  }

  private loadVideos(): void {
    const viewerId = this.currentUser()?.id;
    if (!viewerId) return;
    this.videoBusy.set(true);
    this.videoError.set('');
    this.api.videos().subscribe({
      next: ({ items }) => {
        if (this.currentUser()?.id !== viewerId) return;
        this.videoItems.set(items);
        this.videoBusy.set(false);
      },
      error: (error: unknown) => {
        if (this.currentUser()?.id !== viewerId) return;
        this.videoBusy.set(false);
        this.videoError.set(apiFailureMessage(error));
      },
    });
  }

  togglePersonalization(): void {
    const paused = !this.personalizationPaused();
    if (this.currentUser()) {
      if (this.personalizationBusy()) return;
      this.personalizationBusy.set(true);
      this.api.updateFeedSettings(paused).subscribe({
        next: (settings) => {
          this.personalizationBusy.set(false);
          this.personalizationPaused.set(settings.paused);
          this.notify(settings.paused ? 'Đã tạm dừng cập nhật tùy chỉnh từ thao tác mới.' : 'Đã bật cập nhật tùy chỉnh.');
        },
        error: (error: unknown) => {
          this.personalizationBusy.set(false);
          this.notify(apiFailureMessage(error));
        },
      });
      return;
    }
    this.personalizationPaused.set(paused);
    this.notify(this.personalizationPaused() ? 'Đã tạm dừng mô phỏng cá nhân hóa.' : 'Đã bật mô phỏng cá nhân hóa.');
  }

  openPreferences(): void {
    this.preferencesOpen.set(true);
  }

  resetPreferences(): void {
    if (this.currentUser()) {
      this.api.resetFeedPreferences().subscribe({
        next: () => {
          this.lessTopics.set(new Set());
          this.preferredTopics.set(new Set());
          this.personalizationPaused.set(false);
          this.forYouPosts.set([]);
          this.forYouNextCursor.set(null);
          this.preferencesOpen.set(false);
          this.loadForYou();
          this.notify('Đã xóa các tùy chọn cá nhân hóa.');
        },
        error: (error: unknown) => this.notify(apiFailureMessage(error)),
      });
      return;
    }
    this.lessTopics.set(new Set());
    this.preferredTopics.set(new Set());
    this.personalizationPaused.set(false);
    this.preferencesOpen.set(false);
    this.notify('Đã đặt lại tùy chọn trong phiên demo.');
  }

  private notify(message: string): void {
    this.showToast.set(message);
    window.setTimeout(() => {
      if (this.showToast() === message) this.showToast.set('');
    }, 3200);
  }

  private findPost(postId: string): DemoPost | undefined {
    return [
      ...this.forYouPosts(), ...this.followingPosts(), ...this.viewedProfilePosts(), ...this.accountPosts(), ...this.posts(),
    ].find((post) => post.id === postId);
  }

  private updatePost(postId: string, update: (post: DemoPost) => DemoPost): void {
    for (const posts of [this.posts, this.accountPosts, this.forYouPosts, this.followingPosts, this.viewedProfilePosts]) {
      posts.update((items) => items.map((post) => post.id === postId ? update(post) : post));
    }
  }

  private setPostActionBusy(actionKey: string, busy: boolean): void {
    this.postActionBusy.update((current) => {
      const next = new Set(current);
      if (busy) next.add(actionKey);
      else next.delete(actionKey);
      return next;
    });
  }
}

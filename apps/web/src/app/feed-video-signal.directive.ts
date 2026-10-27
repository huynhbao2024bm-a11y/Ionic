import { Directive, ElementRef, Input, OnDestroy, OnInit, inject } from '@angular/core';
import { IonicApiService } from './ionic-api.service';

const activeViewThresholdMs = 3_000;
const minimumSkipPlaybackMs = 800;

@Directive({
  selector: 'video[ionicVideoSignal]',
  standalone: true,
})
export class FeedVideoSignalDirective implements OnInit, OnDestroy {
  @Input({ required: true }) ionicVideoSignal = '';

  private readonly element = inject(ElementRef<HTMLVideoElement>).nativeElement;
  private readonly api = inject(IonicApiService);
  private observer?: IntersectionObserver;
  private activeTimer?: number;
  private activeSince: number | null = null;
  private activePlaybackMs = 0;
  private isVisible = false;
  private isPlaying = false;
  private signalSent = false;

  private readonly onPlaying = (): void => {
    this.isPlaying = true;
    this.syncPlaybackClock();
  };

  private readonly onInterrupted = (): void => {
    this.isPlaying = false;
    this.syncPlaybackClock();
  };

  private readonly onEnded = (): void => {
    this.isPlaying = false;
    this.syncPlaybackClock();
    const durationMs = this.element.duration * 1_000;
    const completionThreshold = Number.isFinite(durationMs) && durationMs > 0
      ? Math.min(activeViewThresholdMs, durationMs * 0.75)
      : activeViewThresholdMs;
    if (!this.signalSent && this.activePlaybackMs >= completionThreshold) {
      this.sendSignal('active_view');
    }
  };

  private readonly onVisibilityChange = (): void => this.syncPlaybackClock();

  ngOnInit(): void {
    if (typeof IntersectionObserver === 'undefined') return;
    this.observer = new IntersectionObserver(([entry]) => {
      if (!entry) return;
      const wasVisible = this.isVisible;
      this.isVisible = entry.isIntersecting && entry.intersectionRatio >= 0.5;
      this.syncPlaybackClock();
      if (wasVisible && !this.isVisible) this.recordFastSkip();
    }, { threshold: [0, 0.5] });
    this.observer.observe(this.element);
    this.element.addEventListener('playing', this.onPlaying);
    this.element.addEventListener('pause', this.onInterrupted);
    this.element.addEventListener('waiting', this.onInterrupted);
    this.element.addEventListener('ended', this.onEnded);
    document.addEventListener('visibilitychange', this.onVisibilityChange);
  }

  ngOnDestroy(): void {
    this.stopPlaybackClock();
    this.observer?.disconnect();
    this.element.removeEventListener('playing', this.onPlaying);
    this.element.removeEventListener('pause', this.onInterrupted);
    this.element.removeEventListener('waiting', this.onInterrupted);
    this.element.removeEventListener('ended', this.onEnded);
    document.removeEventListener('visibilitychange', this.onVisibilityChange);
  }

  private syncPlaybackClock(): void {
    const shouldCount = this.isVisible && this.isPlaying && document.visibilityState === 'visible' && !this.signalSent;
    if (!shouldCount) {
      this.stopPlaybackClock();
      return;
    }
    if (this.activeSince !== null) return;

    this.activeSince = performance.now();
    const remainingMs = Math.max(0, activeViewThresholdMs - this.activePlaybackMs);
    this.activeTimer = window.setTimeout(() => {
      this.stopPlaybackClock();
      if (this.activePlaybackMs >= activeViewThresholdMs) this.sendSignal('active_view');
      else this.syncPlaybackClock();
    }, remainingMs);
  }

  private stopPlaybackClock(): void {
    if (this.activeTimer !== undefined) {
      window.clearTimeout(this.activeTimer);
      this.activeTimer = undefined;
    }
    if (this.activeSince !== null) {
      this.activePlaybackMs += Math.max(0, performance.now() - this.activeSince);
      this.activeSince = null;
    }
  }

  private recordFastSkip(): void {
    if (
      !this.signalSent &&
      this.activePlaybackMs >= minimumSkipPlaybackMs &&
      this.activePlaybackMs < activeViewThresholdMs
    ) {
      this.sendSignal('skip');
    }
  }

  private sendSignal(kind: 'active_view' | 'skip'): void {
    if (this.signalSent || !this.ionicVideoSignal) return;
    this.signalSent = true;
    this.api.recordVideoSignal(this.ionicVideoSignal, crypto.randomUUID(), kind).subscribe({
      error: () => undefined,
    });
  }
}

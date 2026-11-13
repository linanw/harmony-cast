import { audio } from '@kit.AudioKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import cast from 'libcast.so';

// Serialize every volume change, including disconnect and recovery after restart.
export class AudioOutput {
  readonly ready: Promise<void>;
  private manager = audio.getAudioManager();
  private store: preferences.Preferences;
  private timer: number = -1;
  private busy = false;
  private work: Promise<void> = Promise.resolve();
  private processed = 0;
  private notify: (message: string) => void;

  constructor(context: common.UIAbilityContext, notify: (message: string) => void) {
    this.notify = notify;
    this.store = preferences.getPreferencesSync(context, { name: 'audioRestore' });
    this.ready = this.restore().then(() => {
      this.timer = setInterval(() => this.poll(), 100);
    });
  }

  private async muteTablet(): Promise<void> {
    const type = audio.AudioVolumeType.MEDIA;
    if (!(this.store.getSync('pending', false) as boolean)) {
      this.store.putSync('muted', await this.manager.isMute(type));
      this.store.putSync('volume', await this.manager.getVolume(type));
      this.store.putSync('pending', true);
      this.store.flushSync(); // Persist recovery before changing system state.
      hilog.info(0, 'CastAudio', 'SAVED volume=%{public}d muted=%{public}s',
        this.store.getSync('volume', 0) as number, `${this.store.getSync('muted', false)}`);
    }
    // Deprecated public API, verified on this MatePad; current replacements
    // only show a volume panel and cannot perform a remote automatic handoff.
    if (!(await this.manager.isMute(type))) { await this.manager.mute(type, true); }
    if (!(await this.manager.isMute(type))) { throw new Error('平板未能静音'); }
  }

  private async restoreNow(): Promise<void> {
    if (!(this.store.getSync('pending', false) as boolean)) { return; }
    const type = audio.AudioVolumeType.MEDIA;
    const muted = this.store.getSync('muted', false) as boolean;
    const volume = this.store.getSync('volume', 0) as number;
    if (muted || volume === 0) {
      await this.manager.mute(type, true);
    } else {
      await this.manager.setVolume(type, volume);
      await this.manager.mute(type, false);
    }
    if ((await this.manager.isMute(type)) !== (muted || volume === 0) ||
      (!muted && volume > 0 && (await this.manager.getVolume(type)) !== volume)) {
      throw new Error('无法恢复平板音量，请在平板调整音量');
    }
    this.store.putSync('pending', false);
    this.store.flushSync();
    hilog.info(0, 'CastAudio', 'RESTORED volume=%{public}d muted=%{public}s', volume, `${muted}`);
  }

  private poll(): void {
    if (this.busy) { return; }
    const request = cast.audioRequest();
    if (request.live && request.serial === this.processed) { return; }
    if (!request.live && !(this.store.getSync('pending', false) as boolean)) {
      this.processed = 0; return;
    }
    this.busy = true;
    this.work = this.work.then(async () => {
      try {
        if (request.live && request.enabled) { await this.muteTablet(); }
        else { await this.restoreNow(); }
        this.processed = request.live ? request.serial : 0;
        if (request.live) {
          cast.audioReply(request.serial, request.enabled, true);
          hilog.info(0, 'CastAudio', 'ACK serial=%{public}d mac=%{public}s muted=%{public}s',
            request.serial, `${request.enabled}`, `${await this.manager.isMute(audio.AudioVolumeType.MEDIA)}`);
        } else {
          this.notify('已恢复平板声音');
        }
      } catch (error) {
        this.processed = request.serial;
        cast.audioReply(request.serial, false, false);
        try { await this.restoreNow(); } catch { /* Retain journal for retry. */ }
        this.notify(`声音切换失败：${error.message}`);
        hilog.error(0, 'CastAudio', 'FAILED %{public}s', JSON.stringify(error));
      }
    }).finally(() => { this.busy = false; });
  }

  restore(): Promise<void> {
    this.processed = 0;
    this.work = this.work.then(() => this.restoreNow()).catch((error: Error) => {
      this.notify(`恢复声音失败：${error.message}`);
      // Keep recovery durable. A subsequent stop or next launch retries it.
    });
    return this.work;
  }

  close(): void {
    clearInterval(this.timer);
    this.restore();
  }
}

import cast from 'libcast.so';
import { display } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { MacDevice, MacDiscovery } from '../services/MacDiscovery';
import { AudioOutput } from '../services/AudioOutput';

@Entry
@Component
struct Index {
  @State host: string = '';
  @State code: string = '';
  @State message: string = '';
  @State discoveryMessage: string = '正在寻找附近的 Mac…';
  @State devices: MacDevice[] = [];
  @State lastMac: string = '';
  @State connectedName: string = '';
  @State showManual: boolean = false;
  @State connecting: boolean = false;
  @State stopping: boolean = false;
  @State active: boolean = false;
  private timer: number = -1;
  private backgroundTaskActive: boolean = false;
  private pageVisible: boolean = false;
  private discovery?: MacDiscovery;
  private audioOutput?: AudioOutput;

  aboutToAppear(): void {
    this.pageVisible = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.audioOutput = new AudioOutput(context, (message: string) => { this.message = message; });
    try {
      const store = preferences.getPreferencesSync(context, { name: 'cast' });
      this.host = store.getSync('host', '') as string;
      this.lastMac = store.getSync('lastMac', '') as string;
    } catch { /* Discovery also works without saved preferences. */ }
    this.discovery = new MacDiscovery(context, (devices: MacDevice[]) => {
      this.devices = devices.sort((a: MacDevice, b: MacDevice) => {
        if (a.id === this.lastMac) { return -1; }
        if (b.id === this.lastMac) { return 1; }
        return a.name.localeCompare(b.name);
      });
    }, (message: string) => { this.discoveryMessage = message; });
    this.discovery.start();
    this.timer = setInterval(() => {
      if (this.active) {
        this.message = cast.status();
        if (this.message.includes('断开') || this.message.includes('结束') ||
          this.message.includes('错误') || this.message.includes('过慢')) {
          this.stop();
        }
      }
    }, 500);
  }

  aboutToDisappear(): void {
    this.pageVisible = false;
    clearInterval(this.timer);
    this.discovery?.stop();
    if (!this.connecting) { this.stop(); }
    this.audioOutput?.close();
  }

  onBackPress(): boolean {
    if (this.active || this.connecting) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      try { context.moveAbilityToBackground().catch(() => {}); }
      catch { /* Keep casting if the system cannot background this window. */ }
      return true;
    }
    return false;
  }

  private async stop(): Promise<void> {
    if (this.stopping) { return; }
    this.stopping = true;
    this.active = false;
    cast.stop();
    await this.audioOutput?.restore();
    if (this.backgroundTaskActive) {
      this.backgroundTaskActive = false;
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      try { await backgroundTaskManager.stopBackgroundRunning(context); }
      catch { /* The system may already have stopped the task. */ }
    }
    this.stopping = false;
    if (this.pageVisible) { this.discovery?.start(); }
  }

  private async start(device?: MacDevice): Promise<void> {
    if (this.connecting || this.active || this.stopping) { return; }
    this.connecting = true;
    this.connectedName = device?.name ?? 'Mac';
    this.message = `正在连接 ${this.connectedName}`;
    try {
      let address = this.host.trim();
      let code = this.code.trim();
      let port = 47999;
      if (device) {
        if (!this.discovery) { throw new Error('请重新搜索 Mac'); }
        const current = await this.discovery.resolve(device);
        address = current.host;
        code = current.code;
        port = current.port;
      }
      if (!this.pageVisible) { throw new Error('连接已取消'); }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: 'me.harmony.cast.sender', abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.AUDIO_RECORDING, agent);
      this.backgroundTaskActive = true;
      const screen = display.getDefaultDisplaySync();
      const scale = Math.min(1, 1920 / Math.max(screen.width, screen.height));
      const width = Math.floor(screen.width * scale / 2) * 2;
      const height = Math.floor(screen.height * scale / 2) * 2;
      await this.audioOutput?.ready;
      await cast.start(address, code, width, height, port);
      if (!this.pageVisible) { await this.stop(); return; }
      this.active = true;
      this.discovery?.stop();
      this.message = cast.status();
      if (device) { this.lastMac = device.id; }
      this.host = address;
      try {
        const store = preferences.getPreferencesSync(context, { name: 'cast' });
        store.putSync('host', address);
        store.putSync('lastMac', this.lastMac);
        store.flushSync();
      } catch { /* A preference write failure must not end an active cast. */ }
    } catch (error) {
      this.message = `${error.message}`;
      await this.stop();
    } finally {
      this.connecting = false;
    }
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Text('投屏到 Mac').fontSize(32).fontWeight(FontWeight.Bold)
        Text('同一局域网，点选 Mac 即可连接').fontSize(16).fontColor('#555555')
        if (this.active || this.connecting) {
          Text(this.connectedName).fontSize(21).fontWeight(FontWeight.Medium).maxLines(2)
          Button(this.connecting ? '正在连接…' : '停止投屏').width('100%').height(50)
            .enabled(!this.connecting && !this.stopping)
            .onClick(() => { this.message = '已停止投屏'; this.stop(); })
        } else {
          Column({ space: 12 }) {
            ForEach(this.devices, (device: MacDevice) => {
              Button() {
                Row({ space: 16 }) {
                  Column({ space: 6 }) {
                    Text(device.name).fontSize(20).fontWeight(FontWeight.Medium)
                      .fontColor('#17202E').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(device.id === this.lastMac ? '上次连接 · 点一下开始投屏' : '可连接 · 点一下开始投屏')
                      .fontSize(14).fontColor('#586575')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text('连接').fontSize(17).fontColor('#0A59F7')
                }.width('100%').padding(20)
              }
              .type(ButtonType.Normal).borderRadius(16).backgroundColor('#EDF3FF')
              .width('100%').enabled(!this.stopping).onClick(() => { this.start(device); })
            }, (device: MacDevice) => device.id)
          }.width('100%')
          Text(this.discoveryMessage).fontSize(15).fontColor('#555555').width('100%')
          Button('重新搜索').type(ButtonType.Normal).backgroundColor(Color.Transparent)
            .fontColor('#0A59F7').enabled(!this.stopping).onClick(() => { this.discovery?.start(); })
          Button(this.showManual ? '收起手动连接' : '手动连接').type(ButtonType.Normal)
            .backgroundColor(Color.Transparent).fontColor('#666666')
            .onClick(() => { this.showManual = !this.showManual; })
          if (this.showManual) {
            TextInput({ placeholder: 'Mac 地址', text: this.host })
              .onChange((value: string) => { this.host = value; })
            TextInput({ placeholder: '六位连接码', text: this.code }).type(InputType.Number).maxLength(6)
              .onChange((value: string) => { this.code = value; })
            Button('连接此地址').width('100%').height(48)
              .enabled(!this.stopping && this.host.length > 0 && this.code.length === 6)
              .onClick(() => { this.start(); })
          }
        }
        if (this.message.length > 0) {
          Text(this.message).fontSize(15).fontColor('#555555').width('100%')
        }
        Text('开始后，在系统提示中允许共享屏幕。Mac 开启声音时平板自动静音；关闭或断开时恢复平板原来的媒体音量。')
          .fontSize(14).fontColor('#777777')
      }.width('100%').constraintSize({ maxWidth: 560 }).padding(32)
    }.width('100%').height('100%').backgroundColor('#FFFFFF')
  }
}

import { mdns } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';

export interface MacDevice {
  id: string;
  name: string;
  serviceName: string;
  host: string;
  port: number;
  code: string;
}

// Keep resolving separate from the page: late responses after refresh/serviceLost
// must never put an offline Mac back into the list.
export class MacDiscovery {
  private service?: mdns.DiscoveryService;
  private generation: number = 0;
  private emptyTimer: number = -1;
  private found: Map<string, mdns.LocalServiceInfo> = new Map();
  private devices: Map<string, MacDevice> = new Map();
  private resolving: Set<string> = new Set();
  private context: common.UIAbilityContext;
  private changed: (devices: MacDevice[]) => void;
  private status: (message: string) => void;

  constructor(context: common.UIAbilityContext,
    changed: (devices: MacDevice[]) => void,
    status: (message: string) => void) {
    this.context = context;
    this.changed = changed;
    this.status = status;
  }

  start(): void {
    this.stop();
    const session = this.generation;
    this.changed([]);
    this.status('正在寻找附近的 Mac…');
    try {
      const service = mdns.createDiscoveryService(this.context, '_harmonycast._tcp');
      this.service = service;
      service.on('discoveryStart', (event: mdns.DiscoveryEventInfo) => {
        if (session !== this.generation) { return; }
        if (event.errorCode !== undefined) { this.status('搜索暂时不可用，请点「重新搜索」'); }
      });
      service.on('serviceFound', (info: mdns.LocalServiceInfo) => {
        if (session !== this.generation) { return; }
        this.found.set(info.serviceName, info);
        this.resolveFound(info, session);
      });
      service.on('serviceLost', (info: mdns.LocalServiceInfo) => {
        if (session !== this.generation) { return; }
        this.found.delete(info.serviceName);
        this.devices.delete(info.serviceName);
        this.publish();
      });
      service.startSearchingMDNS();
      this.emptyTimer = setTimeout(() => {
        if (session === this.generation && this.devices.size === 0) {
          this.status('还没找到 Mac。请打开 Mac 上的「鸿蒙投屏」，并连接同一局域网。');
        }
      }, 8000);
    } catch {
      this.status('无法开始搜索，请检查网络后重试');
    }
  }

  stop(): void {
    this.generation++;
    clearTimeout(this.emptyTimer);
    if (this.service) {
      try {
        this.service.off('serviceFound');
        this.service.off('serviceLost');
        this.service.off('discoveryStart');
        this.service.stopSearchingMDNS();
      } catch { /* A network change can already have stopped the browser. */ }
      this.service = undefined;
    }
    this.found.clear();
    this.devices.clear();
    this.resolving.clear();
  }

  // Resolve again on tap, because the Mac may have restarted or changed address.
  async resolve(device: MacDevice): Promise<MacDevice> {
    const info: mdns.LocalServiceInfo = {
      serviceType: '_harmonycast._tcp', serviceName: device.serviceName
    };
    const current = this.parse(await this.resolveWithTimeout(info));
    if (current.id !== device.id) { throw new Error('设备信息已改变，请重新搜索后连接'); }
    return current;
  }

  private async resolveFound(info: mdns.LocalServiceInfo, session: number): Promise<void> {
    const key = info.serviceName;
    if (this.resolving.has(key)) { return; }
    this.resolving.add(key);
    try {
      const device = this.parse(await this.resolveWithTimeout(info));
      if (session !== this.generation || this.found.get(key) !== info) { return; }
      this.devices.set(key, device);
      this.publish();
    } catch {
      if (session === this.generation && this.devices.size === 0) {
        this.status('正在确认 Mac 的连接信息，可稍后点「重新搜索」');
      }
    } finally {
      if (session === this.generation) {
        this.resolving.delete(key);
        const pending = this.found.get(key);
        if (pending && pending !== info) { this.resolveFound(pending, session); }
      }
    }
  }

  private resolveWithTimeout(info: mdns.LocalServiceInfo): Promise<mdns.LocalServiceInfo> {
    return new Promise<mdns.LocalServiceInfo>((resolve, reject) => {
      const timer = setTimeout(() => { reject(new Error('Mac 响应超时，请重新搜索')); }, 8000);
      try {
        mdns.resolveLocalService(this.context, info).then((result: mdns.LocalServiceInfo) => {
          clearTimeout(timer);
          resolve(result);
        }).catch(() => {
          clearTimeout(timer);
          reject(new Error('暂时无法连接这台 Mac，请重新搜索'));
        });
      } catch {
        clearTimeout(timer);
        reject(new Error('无法读取 Mac 的连接信息'));
      }
    });
  }

  private attribute(info: mdns.LocalServiceInfo, key: string): string {
    const item = info.serviceAttribute?.find((entry: mdns.ServiceAttribute) => entry.key === key);
    if (!item || item.value.length > 128) { return ''; }
    return item.value.map((value: number) => String.fromCharCode(value)).join('');
  }

  private parse(info: mdns.LocalServiceInfo): MacDevice {
    const code = this.attribute(info, 'code');
    const id = this.attribute(info, 'id');
    const host = info.host?.address ?? '';
    const port = info.port ?? 0;
    if (this.attribute(info, 'v') !== '1' || !/^[0-9]{6}$/.test(code) ||
      !/^[0-9a-fA-F-]{36}$/.test(id) || host.length === 0 || host.length > 128 ||
      port < 1 || port > 65535) {
      throw new Error('请将 Mac 接收端更新到支持自动发现的版本');
    }
    return { id: id, name: info.serviceName, serviceName: info.serviceName,
      host: host, port: port, code: code };
  }

  private publish(): void {
    const unique: Map<string, MacDevice> = new Map();
    this.devices.forEach((device: MacDevice) => { unique.set(device.id, device); });
    const list = Array.from(unique.values());
    this.changed(list);
    this.status(list.length > 0 ? '点选 Mac 即可投屏' : '正在寻找附近的 Mac…');
  }
}

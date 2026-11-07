// FileManagerWindow.ets —— 子窗口：文件（iPhone / AFC）
//
// 2026-11-02 接入真 AFC：native 侧（OhosIosAfc）完成 lockdown
// StartSession → TLS（主机证书来自配对记录）→ StartService(com.apple.afc)
// → 独立 mux 隧道 + TLS → AFC 帧协议；本窗口只管浏览与操作。
//
// 浏览范围说明：AFC 看到的是 iPhone 的「媒体库沙箱」（DCIM 照片视频、
// Downloads、Recordings 等），与「文件」App 的 iCloud/第三方目录不同 ——
// 那些走的是 com.apple.mobile.fileprovider，后续再接。

import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  SubWindowShell, SubWindowHost, PrimaryButton,
  SubWindowSpec, SUBWINDOW_ROW_GAP,
} from '../../common/SubWindow';
import { TEXT, MUTED_TEXT, SETTINGS_SECTION_PADDING } from '../../common/Theme';
import { current_cached_fd, open_usb_fd_channel } from '../../common/UsbManagerHost';
import {
  afcConnect, afcListDir, afcReadFile, afcRemove,
  AfcEntry, AfcDeviceInfo,
} from 'libim_core.so';

const TAG: string = 'im_file_manager';
const DOMAIN: number = 0x0100;

export const WINDOW_NAME: string = 'FileManagerWindow';
export const PAGE_PATH: string = 'pages/windows/FileManagerWindow';

export function open_file_manager(ctx: common.Context): void {
  const spec: SubWindowSpec = {
    name: WINDOW_NAME,
    page: PAGE_PATH,
    title: '文件',
    width: 860,
    height: 640,
    resizable: true,
    minWidth: 640,
    minHeight: 480,
    modal: false,
  };
  SubWindowHost.open(ctx, spec).catch((error: Error): void => {
    hilog.error(DOMAIN, TAG, '打开文件管理窗口失败: %{public}s', error.message);
  });
}

// 文件大小的人类可读形式。
function human_size(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

@Entry
@Component
struct FileManagerWindow {
  @State busy: boolean = false;
  @State statusText: string = '正在连接 iPhone…';
  @State errorText: string = '';
  @State udid: string = '';
  @State currentPath: string = '/';
  @State entries: AfcEntry[] = [];
  private connected: boolean = false;

  aboutToAppear(): void {
    this.connect_and_list();
  }

  /** 拿 fd（复用心跳开的通道，没有就现场开一次）→ afcConnect → 列根目录。 */
  private async connect_and_list(): Promise<void> {
    this.busy = true;
    this.errorText = '';
    try {
      let fd: number = current_cached_fd();
      if (fd < 0) {
        const channel = await open_usb_fd_channel();
        if (!channel.ok) {
          this.errorText = `拿不到 iPhone 的 USB 通道：${channel.summary}`;
          return;
        }
        fd = channel.fd;
      }
      const info: AfcDeviceInfo = await afcConnect(fd);
      this.udid = info.udid;
      this.connected = true;
      await this.list_dir(this.currentPath);
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      this.errorText = `连接失败：${failure.message ?? String(failure)}`;
    } finally {
      this.busy = false;
    }
  }

  private async list_dir(path: string): Promise<void> {
    this.busy = true;
    this.errorText = '';
    try {
      const fd: number = current_cached_fd();
      const list: AfcEntry[] = await afcListDir(fd, path);
      // 目录在前、按名排序；文件按名排序。
      const dirs = list.filter((entry: AfcEntry): boolean => entry.isDir)
        .sort((a: AfcEntry, b: AfcEntry): number =>
          a.name.localeCompare(b.name));
      const files = list.filter((entry: AfcEntry): boolean => !entry.isDir)
        .sort((a: AfcEntry, b: AfcEntry): number =>
          a.name.localeCompare(b.name));
      this.entries = [...dirs, ...files];
      this.currentPath = path;
      this.statusText = path === '/' ? '/' : path;
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      this.errorText = `读取目录失败：${failure.message ?? String(failure)}`;
    } finally {
      this.busy = false;
    }
  }

  /** 进入子目录（点击目录行）。 */
  private async enter_dir(name: string): Promise<void> {
    const next = this.currentPath === '/'
      ? `/${name}` : `${this.currentPath}/${name}`;
    await this.list_dir(next);
  }

  /** 返回上级目录。 */
  private async go_up(): Promise<void> {
    if (this.currentPath === '/') return;
    const index = this.currentPath.lastIndexOf('/');
    const parent = index <= 0 ? '/' : this.currentPath.substring(0, index);
    await this.list_dir(parent);
  }

  /** 把文件读到沙箱 Downloads 目录（同名覆盖）。 */
  private async download_file(entry: AfcEntry): Promise<void> {
    this.busy = true;
    this.errorText = '';
    this.statusText = `正在下载 ${entry.name}…`;
    try {
      const fd: number = current_cached_fd();
      const data: ArrayBuffer = await afcReadFile(fd,
        this.currentPath === '/'
          ? `/${entry.name}` : `${this.currentPath}/${entry.name}`);
      const dir = `${getContext().filesDir}/Downloads`;
      try {
        fs.accessSync(dir);
      } catch {
        fs.mkdirSync(dir, true);
      }
      const file = fs.openSync(`${dir}/${entry.name}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, data);
      fs.closeSync(file);
      this.statusText = `已保存到应用沙箱 Downloads/${entry.name}`;
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      this.errorText = `下载失败：${failure.message ?? String(failure)}`;
    } finally {
      this.busy = false;
    }
  }

  /** 删除（设备侧确认弹窗由 iOS 系统不做 —— AFC 直接删，这里靠 UI 二次确认）。 */
  private async remove_entry(entry: AfcEntry): Promise<void> {
    this.busy = true;
    this.errorText = '';
    try {
      const fd: number = current_cached_fd();
      await afcRemove(fd,
        this.currentPath === '/'
          ? `/${entry.name}` : `${this.currentPath}/${entry.name}`);
      await this.list_dir(this.currentPath);
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      this.errorText = `删除失败：${failure.message ?? String(failure)}`;
    } finally {
      this.busy = false;
    }
  }

  /** 面包屑段：/ → DCIM → 100APPLE。 */
  @Builder
  breadcrumb() {
    Row() {
      Text(this.currentPath === '/' ? '根目录' : this.currentPath)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.currentPath !== '/') {
        Text('上一级')
          .fontSize(12)
          .fontColor(TEXT)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(8)
          .border({ width: 1, color: '#33888888' })
          .onClick((): void => {
            if (!this.busy) {
              this.go_up();
            }
          })
          .margin({ right: 6 })
      }
      Text(this.busy ? '…' : '刷新')
        .fontSize(12)
        .fontColor(TEXT)
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .borderRadius(8)
        .border({ width: 1, color: '#33888888' })
        .onClick((): void => {
          if (!this.busy) {
            this.list_dir(this.currentPath);
          }
        })
    }
    .width('100%')
    .margin({ bottom: 6 })
  }

  @Builder
  entry_row(entry: AfcEntry) {
    Row() {
      Text(entry.isDir ? '📁' : '📄')
        .fontSize(15)
        .margin({ right: 8 })
      Text(entry.name)
        .fontSize(13)
        .fontColor(TEXT)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(entry.isDir ? '' : human_size(entry.size))
        .fontSize(11)
        .fontColor(MUTED_TEXT)
        .margin({ right: 10 })
      if (!entry.isDir) {
        Text('下载')
          .fontSize(11)
          .fontColor('#3A7BD5')
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .borderRadius(6)
          .backgroundColor('#143A7BD5')
          .onClick((): void => {
            if (!this.busy) {
              this.download_file(entry);
            }
          })
      }
      Text('删除')
        .fontSize(11)
        .fontColor('#C0392B')
        .padding({ left: 6, right: 6, top: 3, bottom: 3 })
        .borderRadius(6)
        .backgroundColor('#14C0392B')
        .onClick((): void => {
          if (!this.busy) {
            this.remove_entry(entry);
          }
        })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(8)
    .onClick((): void => {
      if (entry.isDir && !this.busy) {
        this.enter_dir(entry.name);
      }
    })
  }

  @Builder
  file_manager_body() {
    Column() {
      if (this.errorText !== '') {
        Column() {
          Text('无法访问 iPhone 文件')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT)
          Text(this.errorText)
            .fontSize(11)
            .fontColor(MUTED_TEXT)
            .margin({ top: 8 })
            .textAlign(TextAlign.Center)
          PrimaryButton({
            label: '重试',
            buttonWidth: 120,
            buttonHeight: 38,
            on_action: (): void => {
              this.connect_and_list();
            },
          }).margin({ top: 16 })
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
      } else {
        this.breadcrumb();
        List() {
          ForEach(this.entries, (entry: AfcEntry) => {
            ListItem() {
              this.entry_row(entry)
            }
          }, (entry: AfcEntry): string =>
            `${this.currentPath}/${entry.name}`)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        Divider().color('#1A888888').margin({ top: 4, bottom: 4 })
        Text(this.busy ? this.statusText
          : `${this.entries.length} 项 · UDID ${this.udid}`)
          .fontSize(10)
          .fontColor(MUTED_TEXT)
          .maxLines(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding(SETTINGS_SECTION_PADDING)
  }

  build() {
    Column() {
      SubWindowShell({
        windowName: WINDOW_NAME,
        title: '文件',
        subtitle: 'iPhone（AFC）',
        gap: SUBWINDOW_ROW_GAP,
        hasNotice: false,
        hasFooter: false,
        hasActions: true,
        actionGap: 18,
        actionsSplit: false,
        content: (): void => {
          this.file_manager_body();
        },
        actions: (): void => {
          this.close_action();
        },
      });
    }
  }

  /** 靠右的「关闭」主按钮（与其它子窗口同款）。 */
  @Builder
  close_action() {
    PrimaryButton({
      label: '关闭',
      buttonWidth: 112,
      buttonHeight: 40,
      on_action: (): void => {
        SubWindowHost.close(WINDOW_NAME);
      },
    });
  }
}

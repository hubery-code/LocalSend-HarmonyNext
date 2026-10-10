import { common } from '@kit.AbilityKit';
import { FileRow, LocalSendService, PeerRow, ServiceSnapshot } from '../service/LocalSendService';

/** One controller for the whole app: the page is rebuilt on rotation and must not restart it. */
const service: LocalSendService = new LocalSendService();

function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

@Entry
@Component
struct Index {
  @State snap: ServiceSnapshot = new ServiceSnapshot();
  @State aliasDraft: string = '';
  @State hostDraft: string = '';

  aboutToAppear(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    service.attach((snapshot: ServiceSnapshot): void => {
      this.snap = snapshot;
      this.aliasDraft = snapshot.alias;
    });
    service.open(context).catch((reason: Object): void => {
      service.reportError(`${reason}`);
    });
  }

  aboutToDisappear(): void {
    // The ability owns the listener slot; the page must not leave a dead one behind.
    service.attach((): void => undefined);
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 12 }) {
          this.header()
          this.controls()
          this.peers()
          this.transfer()
          this.console()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
      }
      .width('100%')
      .height('100%')

      if (this.snap.hasOffer) {
        this.offerSheet()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder header() {
    Column({ space: 4 }) {
      Text('LocalSend')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
      Text(`${this.snap.scheme} · 端口 ${this.snap.port}${this.snap.multicast ? '' : ' · 无组播'}`)
        .fontSize(12)
        .fontColor('#888888')
      Text(`指纹 ${this.snap.fingerprint.substring(0, 16)}…`)
        .fontSize(11)
        .fontColor('#888888')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder controls() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.aliasDraft, placeholder: '设备名称' })
          .layoutWeight(1)
          .onChange((value: string) => {
            this.aliasDraft = value;
          })
        Button('改名')
          .onClick(() => {
            this.run(service.setAlias(this.aliasDraft));
          })
      }
      .width('100%')

      Row() {
        Text('接收文件')
          .fontSize(16)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.snap.running })
          .onChange((isOn: boolean) => {
            this.run(service.setReceiving(isOn));
          })
      }
      .width('100%')

      Row() {
        Text('加密传输 (HTTPS)')
          .fontSize(16)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.snap.encryption })
          .onChange((isOn: boolean) => {
            this.run(service.setEncryption(isOn));
          })
      }
      .width('100%')

      Text(this.snap.encryption ? '当前系统的 TLS 服务端会乱序投递大文件，请仅在局域网可信环境下使用' : '')
        .fontSize(10)
        .fontColor('#B26A00')
        .visibility(this.snap.encryption ? Visibility.Visible : Visibility.None)
        .width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.hostDraft, placeholder: '添加设备 https://ip:53317' })
          .layoutWeight(1)
          .onChange((value: string) => {
            this.hostDraft = value;
          })
        Button('添加')
          .onClick(() => {
            this.addHost();
          })
        Button('发现')
          .onClick(() => {
            this.run(service.refresh());
          })
      }
      .width('100%')

      ForEach(this.snap.hosts, (spec: string) => {
        Text(`已保存 ${spec}`)
          .fontSize(11)
          .fontColor('#777777')
      }, (spec: string) => spec)
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor('#F5F5F5')
  }

  @Builder peers() {
    Column({ space: 6 }) {
      Text(`附近设备 (${this.snap.peers.length})`)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
      if (this.snap.peers.length === 0) {
        Text(this.snap.running ? '暂无设备，可点“发现”' : '开启接收后才能发现设备')
          .fontSize(12)
          .fontColor('#999999')
      }
      ForEach(this.snap.peers, (peer: PeerRow) => {
        Row({ space: 8 }) {
          Text(peer.name)
            .fontSize(14)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${peer.host}:${peer.port}`)
            .fontSize(12)
            .fontColor('#777777')
          if (peer.download) {
            Text('可下载')
              .fontSize(11)
              .fontColor('#2E7D32')
          }
        }
        .width('100%')
      }, (peer: PeerRow) => `${peer.host}:${peer.port}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder transfer() {
    if (this.snap.hasSession) {
      Column({ space: 6 }) {
        Row() {
          Text(`正在接收 · ${this.snap.sessionSender}`)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
          Button('停止')
            .fontSize(13)
            .onClick(() => {
              service.stopSession();
            })
        }
        .width('100%')

        ForEach(this.snap.sessionFiles, (file: FileRow) => {
          Column({ space: 2 }) {
            Row() {
              Text(file.name)
                .fontSize(12)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${formatBytes(file.received)} / ${formatBytes(file.size)}`)
                .fontSize(11)
                .fontColor('#777777')
            }
            .width('100%')
            Progress({ value: file.size === 0 ? 100 : file.received * 100 / file.size })
              .width('100%')
            Text(file.status)
              .fontSize(10)
              .fontColor(file.status === 'failed' ? '#C62828' : '#2E7D32')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }, (file: FileRow) => `${file.name}:${file.size}`)
      }
      .width('100%')
      .padding(12)
      .borderRadius(12)
      .backgroundColor('#EEEEEE')
    }
  }

  @Builder console() {
    Column({ space: 2 }) {
      Text('日志')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
      Text(this.snap.log.reverse().join('\n'))
        .fontSize(10)
        .fontFamily('monospace')
        .fontColor('#555555')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder offerSheet() {
    Column() {
      Column({ space: 10 }) {
        Text(`${this.snap.offerSender}`)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
        Text('想要发送以下文件')
          .fontSize(13)
          .fontColor('#666666')
        Scroll() {
          Column({ space: 4 }) {
            ForEach(this.snap.offerFiles, (file: FileRow) => {
              Row() {
                Text(file.name)
                  .fontSize(12)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(formatBytes(file.size))
                  .fontSize(11)
                  .fontColor('#777777')
              }
              .width('100%')
            }, (file: FileRow) => file.name)
          }
          .width('100%')
        }
        .height(180)
        .width('100%')

        Text(`保存到 ${this.snap.offerDestination}`)
          .fontSize(10)
          .fontColor('#999999')

        Row({ space: 12 }) {
          Button('拒绝')
            .backgroundColor('#EEEEEE')
            .fontColor('#333333')
            .onClick(() => {
              service.declineOffer();
            })
          Button('接受')
            .onClick(() => {
              service.acceptOffer(this.allOfferIds());
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      .width('86%')
      .padding(16)
      .borderRadius(16)
      .backgroundColor(Color.White)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(0,0,0,0.45)')
  }

  private allOfferIds(): string[] {
    const rows: FileRow[] = this.snap.offerFiles;
    const ids: string[] = [];
    for (let i = 0; i < rows.length; i++) {
      ids.push(rows[i].id);
    }
    return ids;
  }

  /** Every action is fire-and-forget on screen; a rejected one still has to be reported. */
  private run(action: Promise<void>): void {
    action.catch((reason: Object): void => {
      service.reportError(`${reason}`);
    });
  }

  private addHost(): void {
    const spec: string = this.hostDraft.trim();
    if (spec.length === 0) {
      return;
    }
    this.hostDraft = '';
    this.run(service.addKnownHost(spec));
  }
}

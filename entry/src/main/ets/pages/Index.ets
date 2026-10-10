import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { describeFailure } from '@lsnext/protocol';
import { FileRow, LocalSendService, PeerRow, ServiceSnapshot } from '../service/LocalSendService';

/** One controller for the whole app: the page is rebuilt on rotation and must not restart it. */
const service: LocalSendService = new LocalSendService();

/** How many files one send may carry; the picker dialogs enforce the same ceiling. */
const MAX_PICK: number = 20;

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

function sendStatusLabel(status: string): string {
  if (status === 'hashing') {
    return '计算校验';
  }
  if (status === 'sending') {
    return '上传中';
  }
  if (status === 'success') {
    return '完成';
  }
  if (status === 'skipped') {
    return '对方未选';
  }
  if (status === 'failed') {
    return '失败';
  }
  if (status === 'canceled') {
    return '已取消';
  }
  if (status === 'pending') {
    return '排队';
  }
  return '准备中';
}

/** Task-level states share the row vocabulary; only the waiting and uploading phases differ. */
function taskStatusLabel(status: string): string {
  if (status === 'waiting') {
    return '等待对方确认';
  }
  if (status === 'uploading') {
    return '上传中';
  }
  return sendStatusLabel(status);
}

/** The web rows count bytes out, so they need their own three words. */
function webStatusLabel(status: string): string {
  if (status === 'done') {
    return '已下载';
  }
  if (status === 'partial') {
    return '下载中';
  }
  return '未下载';
}

/** Four digits, which is the shape the official clients hand out for web transfers. */
function randomPin(): string {
  return `${Math.floor(1000 + Math.random() * 9000)}`;
}

@Entry
@Component
struct Index {
  @State snap: ServiceSnapshot = new ServiceSnapshot();
  @State aliasDraft: string = '';
  @State hostDraft: string = '';
  @State pinDraft: string = '';
  @State pinEdit: string = '';
  @State showPinSheet: boolean = false;
  /** The peer chosen as the send target; an empty fingerprint means none. */
  @State target: PeerRow = new PeerRow();

  aboutToAppear(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    service.attach((snapshot: ServiceSnapshot): void => {
      this.snap = snapshot;
      this.aliasDraft = snapshot.alias;
    });
    service.open(context).catch((reason: Object): void => {
      service.reportError(`${describeFailure(reason)}`);
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
          this.send()
          this.webShare()
          this.transfer()
          this.console()
          this.about()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
      }
      .width('100%')
      .height('100%')

      if (this.snap.hasOffer) {
        this.offerSheet()
      } else if (this.snap.hasWebOffer) {
        this.webSheet()
      } else if (this.showPinSheet) {
        this.pinSheet()
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

      Row({ space: 8 }) {
        Text('接收 PIN')
          .fontSize(16)
          .layoutWeight(1)
        if (this.snap.receivePin.length > 0) {
          Button('清除')
            .fontSize(13)
            .backgroundColor('#EEEEEE')
            .fontColor('#333333')
            .onClick(() => {
              this.run(service.setReceivePin(''));
            })
        }
        // Buttons, not a Toggle: a Toggle fires its `onChange` when the first snapshot flips the
        // bound value, which would pop this sheet at every launch.
        Button(this.snap.receivePin.length > 0 ? '修改' : '设置')
          .fontSize(13)
          .onClick(() => {
            this.pinEdit = this.snap.receivePin.length > 0 ? this.snap.receivePin : randomPin();
            this.showPinSheet = true;
          })
      }
      .width('100%')

      Text(this.snap.receivePin.length > 0 ? `其他设备和浏览器上传前需要输入 PIN：${this.snap.receivePin}` : '')
        .fontSize(10)
        .fontColor('#B26A00')
        .visibility(this.snap.receivePin.length > 0 ? Visibility.Visible : Visibility.None)
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
          Button(this.target.fingerprint === peer.fingerprint ? '已选' : '发送')
            .fontSize(12)
            .backgroundColor(this.target.fingerprint === peer.fingerprint ? '#2E7D32' : '#E8E8E8')
            .fontColor(this.target.fingerprint === peer.fingerprint ? Color.White : '#333333')
            .onClick(() => {
              this.target = peer;
            })
        }
        .width('100%')
      }, (peer: PeerRow) => `${peer.host}:${peer.port}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder send() {
    Column({ space: 8 }) {
      Text('发送文件')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)

      Row({ space: 8 }) {
        Button('选择文档')
          .fontSize(13)
          .onClick(() => {
            this.pickDocuments();
          })
        Button('选择图片')
          .fontSize(13)
          .onClick(() => {
            this.pickPhotos();
          })
        Button('清空')
          .fontSize(13)
          .backgroundColor('#EEEEEE')
          .fontColor('#333333')
          .onClick(() => {
            service.clearPicked();
          })
      }
      .width('100%')

      Text(this.target.name.length > 0 ? `目标设备 ${this.target.name} (${this.target.host})` : '先在上方设备行点“发送”选一台设备')
        .fontSize(11)
        .fontColor(this.target.name.length > 0 ? '#2E7D32' : '#999999')
        .width('100%')

      Text(this.snap.picked.length > 0 ? `已选 ${this.snap.picked.length} 个文件` : '尚未选择文件')
        .fontSize(11)
        .fontColor(this.snap.picked.length > 0 ? '#2E7D32' : '#999999')

      ForEach(this.snap.picked, (item: FileRow) => {
        Text(item.name)
          .fontSize(11)
          .fontColor('#666666')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }, (item: FileRow) => `${item.id}:${item.name}`)

      Row({ space: 8 }) {
        TextInput({ text: this.pinDraft, placeholder: '接收方 PIN（可选）' })
          .layoutWeight(1)
          .onChange((value: string) => {
            this.pinDraft = value;
          })
        Button(this.snap.sendActive ? '取消发送' : '开始发送')
          .fontSize(13)
          .backgroundColor(this.snap.sendActive ? '#C62828' : '#2E7D32')
          .fontColor(Color.White)
          .onClick(() => {
            this.toggleSend();
          })
      }
      .width('100%')

      if (this.snap.sendFiles.length > 0) {
        Row() {
          Text(`进度 ${formatBytes(this.snap.sendSent)} / ${formatBytes(this.snap.sendTotal)}`)
            .fontSize(11)
            .fontColor('#777777')
            .layoutWeight(1)
          Text(taskStatusLabel(this.snap.sendState))
            .fontSize(11)
            .fontColor('#777777')
        }
        .width('100%')

        Progress({ value: this.snap.sendTotal === 0 ? 0 : this.snap.sendSent * 100 / this.snap.sendTotal })
          .width('100%')

        ForEach(this.snap.sendFiles, (item: FileRow) => {
          Row() {
            Text(item.name)
              .fontSize(12)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${formatBytes(item.received)} / ${formatBytes(item.size)}`)
              .fontSize(11)
              .fontColor('#777777')
            Text(sendStatusLabel(item.status))
              .fontSize(11)
              .fontColor(item.status === 'failed' ? '#C62828' : '#2E7D32')
          }
          .width('100%')
        // ForEach only re-renders a row when its key changes, so every value the row draws belongs
        // in the key — a stable id alone leaves the row frozen at whatever it first showed.
        }, (item: FileRow) => `${item.id}:${item.status}:${item.received}`)
      }

      if (this.snap.sendError.length > 0) {
        Text(this.snap.sendError)
          .fontSize(11)
          .fontColor('#C62828')
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(12)
    .backgroundColor('#F5F5F5')
  }

  @Builder webShare() {
    Column({ space: 8 }) {
      Text('网页传')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)

      Row({ space: 8 }) {
        Button(this.snap.webSharing && !this.snap.webUploading ? '停止网页传' : '网页传文件')
          .fontSize(13)
          .backgroundColor(this.snap.webSharing && !this.snap.webUploading ? '#C62828' : '#1565C0')
          .fontColor(Color.White)
          .onClick(() => {
            this.run(service.toggleWebShare());
          })
        Button(this.snap.webUploading ? '停止网页收' : '网页收文件')
          .fontSize(13)
          .backgroundColor(this.snap.webUploading ? '#C62828' : '#1565C0')
          .fontColor(Color.White)
          .onClick(() => {
            this.run(service.toggleWebUpload());
          })
      }
      .width('100%')

      if (this.snap.webSharing) {
        ForEach(this.snap.webUrls, (url: string) => {
          Text(url)
            .fontSize(12)
            .fontFamily('monospace')
            .fontColor('#1565C0')
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
        }, (url: string) => url)

        if (this.snap.webUploading) {
          Text('同一网络的电脑浏览器打开下面的地址即可上传；收到的文件会像普通接收一样弹出确认')
            .fontSize(11)
            .fontColor('#777777')
          if (this.snap.receivePin.length > 0) {
            Text(`浏览器上传时需要输入 PIN：${this.snap.receivePin}`)
              .fontSize(11)
              .fontColor('#B26A00')
          }
        } else {
          Text(`共 ${this.snap.webTotal} 字节 · 已送出 ${formatBytes(this.snap.webSent)} · `
            + `已允许 ${this.snap.webClients} 台浏览器`)
            .fontSize(11)
            .fontColor('#777777')

          ForEach(this.snap.webFiles, (item: FileRow) => {
            Row() {
              Text(item.name)
                .fontSize(12)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${formatBytes(item.received)} / ${formatBytes(item.size)}`)
                .fontSize(11)
                .fontColor('#777777')
              Text(webStatusLabel(item.status))
                .fontSize(11)
                .fontColor(item.status === 'done' ? '#2E7D32' : '#777777')
            }
            .width('100%')
          // As in the send rows: every value drawn here belongs in the key, or the row never updates.
          }, (item: FileRow) => `${item.id}:${item.status}:${item.received}`)
        }
      } else {
        Text('“网页传文件”：先在“发送文件”里选好文件，再开启，浏览器打开地址即可下载；'
          + '“网页收文件”：浏览器打开地址后把文件传上来')
          .fontSize(11)
          .fontColor('#999999')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(12)
    .backgroundColor('#F5F5F5')
  }

  @Builder pinSheet() {
    Column() {
      Column({ space: 10 }) {
        Text('接收 PIN')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
        Text('开启后，其他设备和浏览器上传前都必须输入这串数字')
          .fontSize(12)
          .fontColor('#666666')
          .width('100%')
        TextInput({ text: this.pinEdit, placeholder: '至少 4 位数字' })
          .type(InputType.Number)
          .maxLength(8)
          .onChange((value: string) => {
            this.pinEdit = value;
          })
        Row({ space: 12 }) {
          Button('随机生成')
            .fontSize(13)
            .backgroundColor('#EEEEEE')
            .fontColor('#333333')
            .onClick(() => {
              this.pinEdit = randomPin();
            })
          Blank()
          Button('取消')
            .fontSize(13)
            .backgroundColor('#EEEEEE')
            .fontColor('#333333')
            .onClick(() => {
              this.showPinSheet = false;
            })
          Button('确定')
            .fontSize(13)
            .onClick(() => {
              this.confirmPin();
            })
        }
        .width('100%')
      }
      .width('80%')
      .padding(16)
      .borderRadius(16)
      .backgroundColor(Color.White)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(0,0,0,0.45)')
  }

  @Builder webSheet() {
    Column() {
      Column({ space: 10 }) {
        Text('有浏览器想下载分享的文件')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
        Text(`来源 ${this.snap.webOfferClient}`)
          .fontSize(13)
          .fontColor('#666666')
        Text(`${this.snap.webOfferFiles} 个文件 · ${formatBytes(this.snap.webOfferBytes)}`)
          .fontSize(13)
          .fontColor('#666666')
        if (this.snap.webOfferAgent.length > 0) {
          Text(this.snap.webOfferAgent)
            .fontSize(10)
            .fontColor('#999999')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        Row({ space: 12 }) {
          Button('拒绝')
            .backgroundColor('#EEEEEE')
            .fontColor('#333333')
            .onClick(() => {
              service.denyWebVisitor();
            })
          Button('允许')
            .onClick(() => {
              service.allowWebVisitor();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      .width('80%')
      .padding(16)
      .borderRadius(16)
      .backgroundColor(Color.White)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(0,0,0,0.45)')
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

  @Builder about() {
    Column({ space: 3 }) {
      Text('关于')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
      Text('LocalSend-HarmonyNext 0.1.0 · LocalSend 协议 v2.2')
        .fontSize(11)
        .fontColor('#777777')
      Text('与官方 LocalSend 客户端在局域网内直接互传文件，不经过任何服务器，也不收集任何数据。')
        .fontSize(10)
        .fontColor('#999999')
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
      service.reportError(`${describeFailure(reason)}`);
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

  private toggleSend(): void {
    if (this.snap.sendActive) {
      service.cancelSend();
      return;
    }
    if (this.target.fingerprint.length === 0) {
      service.reportError('还没选择目标设备');
      return;
    }
    service.startSend(this.target.fingerprint, this.pinDraft.trim());
  }

  private confirmPin(): void {
    const pin: string = this.pinEdit.trim();
    if (pin.length < 4) {
      service.reportError('PIN 至少 4 位');
      return;
    }
    this.showPinSheet = false;
    this.run(service.setReceivePin(pin));
  }

  /**
   * Both pickers are the system ones, so no media or file permission is requested: the returned uris
   * carry the temporary read grant with them.
   */
  private pickDocuments(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    // The picker may answer with a single uri per invocation on a phone, so picks accumulate in the
    // service rather than replacing each other.
    const options: picker.DocumentSelectOptions = {
      maxSelectNumber: MAX_PICK
    };
    const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    docPicker.select(options).then((uris: string[]): void => {
      this.applyPicked(uris);
    }).catch((reason: BusinessError): void => {
      service.reportError(`选择文档失败: ${reason.message}`);
    });
  }

  private pickPhotos(): void {
    const options: picker.PhotoSelectOptions = {
      MIMEType: picker.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE,
      maxSelectNumber: MAX_PICK
    };
    const photoPicker: picker.PhotoViewPicker = new picker.PhotoViewPicker();
    photoPicker.select(options).then((result: picker.PhotoSelectResult): void => {
      this.applyPicked(result.photoUris);
    }).catch((reason: BusinessError): void => {
      service.reportError(`选择图片失败: ${reason.message}`);
    });
  }

  /** An empty result is a dismissed dialog, not a failure worth a red line. */
  private applyPicked(uris: string[]): void {
    if (uris.length === 0) {
      return;
    }
    service.addPicked(uris);
  }
}

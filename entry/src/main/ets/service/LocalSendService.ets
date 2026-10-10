import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import {
  ApiPath, ClientCredentials, DEFAULT_PORT, DestinationContext, DeviceTypeValue, Discovery,
  FileProgressEvent, FileStatus, HttpServer, Identity, IdentityRepository, KnownChannel, LocalInterface,
  PrepareContext, PrepareDecision, PROTOCOL_VERSION, Peer, ProtocolScheme, ReceivedFile, ReceiveSession,
  RequestHandler, SendFile, SendFileStatus, SendSource, SendTarget, SendTask, SendTaskStatus, Sender,
  SenderConfig, SessionEndReason, SessionManager, SessionManagerConfig, TlsMaterial, WireDeviceInfo,
  WebOfferContext, WebOfferFile, WebShare, WebShareConfig
} from '@lsnext/protocol';
import { AppPrefs } from './AppPrefs';
import { formatHostSpec, parseHostSpec, sameHost } from './HostSpec';
/** hilog tag; 0x0000 keeps us inside the app's own log domain. */
const TAG: string = 'LocalSendNext';

/** What the page draws. A fresh snapshot per change keeps ArkUI's @State diffing honest. */
export class PeerRow {
  name: string = '';
  host: string = '';
  port: number = 0;
  scheme: string = 'http';
  download: boolean = false;
  fingerprint: string = '';
}

export class FileRow {
  /** fileId, so an accept can name exactly the rows the page showed. */
  id: string = '';
  name: string = '';
  size: number = 0;
  /** Bytes received while downloading; bytes handed to the socket while sending. */
  received: number = 0;
  status: string = '';
}

export class ServiceSnapshot {
  running: boolean = false;
  alias: string = '';
  fingerprint: string = '';
  scheme: string = 'http';
  port: number = DEFAULT_PORT;
  multicast: boolean = false;
  encryption: boolean = false;
  peers: PeerRow[] = [];
  hasOffer: boolean = false;
  offerSender: string = '';
  offerDestination: string = '';
  offerFiles: FileRow[] = [];
  hasSession: boolean = false;
  sessionSender: string = '';
  sessionFiles: FileRow[] = [];
  hosts: string[] = [];
  /** Files the user has picked to send, not sent yet. */
  picked: FileRow[] = [];
  sendActive: boolean = false;
  sendPeer: string = '';
  sendState: string = '';
  sendFiles: FileRow[] = [];
  sendTotal: number = 0;
  sendSent: number = 0;
  sendError: string = '';
  /** The web share (Download API): what is offered, where to open it, and who got in. */
  webSharing: boolean = false;
  webFiles: FileRow[] = [];
  webTotal: number = 0;
  webSent: number = 0;
  webClients: number = 0;
  webUrls: string[] = [];
  hasWebOffer: boolean = false;
  webOfferClient: string = '';
  webOfferAgent: string = '';
  webOfferFiles: number = 0;
  webOfferBytes: number = 0;
  log: string[] = [];
}

/** The directory files land in, decided once per app run. */
const RECEIVE_SUBDIR: string = '/LocalSend';

/**
 * The app-side controller: identity, HTTP server, discovery and the receive session
 * engine, wired together and mirrored into one snapshot for the page.
 *
 * Everything protocol-shaped lives in the HAR; this class only owns lifecycle and the
 * answers the protocol asks the application for (where to save, what the user accepted).
 */
export class LocalSendService {
  private prefs: AppPrefs | null = null;
  private identity: Identity | null = null;
  private server: HttpServer | null = null;
  private discovery: Discovery | null = null;
  private sessions: SessionManager | null = null;
  private filesDir: string = '';
  private logLines: string[] = [];
  private listener: ((snapshot: ServiceSnapshot) => void) | null = null;
  /** Set while an offer is on screen; the page's accept/decline resolves it. */
  private resolveOffer: ((decision: PrepareDecision) => void) | null = null;
  private offer: PrepareContext | null = null;
  private session: ReceiveSession | null = null;
  private running: boolean = false;
  private aliasText: string = '';
  private encryption: boolean = false;
  private known: KnownChannel[] = [];
  private sender: Sender | null = null;
  private pickedUris: string[] = [];
  private web: WebShare | null = null;
  /** Set while a browser's download request is on screen. */
  private webOffer: WebOfferContext | null = null;
  private resolveWebOffer: ((accepted: boolean) => void) | null = null;

  /** Called by the page in aboutToAppear; the service never holds a UI object. */
  attach(listener: (snapshot: ServiceSnapshot) => void): void {
    this.listener = listener;
    this.emit();
  }

  async open(context: common.UIAbilityContext): Promise<void> {
    if (this.prefs !== null) {
      return;
    }
    this.prefs = await AppPrefs.open(context);
    this.filesDir = context.filesDir;
    this.aliasText = this.prefs.alias();
    this.encryption = this.prefs.encryption();
    this.known = this.readKnown();
    // Resolve the identity now so the UI can show a fingerprint before the server runs.
    this.identity = await new IdentityRepository(this.prefs).resolve(this.encryption, '');
    if (this.prefs.receiving()) {
      await this.startReceiving();
    }
    this.emit();
  }

  async setAlias(alias: string): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    await this.prefs.setAlias(alias);
    this.aliasText = alias;
    this.emit();
  }

  alias(): string {
    return this.aliasText;
  }

  encryptionEnabled(): boolean {
    return this.encryption;
  }

  /** Changing the scheme needs a new identity and a new listener, so it restarts the service. */
  async setEncryption(enabled: boolean): Promise<void> {
    if (this.prefs === null || this.encryption === enabled) {
      return;
    }
    await this.prefs.setEncryption(enabled);
    this.encryption = enabled;
    const wasRunning: boolean = this.running;
    await this.shutdown();
    this.identity = await new IdentityRepository(this.prefs).resolve(enabled, '');
    if (wasRunning) {
      await this.startReceiving();
    } else {
      this.emit();
    }
  }

  async setReceiving(enabled: boolean): Promise<void> {
    if (this.prefs !== null) {
      await this.prefs.setReceiving(enabled);
    }
    if (enabled) {
      await this.startReceiving();
    } else {
      await this.shutdown();
    }
  }

  isRunning(): boolean {
    return this.running;
  }

  /** The page fires actions without awaiting them; a failure still has to reach the screen. */
  reportError(message: string): void {
    this.log(`错误: ${message}`);
    this.emit();
  }

  private async startReceiving(): Promise<void> {
    if (this.running || this.identity === null) {
      return;
    }
    const identity: Identity = this.identity;
    const sessions: SessionManager = new SessionManager(this.sessionConfig(identity));
    this.sessions = sessions;
    const discovery: Discovery = new Discovery({
      self: (): WireDeviceInfo => this.selfInfo(identity),
      port: DEFAULT_PORT,
      group: null,
      identity: (): Identity | null => this.identity,
      onPeersChanged: (peers: Peer[]): void => {
        this.log(`peers: ${peers.length}`);
        this.emit();
      },
      log: (message: string): void => this.log(message)
    });
    this.discovery = discovery;

    this.web = new WebShare(this.webConfig(identity));

    const routes: Map<string, RequestHandler> = sessions.routes();
    routes.set(ApiPath.REGISTER, discovery.registerHandler());
    routes.set(ApiPath.INFO, discovery.infoHandler());
    // The web surface is live as soon as the server is: an off share must answer its pages with 403
    // rather than let requests fall through as unknown paths.
    this.web.routes().forEach((handler: RequestHandler, path: string) => {
      routes.set(path, handler);
    });

    const tls: TlsMaterial | null = identity.isHttps
      ? {
        certPem: identity.certPem,
        keyPem: identity.keyPem,
        keyPassword: identity.keyPassword,
        // Verified on the emulator: once we *request* a client certificate, the HarmonyOS TLS
        // stack validates it against its trust store and answers `unknown ca` to LocalSend's
        // self-signed device certificates. The official client still connects when we do not
        // ask, so encryption works both ways — only the peer's proven fingerprint is lost.
        requestClientCertificate: false
      }
      : null;

    this.server = await HttpServer.start({
      port: DEFAULT_PORT,
      tls: tls,
      routes: routes,
      log: (message: string): void => this.log(message)
    });
    await discovery.start();
    this.running = true;
    // Announce once we are actually listening, so no peer is pointed at a closed port.
    discovery.setAnswerAnnouncements(true);
    discovery.announce();
    this.log(`receiving on :${DEFAULT_PORT} over ${identity.scheme}`);
    this.emit();
  }

  private async shutdown(): Promise<void> {
    if (this.discovery !== null) {
      await this.discovery.stop();
      this.discovery = null;
    }
    if (this.server !== null) {
      await this.server.stop();
      this.server = null;
    }
    if (this.sessions !== null) {
      this.sessions.reset();
      this.sessions = null;
    }
    if (this.web !== null) {
      this.web.reset();
      this.web = null;
    }
    this.resolveOffer = null;
    this.offer = null;
    this.session = null;
    this.webOffer = null;
    this.resolveWebOffer = null;
    this.running = false;
    this.emit();
  }

  async close(): Promise<void> {
    await this.shutdown();
  }

  /** Discovery with no multicast: probe the addresses the user or a previous run knows. */
  /**
   * Adds `[scheme://]host[:port]` to the saved leads. Without multicast these are the only
   * addresses discovery has to work from, so they persist across launches.
   */
  async addKnownHost(spec: string): Promise<void> {
    const channel: KnownChannel | null = parseHostSpec(spec);
    if (channel === null) {
      this.reportError(`无法识别的地址: ${spec}`);
      return;
    }
    for (let i = 0; i < this.known.length; i++) {
      if (sameHost(this.known[i], channel)) {
        return;
      }
    }
    this.known.push(channel);
    await this.persistKnown();
    this.emit();
  }

  async refresh(): Promise<void> {
    if (this.discovery === null) {
      this.log('接收未开启，无法发现设备');
      return;
    }
    await this.discovery.discoverStaged(this.known);
    this.emit();
  }

  private readKnown(): KnownChannel[] {
    const channels: KnownChannel[] = [];
    if (this.prefs === null) {
      return channels;
    }
    const specs: string[] = this.prefs.knownHosts();
    for (let i = 0; i < specs.length; i++) {
      const channel: KnownChannel | null = parseHostSpec(specs[i]);
      if (channel !== null) {
        channels.push(channel);
      }
    }
    return channels;
  }

  private async persistKnown(): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    const specs: string[] = [];
    for (let i = 0; i < this.known.length; i++) {
      specs.push(formatHostSpec(this.known[i]));
    }
    await this.prefs.setKnownHosts(specs);
  }

  peers(): Peer[] {
    return this.discovery === null ? [] : this.discovery.peers.list();
  }

  // ------------------------------------------------------------------- sending

  /**
   * Stages the uris the system picker returned — a document uri, a media uri or a sandbox path, all
   * of which `fileIo.open` accepts unchanged.
   *
   * Picks accumulate because the phone's document picker returns one file per invocation: a folder
   * transfer is built by tapping 选择文档 several times, so a second pick must not discard the first.
   */
  addPicked(uris: string[]): void {
    for (let i = 0; i < uris.length; i++) {
      const uri: string = uris[i];
      if (this.pickedUris.indexOf(uri) < 0) {
        this.pickedUris.push(uri);
      }
    }
    this.emit();
  }

  clearPicked(): void {
    this.pickedUris = [];
    this.emit();
  }

  /**
   * Sends the staged selection to one peer. The engine runs on its own and reports through
   * `onChanged`, so a folder transfer never blocks the tap handler that started it.
   */
  startSend(fingerprint: string, pin: string): void {
    const peer: Peer | null = this.discovery === null ? null : this.discovery.peers.get(fingerprint);
    if (peer === null) {
      this.reportError('该设备已不在列表中，请重新发现');
      return;
    }
    if (this.pickedUris.length === 0) {
      this.reportError('还没有选择文件');
      return;
    }
    const identity: Identity | null = this.identity;
    if (identity === null) {
      this.reportError('设备标识尚未就绪');
      return;
    }
    const sources: SendSource[] = [];
    for (let i = 0; i < this.pickedUris.length; i++) {
      sources.push({ uri: this.pickedUris[i], fileName: displayNameOf(this.pickedUris[i]) });
    }
    const target: SendTarget = {
      host: peer.host,
      port: peer.port,
      scheme: peer.protocol,
      alias: peer.alias,
      fingerprint: peer.fingerprint
    };
    const sender: Sender = this.sender === null ? new Sender(this.senderConfig(identity)) : this.sender;
    this.sender = sender;
    sender.start(target, sources, pin.length > 0 ? pin : null);
    this.emit();
  }

  cancelSend(): void {
    if (this.sender !== null) {
      this.sender.cancel();
    }
    this.emit();
  }

  private senderConfig(identity: Identity): SenderConfig {
    const credentials: ClientCredentials | null = identity.isHttps
      ? { certPem: identity.certPem, keyPem: identity.keyPem, keyPassword: identity.keyPassword }
      : null;
    const config: SenderConfig = {
      self: (): WireDeviceInfo => this.selfInfo(identity),
      credentials: (): ClientCredentials | null => credentials,
      onChanged: (): void => this.emit(),
      log: (message: string): void => this.log(message)
    };
    return config;
  }

  private sendRows(): FileRow[] {
    const task: SendTask | null = this.sender === null ? null : this.sender.current();
    const rows: FileRow[] = [];
    if (task === null) {
      return rows;
    }
    for (let i = 0; i < task.files.length; i++) {
      const file: SendFile = task.files[i];
      const row: FileRow = new FileRow();
      row.id = file.fileId;
      row.name = file.fileName;
      row.size = file.size;
      row.received = file.sent;
      row.status = file.status;
      rows.push(row);
    }
    return rows;
  }

  private pickedRows(): FileRow[] {
    const rows: FileRow[] = [];
    for (let i = 0; i < this.pickedUris.length; i++) {
      const row: FileRow = new FileRow();
      row.id = `p${i}`;
      row.name = displayNameOf(this.pickedUris[i]);
      row.status = 'queued';
      rows.push(row);
    }
    return rows;
  }

  private sendErrorText(): string {
    const task: SendTask | null = this.sender === null ? null : this.sender.current();
    if (task === null) {
      return '';
    }
    if (task.error.length > 0) {
      return task.error;
    }
    // The task-level error stays empty when a single file failed; surface that one instead.
    for (let i = 0; i < task.files.length; i++) {
      if (task.files[i].status === SendFileStatus.FAILED) {
        return `${task.files[i].fileName}: ${task.files[i].error}`;
      }
    }
    return '';
  }

  // ------------------------------------------------------------ web share (Download API)

  /** One switch for the page: a running share stops, anything else starts one from the picks. */
  async toggleWebShare(): Promise<void> {
    if (this.web !== null && this.web.isSharing()) {
      this.stopWebShare();
      return;
    }
    await this.startWebShare();
  }

  /**
   * Offers the staged selection to browsers.
   *
   * A share is only meaningful while the server listens, so starting one from a stopped app turns
   * receiving on first rather than making the user flip two switches in a row.
   */
  async startWebShare(): Promise<void> {
    if (this.pickedUris.length === 0) {
      this.reportError('还没有选择文件');
      return;
    }
    if (!this.running) {
      await this.setReceiving(true);
    }
    const web: WebShare | null = this.web;
    if (web === null) {
      this.reportError('接收未能开启，无法网页分享');
      return;
    }
    const sources: SendSource[] = [];
    for (let i = 0; i < this.pickedUris.length; i++) {
      sources.push({ uri: this.pickedUris[i], fileName: displayNameOf(this.pickedUris[i]) });
    }
    const count: number = await web.share(sources);
    if (count === 0) {
      this.reportError('选中的文件都读取不到');
      return;
    }
    // Peers cache our announcement, so the new download flag only reaches them once we re-announce.
    if (this.discovery !== null) {
      this.discovery.announce();
    }
    this.emit();
  }

  stopWebShare(): void {
    const web: WebShare | null = this.web;
    if (web !== null) {
      web.stop();
    }
    this.emit();
  }

  private webConfig(identity: Identity): WebShareConfig {
    const config: WebShareConfig = {
      self: (): WireDeviceInfo => this.selfInfo(identity),
      // A share PIN belongs with the settings screen; until then the confirmation dialog is the gate.
      pin: (): string | null => null,
      decide: (context: WebOfferContext): Promise<boolean> => this.askWebVisitor(context),
      // A browser that hangs up leaves the sheet standing over a request nobody can serve anymore.
      onOfferClosed: (clientIp: string): void => {
        const pending: WebOfferContext | null = this.webOffer;
        if (pending !== null && pending.clientIp === clientIp) {
          this.webOffer = null;
          this.resolveWebOffer = null;
          this.emit();
        }
      },
      onChanged: (): void => this.emit(),
      log: (message: string): void => this.log(message)
    };
    return config;
  }

  private askWebVisitor(context: WebOfferContext): Promise<boolean> {
    this.webOffer = context;
    this.emit();
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      this.resolveWebOffer = resolve;
    });
  }

  allowWebVisitor(): void {
    this.answerWebOffer(true);
  }

  denyWebVisitor(): void {
    this.answerWebOffer(false);
  }

  /** The browser may already have hung up; resolving anyway is harmless and frees the waiting slot. */
  private answerWebOffer(accepted: boolean): void {
    const resolve: ((accepted: boolean) => void) | null = this.resolveWebOffer;
    if (resolve === null) {
      return;
    }
    this.resolveWebOffer = null;
    this.webOffer = null;
    resolve(accepted);
    this.emit();
  }

  private webRows(): FileRow[] {
    const rows: FileRow[] = [];
    const web: WebShare | null = this.web;
    if (web === null) {
      return rows;
    }
    const files: WebOfferFile[] = web.offered();
    for (let i = 0; i < files.length; i++) {
      const file: WebOfferFile = files[i];
      const row: FileRow = new FileRow();
      row.id = file.fileId;
      row.name = file.fileName;
      row.size = file.size;
      row.received = file.downloaded;
      if (file.size > 0 && file.downloaded >= file.size) {
        row.status = 'done';
      } else if (file.downloaded > 0) {
        row.status = 'partial';
      } else {
        row.status = 'idle';
      }
      rows.push(row);
    }
    return rows;
  }

  /** Where a browser on the same network opens the share: one address per live interface. */
  private webLinks(): string[] {
    const links: string[] = [];
    const discovery: Discovery | null = this.discovery;
    if (discovery === null) {
      return links;
    }
    const scheme: string = this.identity === null || !this.identity.isHttps
      ? ProtocolScheme.HTTP : ProtocolScheme.HTTPS;
    const interfaces: LocalInterface[] = discovery.localInterfaces();
    for (let i = 0; i < interfaces.length; i++) {
      links.push(`${scheme}://${interfaces[i].address}:${DEFAULT_PORT}/`);
    }
    return links;
  }

  // ------------------------------------------------------------- user answers

  acceptOffer(fileIds: string[]): void {
    const resolve: ((decision: PrepareDecision) => void) | null = this.resolveOffer;
    if (resolve === null) {
      return;
    }
    this.resolveOffer = null;
    this.offer = null;
    resolve({ declined: false, acceptedFileIds: fileIds });
    this.emit();
  }

  declineOffer(): void {
    const resolve: ((decision: PrepareDecision) => void) | null = this.resolveOffer;
    if (resolve === null) {
      return;
    }
    this.resolveOffer = null;
    this.offer = null;
    resolve({ declined: true, acceptedFileIds: [] });
    this.emit();
  }

  stopSession(): void {
    if (this.sessions === null) {
      return;
    }
    this.sessions.cancelActiveLocally();
    this.emit();
  }

  /** Used by the emulator test: a peer that never appears in discovery is added by hand. */
  private selfInfo(identity: Identity): WireDeviceInfo {
    const info: WireDeviceInfo = {
      alias: this.aliasText,
      version: PROTOCOL_VERSION,
      deviceModel: 'HarmonyOS',
      deviceType: DeviceTypeValue.MOBILE,
      fingerprint: identity.fingerprint,
      port: DEFAULT_PORT,
      protocol: identity.isHttps ? ProtocolScheme.HTTPS : ProtocolScheme.HTTP,
      // `download` means "the browser download page is live", and only a running share is that.
      download: this.web !== null && this.web.isSharing()
    };
    return info;
  }

  private sessionConfig(identity: Identity): SessionManagerConfig {
    const config: SessionManagerConfig = {
      selfFingerprint: (): string => identity.fingerprint,
      // The receive PIN guards the browser upload page; device-to-device trust comes from TLS.
      pin: (): string | null => null,
      destination: async (context: DestinationContext): Promise<string | null> => {
        this.log(`incoming ${context.fileCount} file(s), ${context.totalBytes} byte(s) `
          + `from ${context.info.alias} (${context.senderIp})`);
        return this.filesDir + RECEIVE_SUBDIR;
      },
      decide: (context: PrepareContext): Promise<PrepareDecision> => this.askUser(context),
      verifyChecksums: (): boolean => true,
      onSessionCreated: (session: ReceiveSession): void => {
        this.session = session;
        this.emit();
      },
      onSessionEnded: (session: ReceiveSession, reason: SessionEndReason): void => {
        this.log(`session ${session.sessionId} ended: ${reason}`);
        this.session = null;
        this.emit();
      },
      onFileUpdated: (session: ReceiveSession, file: ReceivedFile): void => {
        this.session = session;
        this.emit();
      },
      onProgress: (event: FileProgressEvent): void => {
        this.emit();
      },
      onPrepareAborted: (sessionId: string): void => {
        this.log(`offer ${sessionId} withdrawn by the sender`);
        this.resolveOffer = null;
        this.offer = null;
        this.emit();
      },
      onCancelReceived: (senderIp: string, sessionId: string): void => {
        this.log(`cancel from ${senderIp} for session ${sessionId}`);
      },
      log: (message: string): void => this.log(message)
    };
    return config;
  }

  private askUser(context: PrepareContext): Promise<PrepareDecision> {
    this.offer = context;
    this.emit();
    return new Promise<PrepareDecision>((resolve: (value: PrepareDecision) => void) => {
      this.resolveOffer = resolve;
    });
  }

  // ------------------------------------------------------------------ snapshot

  private log(message: string): void {
    // The on-screen console is not enough once the app is out of sight: the same lines have to
    // be reachable from `hdc shell hilog` while debugging a transfer.
    hilog.info(0x0000, TAG, '%{public}s', message);
    this.logLines.push(message);
    if (this.logLines.length > 120) {
      this.logLines.splice(0, this.logLines.length - 120);
    }
  }

  private rowsOf(files: ReceivedFile[]): FileRow[] {
    const rows: FileRow[] = [];
    for (let i = 0; i < files.length; i++) {
      const file: ReceivedFile = files[i];
      const row: FileRow = new FileRow();
      row.id = file.fileId;
      row.name = file.fileName;
      row.size = file.size;
      row.received = file.receivedBytes;
      row.status = file.status;
      rows.push(row);
    }
    return rows;
  }

  private sessionFiles(): FileRow[] {
    const session: ReceiveSession | null = this.session;
    if (session === null) {
      return [];
    }
    const list: ReceivedFile[] = [];
    session.files.forEach((file: ReceivedFile) => {
      list.push(file);
    });
    return this.rowsOf(list);
  }

  private offerFiles(): FileRow[] {
    const offer: PrepareContext | null = this.offer;
    if (offer === null) {
      return [];
    }
    const rows: FileRow[] = [];
    for (let i = 0; i < offer.candidates.length; i++) {
      const row: FileRow = new FileRow();
      row.id = offer.candidates[i].fileId;
      row.name = offer.candidates[i].fileName;
      row.size = offer.candidates[i].size;
      row.status = FileStatus.PENDING;
      rows.push(row);
    }
    return rows;
  }

  private peerRows(): PeerRow[] {
    const peers: Peer[] = this.peers();
    const rows: PeerRow[] = [];
    for (let i = 0; i < peers.length; i++) {
      const row: PeerRow = new PeerRow();
      row.name = peers[i].alias;
      row.host = peers[i].host;
      row.port = peers[i].port;
      row.scheme = peers[i].protocol;
      row.download = peers[i].download;
      row.fingerprint = peers[i].fingerprint;
      rows.push(row);
    }
    return rows;
  }

  private emit(): void {
    const listener: ((snapshot: ServiceSnapshot) => void) | null = this.listener;
    if (listener === null) {
      return;
    }
    const offer: PrepareContext | null = this.offer;
    const snapshot: ServiceSnapshot = new ServiceSnapshot();
    snapshot.running = this.running;
    snapshot.alias = this.aliasText;
    snapshot.fingerprint = this.identity === null ? '' : this.identity.fingerprint;
    snapshot.scheme = this.identity === null ? ProtocolScheme.HTTP : this.identity.scheme;
    snapshot.port = DEFAULT_PORT;
    snapshot.multicast = this.discovery !== null && this.discovery.hasMulticast();
    snapshot.encryption = this.encryption;
    snapshot.peers = this.peerRows();
    snapshot.hasOffer = offer !== null;
    snapshot.offerSender = offer === null ? '' : `${offer.info.alias} (${offer.senderIp})`;
    snapshot.offerDestination = offer === null ? '' : offer.destination;
    snapshot.offerFiles = this.offerFiles();
    snapshot.hasSession = this.session !== null;
    snapshot.sessionSender = this.session === null ? '' : this.session.senderAlias;
    snapshot.sessionFiles = this.sessionFiles();
    const specs: string[] = [];
    for (let i = 0; i < this.known.length; i++) {
      specs.push(formatHostSpec(this.known[i]));
    }
    snapshot.hosts = specs;
    const sendTask: SendTask | null = this.sender === null ? null : this.sender.current();
    snapshot.picked = this.pickedRows();
    snapshot.sendActive = sendTask !== null && !sendTask.isFinished();
    snapshot.sendPeer = sendTask === null ? '' : `${sendTask.peerAlias} (${sendTask.target.host})`;
    snapshot.sendState = sendTask === null ? '' : sendTask.status;
    snapshot.sendFiles = this.sendRows();
    snapshot.sendTotal = sendTask === null ? 0 : sendTask.totalBytes();
    snapshot.sendSent = sendTask === null ? 0 : sendTask.sentBytes();
    snapshot.sendError = this.sendErrorText();
    const web: WebShare | null = this.web;
    const webOffer: WebOfferContext | null = this.webOffer;
    snapshot.webSharing = web !== null && web.isSharing();
    snapshot.webFiles = this.webRows();
    snapshot.webTotal = web === null ? 0 : web.totalOffered();
    snapshot.webSent = web === null ? 0 : web.transferred();
    snapshot.webClients = web === null ? 0 : web.acceptedClients();
    snapshot.webUrls = this.webLinks();
    snapshot.hasWebOffer = webOffer !== null;
    snapshot.webOfferClient = webOffer === null ? '' : webOffer.clientIp;
    snapshot.webOfferAgent = webOffer === null ? '' : webOffer.userAgent;
    snapshot.webOfferFiles = webOffer === null ? 0 : webOffer.fileCount;
    snapshot.webOfferBytes = webOffer === null ? 0 : webOffer.totalBytes;
    snapshot.log = this.logLines.slice(0);
    listener(snapshot);
  }
}

/**
 * Last path segment of a uri, percent-decoded.
 *
 * Pickers hand back `file://docs/.../名字.pdf` and `file://media/Photo/.../IMG_1.jpg`; a
 * `decodeURIComponent` failure only means the name contains a stray `%`, which is legal in a file
 * name, so the raw tail is the better answer.
 */
function displayNameOf(uri: string): string {
  const trimmed: string = uri.endsWith('/') ? uri.substring(0, uri.length - 1) : uri;
  const slash: number = trimmed.lastIndexOf('/');
  const tail: string = slash < 0 ? trimmed : trimmed.substring(slash + 1);
  try {
    return decodeURIComponent(tail);
  } catch (e) {
    return tail;
  }
}

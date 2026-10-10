import { common } from '@kit.AbilityKit';
import {
  ApiPath, DEFAULT_PORT, DestinationContext, DeviceTypeValue, Discovery, FileProgressEvent, FileStatus,
  HttpServer, Identity, IdentityRepository, KnownChannel, PrepareContext, PrepareDecision, PROTOCOL_VERSION,
  Peer, ProtocolScheme, ReceivedFile, ReceiveSession, RequestHandler, SessionEndReason, SessionManager,
  SessionManagerConfig, TlsMaterial, WireDeviceInfo
} from '@lsnext/protocol';
import { AppPrefs } from './AppPrefs';

/** What the page draws. A fresh snapshot per change keeps ArkUI's @State diffing honest. */
export class PeerRow {
  name: string = '';
  host: string = '';
  port: number = 0;
  scheme: string = 'http';
  download: boolean = false;
}

export class FileRow {
  /** fileId, so an accept can name exactly the rows the page showed. */
  id: string = '';
  name: string = '';
  size: number = 0;
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

    const routes: Map<string, RequestHandler> = sessions.routes();
    routes.set(ApiPath.REGISTER, discovery.registerHandler());
    routes.set(ApiPath.INFO, discovery.infoHandler());

    const tls: TlsMaterial | null = identity.isHttps
      ? {
        certPem: identity.certPem,
        keyPem: identity.keyPem,
        keyPassword: identity.keyPassword,
        // Official servers demand a client certificate; HarmonyOS validates a requested one
        // against its trust store, so this stays off until the handshake spike proves it.
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
    this.resolveOffer = null;
    this.offer = null;
    this.session = null;
    this.running = false;
    this.emit();
  }

  async close(): Promise<void> {
    await this.shutdown();
  }

  /** Discovery with no multicast: probe the addresses the user or a previous run knows. */
  async refresh(channels: KnownChannel[]): Promise<void> {
    if (this.discovery === null) {
      this.log('接收未开启，无法发现设备');
      return;
    }
    await this.discovery.discoverStaged(channels);
    this.emit();
  }

  peers(): Peer[] {
    return this.discovery === null ? [] : this.discovery.peers.list();
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
      // The web download page is a later milestone; advertising it would invite requests we refuse.
      download: false
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
    snapshot.log = this.logLines.slice(0);
    listener(snapshot);
  }
}

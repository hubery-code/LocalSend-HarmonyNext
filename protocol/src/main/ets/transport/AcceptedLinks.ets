import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteLink, IpFamily, PeerAddress, TransportError, tightBuffer } from './ByteLink';
import { sha256Hex } from '../util/Digest';

type DataCallback = (chunk: Uint8Array) => void;

/**
 * Shared plumbing for the four HarmonyOS socket shapes. Subclasses only map send/close/peer
 * resolution onto their concrete socket object; event fan-out lives here.
 */
abstract class SocketByteLink implements ByteLink {
  protected peerAddress: PeerAddress;
  protected dataCallback: DataCallback | null = null;
  protected closedCallback: (() => void) | null = null;
  protected closed: boolean = false;
  private tls: boolean;

  constructor(peerAddress: PeerAddress, tls: boolean) {
    this.peerAddress = peerAddress;
    this.tls = tls;
  }

  peer(): PeerAddress {
    return this.peerAddress;
  }

  isTls(): boolean {
    return this.tls;
  }

  onData(callback: DataCallback): void {
    this.dataCallback = callback;
  }

  onClosed(callback: () => void): void {
    this.closedCallback = callback;
  }

  protected handleChunk(message: ArrayBuffer): void {
    if (this.dataCallback === null) {
      return;
    }
    this.dataCallback(new Uint8Array(message));
  }

  protected handleClosed(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    if (this.closedCallback !== null) {
      this.closedCallback();
    }
  }

  async peerCertFingerprint(): Promise<string | null> {
    return null;
  }

  abstract send(data: Uint8Array): Promise<void>;

  abstract close(): Promise<void>;
}

function familyOf(raw: number | undefined): IpFamily {
  // NetAddress.family is 1 for IPv4 and 2 for IPv6.
  return raw === 2 ? 'IPv6' : 'IPv4';
}

export class TcpAcceptedLink extends SocketByteLink {
  private conn: socket.TCPSocketConnection;

  constructor(conn: socket.TCPSocketConnection, peer: PeerAddress) {
    super(peer, false);
    this.conn = conn;
    conn.on('message', (info: socket.SocketMessageInfo) => {
      this.handleChunk(info.message);
    });
    conn.on('close', () => {
      this.handleClosed();
    });
  }

  async send(data: Uint8Array): Promise<void> {
    try {
      const options: socket.TCPSendOptions = { data: tightBuffer(data) };
      await this.conn.send(options);
    } catch (e) {
      const error: BusinessError = e as BusinessError;
      throw new TransportError(`tcp send failed: ${error.message}`, error.code);
    }
  }

  async close(): Promise<void> {
    try {
      await this.conn.close();
    } catch (e) {
      // A socket that is already gone is not an error for our state machine.
    }
    this.handleClosed();
  }
}

export class TlsAcceptedLink extends SocketByteLink {
  private conn: socket.TLSSocketConnection;

  constructor(conn: socket.TLSSocketConnection, peer: PeerAddress) {
    super(peer, true);
    this.conn = conn;
    conn.on('message', (info: socket.SocketMessageInfo) => {
      this.handleChunk(info.message);
    });
    conn.on('close', () => {
      this.handleClosed();
    });
  }

  async send(data: Uint8Array): Promise<void> {
    try {
      await this.conn.send(tightBuffer(data));
    } catch (e) {
      const error: BusinessError = e as BusinessError;
      throw new TransportError(`tls send failed: ${error.message}`, error.code);
    }
  }

  async close(): Promise<void> {
    try {
      await this.conn.close();
    } catch (e) {
    }
    this.handleClosed();
  }

  async peerCertFingerprint(): Promise<string | null> {
    try {
      const raw: socket.X509CertRawData = await this.conn.getRemoteCertificate();
      return await sha256Hex(raw.data, true);
    } catch (e) {
      return null;
    }
  }
}

/** Resolves the peer address of an accepted socket; both server connection types expose the same call. */
export async function resolvePeer(
  conn: socket.TCPSocketConnection | socket.TLSSocketConnection,
  fallbackPort: number
): Promise<PeerAddress> {
  try {
    const address: socket.NetAddress = await conn.getRemoteAddress();
    const peer: PeerAddress = {
      host: address.address,
      port: address.port === undefined ? fallbackPort : address.port,
      family: familyOf(address.family)
    };
    return peer;
  } catch (e) {
    const peer: PeerAddress = { host: '', port: fallbackPort, family: 'IPv4' };
    return peer;
  }
}

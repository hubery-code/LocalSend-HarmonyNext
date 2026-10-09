import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ByteLink, PeerAddress } from '../transport/ByteLink';
import { TcpAcceptedLink, TlsAcceptedLink, resolvePeer } from '../transport/AcceptedLinks';
import { HttpConnection } from './Connection';
import { RequestHandler } from './Exchange';
import { MAX_CONNECTIONS, MAX_CONNECTIONS_PER_IP } from '../wire/Constants';

export interface TlsMaterial {
  certPem: string;
  keyPem: string;
  keyPassword: string;
  /**
   * Request a client certificate. Official LocalSend servers make one mandatory, so symmetry asks
   * for it here too — but HarmonyOS validates a requested certificate against its trust store, and
   * a LAN peer's certificate is self-signed, so this stays configurable and defaults to off until
   * verified against the official client.
   */
  requestClientCertificate: boolean;
}

export interface ServerConfig {
  port: number;
  tls: TlsMaterial | null;
  routes: Map<string, RequestHandler>;
  log: (message: string) => void;
}

/**
 * The receiver's HTTP server.
 *
 * LocalSend runs one TCP listener per device on the same port as the UDP multicast group, and both
 * plain and TLS sockets feed the same HTTP/1.1 connection state machine.
 */
export class HttpServer {
  private config: ServerConfig;
  private connections: Set<HttpConnection> = new Set<HttpConnection>();
  private perIp: Map<string, number> = new Map<string, number>();
  private tcp: socket.TCPSocketServer | null = null;
  private tls: socket.TLSSocketServer | null = null;
  private stopped: boolean = false;

  private constructor(config: ServerConfig) {
    this.config = config;
  }

  static async start(config: ServerConfig): Promise<HttpServer> {
    const server: HttpServer = new HttpServer(config);
    await server.listen();
    return server;
  }

  private async listen(): Promise<void> {
    const address: socket.NetAddress = { address: '0.0.0.0', port: this.config.port, family: 1 };
    if (this.config.tls === null) {
      const tcp: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      this.tcp = tcp;
      tcp.on('connect', (conn: socket.TCPSocketConnection) => {
        this.onAccepted(conn);
      });
      tcp.on('error', (err: BusinessError) => {
        this.config.log(`tcp server error ${err.code} ${err.message}`);
      });
      await tcp.listen(address);
      return;
    }
    const tls: socket.TLSSocketServer = socket.constructTLSSocketServerInstance();
    this.tls = tls;
    const material: TlsMaterial = this.config.tls;
    const secureOptions: socket.TLSSecureOptions = {
      cert: material.certPem,
      key: material.keyPem,
      password: material.keyPassword,
      protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13],
      isBidirectionalAuthentication: material.requestClientCertificate
    };
    const options: socket.TLSConnectOptions = {
      address: address,
      secureOptions: secureOptions,
      ALPNProtocols: ['http/1.1']
    };
    tls.on('connect', (conn: socket.TLSSocketConnection) => {
      this.onTlsAccepted(conn);
    });
    tls.on('error', (err: BusinessError) => {
      this.config.log(`tls server error ${err.code} ${err.message}`);
    });
    await tls.listen(options);
  }

  private onTlsAccepted(conn: socket.TLSSocketConnection): void {
    resolvePeer(conn, 0).then((peer: PeerAddress) => {
      this.accept(new TlsAcceptedLink(conn, peer));
    }, (reason: Object) => {
      this.config.log(`failed to resolve tls peer: ${reason}`);
    });
  }

  private onAccepted(conn: socket.TCPSocketConnection): void {
    resolvePeer(conn, 0).then((peer: PeerAddress) => {
      this.accept(new TcpAcceptedLink(conn, peer));
    }, (reason: Object) => {
      this.config.log(`failed to resolve tcp peer: ${reason}`);
    });
  }

  private accept(link: ByteLink): void {
    if (this.stopped) {
      link.close();
      return;
    }
    const host: string = link.peer().host;
    const active: number = this.perIp.get(host) ?? 0;
    if (this.connections.size >= MAX_CONNECTIONS || (host.length > 0 && active >= MAX_CONNECTIONS_PER_IP)) {
      // Over limit: drop without a handshake, matching the official server's connection caps.
      link.close();
      return;
    }
    this.perIp.set(host, active + 1);
    const connection: HttpConnection = new HttpConnection(link, this.config.routes, this.config.log);
    connection.setOnFinished((finished: HttpConnection) => {
      this.release(finished);
    });
    this.connections.add(connection);
    connection.start();
  }

  private release(connection: HttpConnection): void {
    if (!this.connections.delete(connection)) {
      return;
    }
    const host: string = connection.peerHost;
    const active: number = this.perIp.get(host) ?? 0;
    if (active <= 1) {
      this.perIp.delete(host);
    } else {
      this.perIp.set(host, active - 1);
    }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    const snapshot: HttpConnection[] = [];
    this.connections.forEach((connection: HttpConnection) => {
      snapshot.push(connection);
    });
    snapshot.forEach((connection: HttpConnection) => {
      connection.close('server stopped');
    });
    this.connections.clear();
    this.perIp.clear();
    try {
      if (this.tcp !== null) {
        await this.tcp.close();
      }
      if (this.tls !== null) {
        await this.tls.close();
      }
    } catch (e) {
      this.config.log(`listener close reported: ${e}`);
    }
  }
}

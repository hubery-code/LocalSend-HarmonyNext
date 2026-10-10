import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { IdentityStore, StoredIdentity } from '@lsnext/protocol';

const STORE_NAME: string = 'localsend';
const KEY_ALIAS: string = 'alias';
const KEY_CERT: string = 'certPem';
const KEY_KEY: string = 'keyPem';
const KEY_KEY_PASSWORD: string = 'keyPassword';
const KEY_FINGERPRINT: string = 'fingerprint';
const KEY_ENCRYPTION: string = 'encryption';
const KEY_RECEIVING: string = 'receiving';
const KEY_KNOWN_HOSTS: string = 'knownHosts';

/**
 * The app's settings and the device identity, in one preferences file.
 *
 * The identity implements the protocol's `IdentityStore` contract: the HAR decides
 * *what* an identity is, this decides only *where* it lives, which is what keeps the
 * protocol layer free of any UI-framework dependency.
 */
export class AppPrefs implements IdentityStore {
  private readonly prefs: preferences.Preferences;

  private constructor(prefs: preferences.Preferences) {
    this.prefs = prefs;
  }

  static async open(context: common.UIAbilityContext): Promise<AppPrefs> {
    const prefs: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
    return new AppPrefs(prefs);
  }

  async load(): Promise<StoredIdentity | null> {
    const fingerprint: string = this.prefs.getSync(KEY_FINGERPRINT, '') as string;
    if (fingerprint.length === 0) {
      return null;
    }
    const stored: StoredIdentity = {
      certPem: this.prefs.getSync(KEY_CERT, '') as string,
      keyPem: this.prefs.getSync(KEY_KEY, '') as string,
      keyPassword: this.prefs.getSync(KEY_KEY_PASSWORD, '') as string,
      fingerprint: fingerprint
    };
    return stored;
  }

  async save(identity: StoredIdentity): Promise<void> {
    this.prefs.putSync(KEY_CERT, identity.certPem);
    this.prefs.putSync(KEY_KEY, identity.keyPem);
    this.prefs.putSync(KEY_KEY_PASSWORD, identity.keyPassword);
    this.prefs.putSync(KEY_FINGERPRINT, identity.fingerprint);
    await this.prefs.flush();
  }

  /** The alias the official clients default to: the device's marketing name. */
  alias(): string {
    const stored: string = this.prefs.getSync(KEY_ALIAS, '') as string;
    if (stored.length > 0) {
      return stored;
    }
    return deviceInfo.marketName;
  }

  async setAlias(alias: string): Promise<void> {
    this.prefs.putSync(KEY_ALIAS, alias);
    await this.prefs.flush();
  }

  /**
   * Encryption on means HTTPS with the device certificate. Off is plain HTTP with a
   * random fingerprint, which is also the only mode verified against the emulator so far.
   */
  encryption(): boolean {
    return this.prefs.getSync(KEY_ENCRYPTION, false) as boolean;
  }

  async setEncryption(enabled: boolean): Promise<void> {
    this.prefs.putSync(KEY_ENCRYPTION, enabled);
    await this.prefs.flush();
  }

  /** Official mobile clients receive as soon as the app is open, so on is the default. */
  receiving(): boolean {
    return this.prefs.getSync(KEY_RECEIVING, true) as boolean;
  }

  async setReceiving(enabled: boolean): Promise<void> {
    this.prefs.putSync(KEY_RECEIVING, enabled);
    await this.prefs.flush();
  }

  /**
   * Addresses the user added by hand. Without multicast there is nothing else to point
   * discovery at, so these have to survive a restart.
   */
  knownHosts(): string[] {
    const stored: string[] = this.prefs.getSync(KEY_KNOWN_HOSTS, []) as string[];
    return stored.slice(0);
  }

  async setKnownHosts(specs: string[]): Promise<void> {
    this.prefs.putSync(KEY_KNOWN_HOSTS, specs.slice(0));
    await this.prefs.flush();
  }
}

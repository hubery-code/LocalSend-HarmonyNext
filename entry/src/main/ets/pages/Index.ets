import { PROTOCOL_VERSION, DEFAULT_PORT } from '@lsnext/protocol';

@Entry
@Component
struct Index {
  @State banner: string = `LocalSend HarmonyNEXT · protocol v${PROTOCOL_VERSION} · port ${DEFAULT_PORT}`;

  build() {
    Column() {
      Text(this.banner)
        .fontSize(18)
        .padding(24)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}

export import class NativeWebShellApp from "native_webshell.hpp" as doof_webshell::NativeWebShellApp {
  static create(htmlPath: string, title: string, width: int, height: int): NativeWebShellApp
  postEvent(eventJson: string): Result<void, string>
  requestWake(): void
  stop(): void
  run(onCall: (requestJson: string): string, drainEvents: (): int): Result<void, string>
}

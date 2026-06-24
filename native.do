export import class NativeWebShellApp from "native_webshell.hpp" as doof_webshell::NativeWebShellApp {
  static create(htmlPath: string, title: string, width: int, height: int): NativeWebShellApp
  postEvent(eventJson: string): Result<void, string>
  beginOpenFileDialog(requestJson: string): Result<void, string>
  beginSaveFileDialog(requestJson: string): Result<void, string>
  setMenuConfiguration(menuJson: string): Result<void, string>
  beginRequestNotificationPermission(requestJson: string): Result<void, string>
  beginPostNotification(requestJson: string): Result<void, string>
  beginReadClipboardText(requestJson: string): Result<void, string>
  beginWriteClipboardText(requestJson: string): Result<void, string>
  requestWake(): void
  stop(): void
  run(onCall: (requestJson: string): string, drainEvents: (): int): Result<void, string>
}

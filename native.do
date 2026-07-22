export import class NativeWebShellApp from "native_webshell.hpp" as doof_webshell::NativeWebShellApp {
  static create(htmlPath: string, title: string, width: int, height: int): NativeWebShellApp
  postEvent(eventJson: string): Result<none, string>
  beginOpenFileDialog(requestJson: string): Result<none, string>
  beginSaveFileDialog(requestJson: string): Result<none, string>
  setMenuConfiguration(menuJson: string): Result<none, string>
  beginRequestNotificationPermission(requestJson: string): Result<none, string>
  beginPostNotification(requestJson: string): Result<none, string>
  beginReadClipboardText(requestJson: string): Result<none, string>
  beginWriteClipboardText(requestJson: string): Result<none, string>
  requestWake(): none
  stop(): none
  run(onCall: (requestJson: string): string, drainEvents: (): int): Result<none, string>
}

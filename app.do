import {
  clearMainEventWakeHandler,
  drainMainEventLoop,
  setMainEventWakeHandler,
} from "std/event"
import { formatJsonValue } from "std/json"

import { WebShellBridgeRegistry, WebShellHandler } from "./bridge"
import { NativeWebShellApp } from "./native"
import { WebShellOptions } from "./options"

export class WebShellApp {
  readonly htmlPath: string
  readonly options: WebShellOptions
  private readonly native: NativeWebShellApp
  private bridge: WebShellBridgeRegistry

  static constructor(htmlPath: string, options: WebShellOptions = WebShellOptions {}): WebShellApp {
    if htmlPath.length == 0 {
      panic("Web shell HTML path must not be empty")
    }
    if options.width <= 0 || options.height <= 0 {
      panic("Web shell window dimensions must be positive")
    }
    return WebShellApp {
      htmlPath,
      options,
      native: NativeWebShellApp.create(htmlPath, options.title, options.width, options.height),
      bridge: WebShellBridgeRegistry {},
    }
  }

  bind(name: string, handler: WebShellHandler): WebShellApp {
    bridge.bind(name, handler)
    return this
  }

  postEvent(name: string, payload: JsonValue = null): Result<void, string> {
    if name.length == 0 {
      panic("Web shell event name must not be empty")
    }
    event: JsonObject := {}
    event.set("name", name)
    event.set("payload", payload)
    return native.postEvent(formatJsonValue(event))
  }

  stop(): void {
    native.stop()
  }

  run(): Result<void, string> {
    setMainEventWakeHandler((): void => native.requestWake())
    result := native.run(
      (requestJson: string): string => bridge.dispatch(requestJson),
      (): int => drainMainEventLoop(),
    )
    clearMainEventWakeHandler()
    return result
  }
}

export function initWebShellApp(
  htmlPath: string,
  options: WebShellOptions = WebShellOptions {},
): WebShellApp {
  return WebShellApp(htmlPath, options)
}

import { Assert } from "std/assert"
import { parseJsonValue } from "std/json"

import { WebShellBridgeRegistry } from "./bridge"
import {
  validateClipboardReadTextRequest,
  validateClipboardWriteTextRequest,
} from "./clipboard"
import { validateNativeDialogRequest } from "./dialogs"
import {
  renderWebShellMenuConfiguration,
  WebShellMenu,
  WebShellMenuItem,
} from "./menu"
import {
  validateNotificationPermissionRequest,
  validatePostNotificationRequest,
} from "./notifications"

function responseObject(text: string): JsonObject {
  value := try! parseJsonValue(text)
  return try! value as JsonObject
}

export function testDispatchesBindingWithParams(): void {
  registry := WebShellBridgeRegistry {}
  registry.bind("echo", (params: JsonValue): Result<JsonValue, string> => Success(params))

  response := responseObject(registry.dispatch("{\"id\":\"1\",\"name\":\"echo\",\"params\":{\"ok\":true}}"))
  Assert.equal(response.get("id")!, "1")
  Assert.equal(response.get("ok")!, true)
  value := try! response.get("value")! as JsonObject
  Assert.equal(value.get("ok")!, true)
}

export function testDefaultsOmittedParamsToNull(): void {
  registry := WebShellBridgeRegistry {}
  let received: JsonValue = false
  registry.bind("empty", (params: JsonValue): Result<JsonValue, string> => {
    received = params
    return Success(null)
  })

  response := responseObject(registry.dispatch("{\"id\":\"2\",\"name\":\"empty\"}"))
  Assert.equal(received, null)
  Assert.equal(response.get("ok")!, true)
  Assert.equal(response.get("value")!, null)
}

export function testBindingReplacement(): void {
  registry := WebShellBridgeRegistry {}
  registry.bind("value", (params: JsonValue): Result<JsonValue, string> => Success("old"))
  registry.bind("value", (params: JsonValue): Result<JsonValue, string> => Success("new"))

  response := responseObject(registry.dispatch("{\"id\":\"3\",\"name\":\"value\"}"))
  Assert.equal(response.get("value")!, "new")
}

export function testReportsHandlerFailure(): void {
  registry := WebShellBridgeRegistry {}
  registry.bind("fail", (params: JsonValue): Result<JsonValue, string> => Failure("nope"))

  response := responseObject(registry.dispatch("{\"id\":\"4\",\"name\":\"fail\"}"))
  Assert.equal(response.get("ok")!, false)
  Assert.equal(response.get("error")!, "nope")
}

export function testReportsUnknownBinding(): void {
  registry := WebShellBridgeRegistry {}
  response := responseObject(registry.dispatch("{\"id\":\"5\",\"name\":\"missing\"}"))
  Assert.equal(response.get("ok")!, false)
  Assert.equal(response.get("error")!, "No Doof binding registered for 'missing'")
}

export function testReportsMalformedRequests(): void {
  registry := WebShellBridgeRegistry {}
  malformed := responseObject(registry.dispatch("not json"))
  Assert.equal(malformed.get("ok")!, false)

  missingName := responseObject(registry.dispatch("{\"id\":\"6\"}"))
  Assert.equal(missingName.get("id")!, "6")
  Assert.equal(missingName.get("ok")!, false)
}

export function testValidatesNativeDialogRequests(): void {
  request := try! validateNativeDialogRequest({ id: "dialog-1", options: { multiple: true } }, "openFile")
  parsed := responseObject(request)
  Assert.equal(parsed.get("id")!, "dialog-1")
  options := try! parsed.get("options")! as JsonObject
  Assert.equal(options.get("multiple")!, true)

  missing := validateNativeDialogRequest({}, "openFile")
  case missing {
    _: Success -> Assert.fail("expected missing id to fail")
    failure: Failure -> Assert.equal(failure.error, "openFile request is missing string id")
  }

  badOptions := validateNativeDialogRequest({ id: "dialog-2", options: false }, "saveFile")
  case badOptions {
    _: Success -> Assert.fail("expected non-object options to fail")
    failure: Failure -> Assert.equal(failure.error, "saveFile options must be an object when provided")
  }
}

export function testRendersMenuConfiguration(): void {
  config := try! renderWebShellMenuConfiguration([
    WebShellMenu {
      title: "File",
      items: [
        WebShellMenuItem {
          id: "open",
          title: "Open...",
          shortcut: "o",
        },
        WebShellMenuItem {
          id: "save",
          title: "Save",
          shortcut: "s",
          enabled: false,
        },
      ],
    },
  ])

  parsed := responseObject(config)
  menus := try! parsed.get("menus")! as JsonValue[]
  menu := try! menus[0] as JsonObject
  Assert.equal(menu.get("title")!, "File")
  items := try! menu.get("items")! as JsonValue[]
  item := try! items[1] as JsonObject
  Assert.equal(item.get("id")!, "save")
  Assert.equal(item.get("enabled")!, false)
}

export function testRejectsInvalidMenuConfiguration(): void {
  result := renderWebShellMenuConfiguration([
    WebShellMenu {
      title: "File",
      items: [
        WebShellMenuItem {
          id: "",
          title: "Open",
        },
      ],
    },
  ])

  case result {
    _: Success -> Assert.fail("expected invalid menu item to fail")
    failure: Failure -> Assert.equal(failure.error, "Web shell menu item id must not be empty")
  }
}

export function testValidatesNotificationPermissionRequests(): void {
  request := try! validateNotificationPermissionRequest({
    id: "notify-permission",
    options: {
      alert: true,
      sound: false,
      badge: true,
    },
  })

  parsed := responseObject(request)
  Assert.equal(parsed.get("id")!, "notify-permission")
  options := try! parsed.get("options")! as JsonObject
  Assert.equal(options.get("sound")!, false)

  invalid := validateNotificationPermissionRequest({ id: "bad", options: true })
  case invalid {
    _: Success -> Assert.fail("expected invalid notification permission options to fail")
    failure: Failure -> Assert.equal(failure.error, "requestNotificationPermission options must be an object when provided")
  }
}

export function testValidatesPostNotificationRequests(): void {
  request := try! validatePostNotificationRequest({
    id: "notify-post",
    options: {
      id: "custom-notification",
      title: "Build complete",
      subtitle: "WebShell",
      body: "The sample finished building.",
      sound: false,
      badge: 2,
      delaySeconds: 1.5,
      userInfo: {
        source: "test",
      },
    },
  })

  parsed := responseObject(request)
  options := try! parsed.get("options")! as JsonObject
  Assert.equal(options.get("id")!, "custom-notification")
  Assert.equal(options.get("title")!, "Build complete")
  Assert.equal(options.get("subtitle")!, "WebShell")
  Assert.equal(options.get("body")!, "The sample finished building.")
  Assert.equal(options.get("sound")!, false)
  Assert.equal(options.get("badge")!, 2)
  Assert.equal(options.get("delaySeconds")!, 1.5)
  userInfo := try! options.get("userInfo")! as JsonObject
  Assert.equal(userInfo.get("source")!, "test")

  missingTitle := validatePostNotificationRequest({ id: "notify-post", options: {} })
  case missingTitle {
    _: Success -> Assert.fail("expected missing notification title to fail")
    failure: Failure -> Assert.equal(failure.error, "postNotification options are missing string title")
  }

  badUserInfo := validatePostNotificationRequest({
    id: "notify-post",
    options: {
      title: "Bad",
      userInfo: false,
    },
  })
  case badUserInfo {
    _: Success -> Assert.fail("expected invalid notification userInfo to fail")
    failure: Failure -> Assert.equal(failure.error, "postNotification userInfo must be an object when provided")
  }
}

export function testValidatesClipboardRequests(): void {
  readRequest := try! validateClipboardReadTextRequest({ id: "clipboard-read", options: {} })
  readParsed := responseObject(readRequest)
  Assert.equal(readParsed.get("id")!, "clipboard-read")

  writeRequest := try! validateClipboardWriteTextRequest({
    id: "clipboard-write",
    options: {
      text: "hello clipboard",
    },
  })
  writeParsed := responseObject(writeRequest)
  options := try! writeParsed.get("options")! as JsonObject
  Assert.equal(options.get("text")!, "hello clipboard")

  missingText := validateClipboardWriteTextRequest({ id: "clipboard-write", options: {} })
  case missingText {
    _: Success -> Assert.fail("expected missing clipboard text to fail")
    failure: Failure -> Assert.equal(failure.error, "writeClipboardText options are missing string text")
  }

  badOptions := validateClipboardReadTextRequest({ id: "clipboard-read", options: true })
  case badOptions {
    _: Success -> Assert.fail("expected invalid clipboard options to fail")
    failure: Failure -> Assert.equal(failure.error, "readClipboardText options must be an object when provided")
  }
}

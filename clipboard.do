import { formatJsonValue } from "std/json"

import { WebShellApp } from "./app"

readonly READ_TEXT_BINDING = "__webshell.native.readClipboardText"
readonly WRITE_TEXT_BINDING = "__webshell.native.writeClipboardText"

export function installWebShellClipboard(app: WebShellApp): void {
  app.bind(READ_TEXT_BINDING, (params: JsonValue): Result<JsonValue, string> => {
    try requestJson := validateClipboardReadTextRequest(params)
    try app.beginReadClipboardText(requestJson)
    return Success(nativeAcceptedValue(params))
  })

  app.bind(WRITE_TEXT_BINDING, (params: JsonValue): Result<JsonValue, string> => {
    try requestJson := validateClipboardWriteTextRequest(params)
    try app.beginWriteClipboardText(requestJson)
    return Success(nativeAcceptedValue(params))
  })
}

export function validateClipboardReadTextRequest(params: JsonValue): Result<string, string> {
  return validateClipboardRequest(params, "readClipboardText", false)
}

export function validateClipboardWriteTextRequest(params: JsonValue): Result<string, string> {
  return validateClipboardRequest(params, "writeClipboardText", true)
}

function validateClipboardRequest(
  params: JsonValue,
  operation: string,
  requiresText: bool,
): Result<string, string> {
  object := params as JsonObject else {
    return Failure(operation + " request must be an object")
  }

  idValue := object.get("id") else {
    return Failure(operation + " request is missing string id")
  }
  id := idValue as string else {
    return Failure(operation + " request id must be a string")
  }
  if id.length == 0 {
    return Failure(operation + " request id must not be empty")
  }

  if object.has("options") {
    options := object.get("options")!
    if options != null {
      optionsObject := options as JsonObject else {
        return Failure(operation + " options must be an object when provided")
      }
      if requiresText {
        textValue := optionsObject.get("text") else {
          return Failure(operation + " options are missing string text")
        }
        _ := textValue as string else {
          return Failure(operation + " text must be a string")
        }
      }
    } else if requiresText {
      return Failure(operation + " options are missing string text")
    }
  } else if requiresText {
    return Failure(operation + " options are missing string text")
  }

  return Success(formatJsonValue(object))
}

function nativeAcceptedValue(params: JsonValue): JsonValue {
  object := try! params as JsonObject
  id := try! object.get("id")! as string
  response: JsonObject := {}
  response.set("id", id)
  response.set("accepted", true)
  return response
}

import { formatJsonValue } from "std/json"

import { WebShellApp } from "./app"

readonly OPEN_FILE_BINDING = "__webshell.native.openFile"
readonly SAVE_FILE_BINDING = "__webshell.native.saveFile"

export function installWebShellDialogs(app: WebShellApp): none {
  app.bind(OPEN_FILE_BINDING, (params: SerialValue): Result<SerialValue, string> => {
    try requestJson := validateNativeDialogRequest(params, "openFile")
    try app.beginOpenFileDialog(requestJson)
    return Success(nativeAcceptedValue(params))
  })

  app.bind(SAVE_FILE_BINDING, (params: SerialValue): Result<SerialValue, string> => {
    try requestJson := validateNativeDialogRequest(params, "saveFile")
    try app.beginSaveFileDialog(requestJson)
    return Success(nativeAcceptedValue(params))
  })
}

export function validateNativeDialogRequest(params: SerialValue, operation: string): Result<string, string> {
  object := params as SerialObject else {
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
    if options != none {
      _ := options as SerialObject else {
        return Failure(operation + " options must be an object when provided")
      }
    }
  }

  return Success(formatJsonValue(object))
}

function nativeAcceptedValue(params: SerialValue): SerialValue {
  object := try! params as SerialObject
  id := try! object.get("id")! as string
  response: SerialObject := { "id": id, "accepted": true }
  return response
}

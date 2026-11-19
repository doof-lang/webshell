import { formatJsonValue, parseJsonValue } from "std/json"

export type WebShellHandler = (params: SerialValue): Result<SerialValue, string>

export class WebShellBridgeRegistry {
  private handlers: Map<string, WebShellHandler> = {}

  bind(name: string, handler: WebShellHandler): none {
    if name.length == 0 {
      panic("Web shell binding name must not be empty")
    }
    handlers.set(name, handler)
  }

  dispatch(requestJson: string): string {
    request := parseJsonValue(requestJson) else error {
      return failureResponse("", "Invalid bridge request JSON: ${error}")
    }
    object := request as SerialObject else error {
      return failureResponse("", "Invalid bridge request: ${error}")
    }

    idValue := object.get("id") else {
      return failureResponse("", "Invalid bridge request: missing string id")
    }
    id := idValue as string else {
      return failureResponse("", "Invalid bridge request: id must be a string")
    }
    nameValue := object.get("name") else {
      return failureResponse(id, "Invalid bridge request: missing string name")
    }
    name := nameValue as string else {
      return failureResponse(id, "Invalid bridge request: name must be a string")
    }

    params: SerialValue := object.get("params") ?? none

    handler := handlers.get(name) else {
      return failureResponse(id, "No Doof binding registered for '${name}'")
    }
    return case handler.call(params) {
      success: Success -> successResponse(id, success.value),
      failure: Failure -> failureResponse(id, failure.error),
    }
  }
}

function successResponse(id: string, value: SerialValue): string {
  response: SerialObject := { "id": id, "ok": true, "value": value }
  return formatJsonValue(response)
}

function failureResponse(id: string, error: string): string {
  response: SerialObject := { "id": id, "ok": false, "error": error }
  return formatJsonValue(response)
}

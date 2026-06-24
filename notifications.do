import { formatJsonValue } from "std/json"

import { WebShellApp } from "./app"

const REQUEST_PERMISSION_BINDING = "__webshell.native.requestNotificationPermission"
const POST_NOTIFICATION_BINDING = "__webshell.native.postNotification"

export function installWebShellNotifications(app: WebShellApp): void {
  app.bind(REQUEST_PERMISSION_BINDING, (params: JsonValue): Result<JsonValue, string> => {
    try requestJson := validateNotificationPermissionRequest(params)
    try app.beginRequestNotificationPermission(requestJson)
    return Success(nativeAcceptedValue(params))
  })

  app.bind(POST_NOTIFICATION_BINDING, (params: JsonValue): Result<JsonValue, string> => {
    try requestJson := validatePostNotificationRequest(params)
    try app.beginPostNotification(requestJson)
    return Success(nativeAcceptedValue(params))
  })
}

export function validateNotificationPermissionRequest(params: JsonValue): Result<string, string> {
  return validateNotificationRequest(params, "requestNotificationPermission", false)
}

export function validatePostNotificationRequest(params: JsonValue): Result<string, string> {
  return validateNotificationRequest(params, "postNotification", true)
}

function validateNotificationRequest(
  params: JsonValue,
  operation: string,
  requiresTitle: bool,
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
      if requiresTitle {
        titleValue := optionsObject.get("title") else {
          return Failure(operation + " options are missing string title")
        }
        title := titleValue as string else {
          return Failure(operation + " title must be a string")
        }
        if title.length == 0 {
          return Failure(operation + " title must not be empty")
        }
      }
      if optionsObject.has("userInfo") {
        userInfo := optionsObject.get("userInfo")!
        if userInfo != null {
          _ := userInfo as JsonObject else {
            return Failure(operation + " userInfo must be an object when provided")
          }
        }
      }
    } else if requiresTitle {
      return Failure(operation + " options are missing string title")
    }
  } else if requiresTitle {
    return Failure(operation + " options are missing string title")
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

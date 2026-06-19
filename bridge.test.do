import { Assert } from "std/assert"
import { parseJsonValue } from "std/json"

import { WebShellBridgeRegistry } from "./bridge"

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

import { initWebShellApp } from "std/webshell"
import { join, resourcesDirectory } from "std/path"

function main(): int {
  resources := resourcesDirectory() else error {
    println("Could not locate app resources: " + error)
    return 1
  }

  app := initWebShellApp{
    htmlPath: join([resources, "web/index.html"]),
    options: {
      title: "Doof WebShell",
      width: 720,
      height: 520,
    },
  }

  app.bind("greet", (params: JsonValue): Result<JsonValue, string> => {
    name := params as string else {
      return Failure("greet expects a string name")
    }

    message := "Hello, " + name + "!"
    try app.postEvent("greeted", message)
    return Success(message)
  })

  result := app.run()
  case result {
    _: Success -> return 0
    failure: Failure -> {
      println("WebShell failed: " + failure.error)
      return 1
    }
  }
}

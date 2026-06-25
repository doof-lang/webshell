# std/webshell

`std/webshell` hosts a bundled HTML file inside a native WebKit shell and
connects JavaScript to Doof through a small JSON bridge.

It is useful for lightweight desktop or mobile UI where the application logic
stays in Doof and the interface is written with ordinary HTML, CSS, and
JavaScript.

## Documentation

- [Guide and API reference](docs/API.md) explains app lifecycle, JSON bridge calls, queued events, dialogs, menus, notifications, clipboard, and platform scope.
- Tests can be run with `doof test webshell`.
- [Samples](samples/) show complete programs built with this module.

## Basic app

```doof
import { initWebShellApp } from "std/webshell"
import { join, resourcesDirectory } from "std/path"

function main(): int {
  resources := resourcesDirectory() else error {
    println("Could not locate resources: " + error)
    return 1
  }

  app := initWebShellApp{
    htmlPath: join([resources, "web/index.html"]),
    options: {
      title: "My App",
      width: 900,
      height: 640,
    },
  }

  app.bind("greet", (params: JsonValue): Result<JsonValue, string> => {
    name := params as string else {
      return Failure("greet expects a string")
    }
    return Success("Hello, " + name + "!")
  })

  result := app.run()
  return case result {
    _: Success -> 0
    failure: Failure -> {
      println("WebShell failed: " + failure.error)
      1
    }
  }
}
```

In JavaScript, call Doof bindings with `window.doof.call`:

```js
const message = await doof.call("greet", "WebShell");
```

## Events

Doof can send events to the web page:

```doof
try app.postEvent("saved", { path: "/tmp/file.txt" })
```

JavaScript can listen for them:

```js
const unsubscribe = doof.on("saved", (payload) => {
  console.log(payload.path);
});
```

Events posted before the page is ready are queued and delivered after the
initial navigation finishes.

## Native dialogs

Install the built-in dialog bindings before `run()`:

```doof
import { initWebShellApp, installWebShellDialogs } from "std/webshell"

app := initWebShellApp("web/index.html")
installWebShellDialogs(app)
```

JavaScript can then open native dialogs:

```js
const path = await doof.native.openFile({
  title: "Open File",
  types: ["txt", "md"],
});

const savePath = await doof.native.saveFile({
  title: "Save File",
  suggestedName: "untitled.txt",
  types: ["txt"],
});
```

`openFile` options:

- `multiple?: boolean`
- `directories?: boolean`
- `types?: string[]`
- `title?: string`

`saveFile` options:

- `suggestedName?: string`
- `types?: string[]`
- `title?: string`

Dialog cancellation resolves to `null`. Open-file with `multiple: true` resolves
to an array of paths. Returned paths are selection grants only; use `std/fs` for
file contents.

On iOS, open-file uses `UIDocumentPickerViewController`. Save dialogs are not
implemented yet and reject with an explanatory error.

## Menus

Native menu configuration is available on macOS:

```doof
import {
  configureWebShellMenus,
  WebShellMenu,
  WebShellMenuItem,
} from "std/webshell"

try configureWebShellMenus(app, [
  WebShellMenu {
    title: "File",
    items: [
      WebShellMenuItem {
        id: "open-file",
        title: "Open File...",
        shortcut: "o",
      },
      WebShellMenuItem {
        id: "save-file",
        title: "Save File...",
        shortcut: "s",
      },
    ],
  },
])
```

JavaScript receives menu selections as events:

```js
doof.on("menuCommand", ({ id }) => {
  if (id === "open-file") openFile();
});
```

iOS accepts menu configuration as a no-op so shared applications can use one
code path.

## Notifications

Install the built-in notification bindings before `run()`:

```doof
import { initWebShellApp, installWebShellNotifications } from "std/webshell"

app := initWebShellApp("web/index.html")
installWebShellNotifications(app)
```

JavaScript can request permission and post local notifications:

```js
const permission = await doof.native.requestNotificationPermission();

if (permission.granted) {
  await doof.native.postNotification({
    id: "build-complete",
    title: "Build complete",
    body: "The app finished building.",
    userInfo: { source: "sample" },
  });
}
```

Notification options:

- `id?: string`
- `title: string`
- `body?: string`
- `subtitle?: string`
- `sound?: boolean`
- `badge?: number | null`
- `delaySeconds?: number`
- `userInfo?: object`

Notification clicks or taps are delivered to JavaScript:

```js
doof.on("notificationResponse", ({ id, action, userInfo }) => {
  console.log(id, action, userInfo);
});
```

Notifications are local only. Remote push/APNs registration is not part of this
module yet.

## Clipboard

Install the built-in clipboard bindings before `run()`:

```doof
import { initWebShellApp, installWebShellClipboard } from "std/webshell"

app := initWebShellApp("web/index.html")
installWebShellClipboard(app)
```

JavaScript can read and write plain text:

```js
await doof.native.writeClipboardText("Copied from WebShell");
const text = await doof.native.readClipboardText();
```

Clipboard support currently covers plain text only.

## API

### `initWebShellApp(htmlPath, options?)`

Create a `WebShellApp`.

`htmlPath` must point to the HTML entry file. Relative paths are resolved
against the current working directory and app resources.

`WebShellOptions` fields:

- `title: string = "Doof"`
- `width: int = 1024`
- `height: int = 768`

### `WebShellApp.bind(name, handler)`

Register a bridge handler callable from JavaScript as `doof.call(name, params)`.

Handlers receive a `JsonValue` and return `Result<JsonValue, string>`.

### `WebShellApp.postEvent(name, payload?)`

Send an event to JavaScript listeners registered with `doof.on`.

### `WebShellApp.run()`

Run the native shell. The macOS shell must run on the main thread. `run()` may
only be called once per app instance.

### `installWebShellDialogs(app)`

Install built-in bridge bindings for `doof.native.openFile` and
`doof.native.saveFile`.

### `configureWebShellMenus(app, menus)`

Configure native application menus. Menu item selections are emitted as
`menuCommand` events.

### `installWebShellNotifications(app)`

Install built-in bridge bindings for `doof.native.requestNotificationPermission`
and `doof.native.postNotification`.

### `installWebShellClipboard(app)`

Install built-in bridge bindings for `doof.native.readClipboardText` and
`doof.native.writeClipboardText`.

## Sample

From the `doof-stdlib` directory:

```sh
doof run webshell/samples/basic
```

Build the iOS variant without launching it:

```sh
doof build --target ios-app webshell/samples/basic
```

## Tests

```sh
doof test webshell
```

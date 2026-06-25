# std/webshell Guide

`std/webshell` hosts bundled HTML in a native WebKit shell and connects
JavaScript to Doof through a JSON bridge. It is for lightweight UI where Doof
owns application logic and web code owns presentation.

## App Lifecycle

Create a `WebShellApp` with `initWebShellApp`, register bindings and optional
native features, then call `run()`. The HTML entry file must be available in the
application resources or at the resolved filesystem path.

`WebShellOptions` controls title and initial window size.

## JSON Bridge

Doof bindings are registered with `app.bind(name, handler)`. JavaScript calls
them with `doof.call(name, params)`. Parameters and return values are
`JsonValue`; handler failures reject the JavaScript promise with the returned
error string.

Doof can send page events with `app.postEvent(name, payload)`. JavaScript
subscribes with `doof.on(name, handler)`. Events posted before the page is ready
are queued and delivered after initial navigation finishes.

## Built-In Native Features

Install optional bindings before `run()`:

- `installWebShellDialogs`
- `installWebShellNotifications`
- `installWebShellClipboard`

Menu configuration is separate through `configureWebShellMenus`.

Dialogs return selected paths or `null` on cancellation. Notifications are local
only; remote push/APNs registration is out of scope. Clipboard support currently
covers plain text.

## Platform Scope

The native shell is WebKit-based. macOS supports menus and file dialogs. iOS
uses document picker support for opening files and treats menu configuration as
a no-op so shared code can use one path.

## API Map

Core:

- `initWebShellApp`
- `WebShellApp`
- `WebShellOptions`

Bridge and native features:

- dialogs installer and validators
- notification installer and validators
- clipboard installer and validators
- `WebShellMenu`
- `WebShellMenuItem`
- `configureWebShellMenus`

Declarations are defined across [index.do](../index.do), [app.do](../app.do),
[options.do](../options.do), [bridge.do](../bridge.do), and feature-specific
files in this module.

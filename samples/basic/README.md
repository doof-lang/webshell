# Basic WebShell sample

This sample bundles a small HTML page in a native app. JavaScript calls the
Doof `greet` binding through `window.doof.call`, while Doof sends a `greeted`
event back through `WebShellApp.postEvent`.

From the `doof-stdlib` directory:

```sh
doof run webshell/samples/basic
```

Build the iOS variant without launching it:

```sh
doof build --target ios-app webshell/samples/basic
```

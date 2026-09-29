import { formatJsonValue } from "std/json"

import { WebShellApp } from "./app"

export class WebShellMenuItem {
  readonly id: string
  readonly title: string
  readonly shortcut: string = ""
  readonly enabled: bool = true
}

export class WebShellMenu {
  readonly title: string
  readonly items: WebShellMenuItem[] = []
}

export function configureWebShellMenus(app: WebShellApp, menus: WebShellMenu[]): Result<none, string> {
  try menuJson := renderWebShellMenuConfiguration(menus)
  return app.setMenuConfiguration(menuJson)
}

export function renderWebShellMenuConfiguration(menus: WebShellMenu[]): Result<string, string> {
  let menuValues: SerialValue[] = []
  for menu of menus {
    if menu.title.length == 0 {
      return Failure("Web shell menu title must not be empty")
    }

    let itemValues: SerialValue[] = []
    for item of menu.items {
      if item.id.length == 0 {
        return Failure("Web shell menu item id must not be empty")
      }
      if item.title.length == 0 {
        return Failure("Web shell menu item title must not be empty")
      }

      itemObject: SerialObject := { "id": item.id, "title": item.title, "shortcut": item.shortcut, "enabled": item.enabled }
      itemValues.push(itemObject)
    }

    menuObject: SerialObject := { "title": menu.title, "items": itemValues.drainToReadonly() }
    menuValues.push(menuObject)
  }

  root: SerialObject := { "menus": menuValues.drainToReadonly() }
  return Success(formatJsonValue(root))
}

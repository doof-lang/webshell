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

export function configureWebShellMenus(app: WebShellApp, menus: WebShellMenu[]): Result<void, string> {
  try menuJson := renderWebShellMenuConfiguration(menus)
  return app.setMenuConfiguration(menuJson)
}

export function renderWebShellMenuConfiguration(menus: WebShellMenu[]): Result<string, string> {
  let menuValues: JsonValue[] = []
  for menu of menus {
    if menu.title.length == 0 {
      return Failure("Web shell menu title must not be empty")
    }

    menuObject: JsonObject := {}
    menuObject.set("title", menu.title)

    let itemValues: JsonValue[] = []
    for item of menu.items {
      if item.id.length == 0 {
        return Failure("Web shell menu item id must not be empty")
      }
      if item.title.length == 0 {
        return Failure("Web shell menu item title must not be empty")
      }

      itemObject: JsonObject := {}
      itemObject.set("id", item.id)
      itemObject.set("title", item.title)
      itemObject.set("shortcut", item.shortcut)
      itemObject.set("enabled", item.enabled)
      itemValues.push(itemObject)
    }

    menuObject.set("items", itemValues)
    menuValues.push(menuObject)
  }

  root: JsonObject := {}
  root.set("menus", menuValues)
  return Success(formatJsonValue(root))
}

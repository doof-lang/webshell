#pragma once

#import <Foundation/Foundation.h>

#include <string>

namespace doof_webshell::detail {

inline NSString* bridgeScript() {
    return @R"JS((function () {
  let sequence = 0;
  let nativeSequence = 0;
  const pending = new Map();
  const pendingNative = new Map();
  const listeners = new Map();

  function call(name, params = null) {
    if (typeof name !== "string" || name.length === 0) {
      return Promise.reject(new Error("Doof binding name must be a non-empty string"));
    }
    const id = `${Date.now()}-${++sequence}`;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      try {
        window.webkit.messageHandlers.doof.postMessage({ id, name, params });
      } catch (error) {
        pending.delete(id);
        reject(error);
      }
    });
  }

  function on(name, handler) {
    if (typeof name !== "string" || name.length === 0 || typeof handler !== "function") {
      throw new TypeError("doof.on requires a non-empty event name and a function");
    }
    let handlers = listeners.get(name);
    if (!handlers) {
      handlers = new Set();
      listeners.set(name, handlers);
    }
    handlers.add(handler);
    return () => {
      handlers.delete(handler);
      if (handlers.size === 0) listeners.delete(name);
    };
  }

  function nativeCall(name, options = {}) {
    const id = `native-${Date.now()}-${++nativeSequence}`;
    return new Promise((resolve, reject) => {
      pendingNative.set(id, { resolve, reject });
      call(name, { id, options }).catch((error) => {
        pendingNative.delete(id);
        reject(error);
      });
    });
  }

  function openFile(options = {}) {
    return nativeCall("__webshell.native.openFile", options);
  }

  function saveFile(options = {}) {
    return nativeCall("__webshell.native.saveFile", options);
  }

  function requestNotificationPermission(options = {}) {
    return nativeCall("__webshell.native.requestNotificationPermission", options);
  }

  function postNotification(options = {}) {
    return nativeCall("__webshell.native.postNotification", options);
  }

  function readClipboardText() {
    return nativeCall("__webshell.native.readClipboardText", {});
  }

  function writeClipboardText(text) {
    if (typeof text !== "string") {
      return Promise.reject(new TypeError("writeClipboardText requires a string"));
    }
    return nativeCall("__webshell.native.writeClipboardText", { text });
  }

  function resolveResponse(json) {
    let response;
    try { response = JSON.parse(json); } catch (_) { return; }
    const entry = pending.get(response.id);
    if (!entry) return;
    pending.delete(response.id);
    if (response.ok) entry.resolve(response.value);
    else entry.reject(new Error(String(response.error || "Doof bridge call failed")));
  }

  function emitEvent(json) {
    let event;
    try { event = JSON.parse(json); } catch (_) { return; }
    if (event && event.name === "__webshell.native.result") {
      const payload = event.payload || {};
      const entry = pendingNative.get(payload.id);
      if (entry) {
        pendingNative.delete(payload.id);
        if (payload.ok) entry.resolve(payload.value);
        else entry.reject(new Error(String(payload.error || "Native web shell operation failed")));
      }
    }
    const handlers = listeners.get(event.name);
    if (!handlers) return;
    for (const handler of [...handlers]) {
      try { handler(event.payload); }
      catch (error) { console.error("Doof event handler failed", error); }
    }
  }

  const native = Object.freeze({
    openFile,
    saveFile,
    requestNotificationPermission,
    postNotification,
    readClipboardText,
    writeClipboardText
  });
  const api = Object.freeze({ call, on, native, __resolve: resolveResponse, __emit: emitEvent });
  Object.defineProperty(window, "doof", { value: api, configurable: false, writable: false });
})();)JS";
}

inline NSString* stringFromUtf8(const std::string& value) {
    return [[[NSString alloc] initWithBytes:value.data()
                                      length:value.size()
                                    encoding:NSUTF8StringEncoding] autorelease];
}

inline std::string utf8FromString(NSString* value) {
    if (value == nil) return "";
    const char* bytes = value.UTF8String;
    return bytes == nullptr ? "" : std::string(bytes);
}

inline NSString* javascriptStringLiteral(NSString* value) {
    if (value == nil) value = @"";
    NSData* data = [NSJSONSerialization dataWithJSONObject:@[value] options:0 error:nil];
    NSString* array = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    return [array substringWithRange:NSMakeRange(1, array.length - 2)];
}

inline NSString* jsonStringFromObject(id object, NSString** errorMessage) {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        if (errorMessage != nullptr) *errorMessage = @"Bridge request is not valid JSON";
        return nil;
    }
    NSError* error = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (data == nil) {
        if (errorMessage != nullptr) *errorMessage = error.localizedDescription;
        return nil;
    }
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

inline NSString* resolveHtmlPath(const std::string& rawPath) {
    NSString* path = [stringFromUtf8(rawPath) stringByExpandingTildeInPath];
    NSFileManager* files = NSFileManager.defaultManager;
    NSMutableArray<NSString*>* candidates = [NSMutableArray array];
    if (path.isAbsolutePath) {
        [candidates addObject:path];
    } else {
        [candidates addObject:[files.currentDirectoryPath stringByAppendingPathComponent:path]];
        NSString* resources = NSBundle.mainBundle.resourcePath;
        if (resources != nil) [candidates addObject:[resources stringByAppendingPathComponent:path]];
        NSString* bundlePath = [NSBundle.mainBundle pathForResource:path ofType:nil];
        if (bundlePath != nil) [candidates addObject:bundlePath];
    }
    for (NSString* candidate in candidates) {
        BOOL directory = NO;
        NSString* normalized = candidate.stringByStandardizingPath.stringByResolvingSymlinksInPath;
        if ([files fileExistsAtPath:normalized isDirectory:&directory] && !directory) return normalized;
    }
    return nil;
}

inline bool isPathInsideRoot(NSString* candidate, NSString* root) {
    NSString* path = candidate.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString* normalizedRoot = root.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    if ([path isEqualToString:normalizedRoot]) return true;
    NSString* prefix = [normalizedRoot stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

}  // namespace doof_webshell::detail

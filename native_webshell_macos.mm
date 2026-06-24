#include "native_webshell.hpp"
#include "native_webshell_shared.hpp"

#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>
#import <WebKit/WebKit.h>
#import <dispatch/dispatch.h>

#include <deque>
#include <mutex>
#include <utility>
#include <vector>

namespace doof_webshell {
namespace {

constexpr size_t kMaxPendingEvents = 256;

NSDictionary* parseDialogRequest(const std::string& requestJson, NSString** errorMessage) {
    NSData* data = [detail::stringFromUtf8(requestJson) dataUsingEncoding:NSUTF8StringEncoding];
    NSError* error = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![value isKindOfClass:NSDictionary.class]) {
        if (errorMessage != nullptr) *errorMessage = error.localizedDescription ?: @"Dialog request must be an object";
        return nil;
    }
    return (NSDictionary*)value;
}

NSString* dialogRequestId(NSDictionary* request) {
    id value = request[@"id"];
    return [value isKindOfClass:NSString.class] ? (NSString*)value : @"";
}

NSDictionary* dialogOptions(NSDictionary* request) {
    id value = request[@"options"];
    return [value isKindOfClass:NSDictionary.class] ? (NSDictionary*)value : @{};
}

BOOL boolOption(NSDictionary* options, NSString* key, BOOL fallback) {
    id value = options[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

NSString* stringOption(NSDictionary* options, NSString* key) {
    id value = options[key];
    return [value isKindOfClass:NSString.class] ? (NSString*)value : nil;
}

NSArray<NSString*>* stringArrayOption(NSDictionary* options, NSString* key) {
    id value = options[key];
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString*>* strings = [NSMutableArray array];
    for (id item in (NSArray*)value) {
        if ([item isKindOfClass:NSString.class] && [item length] > 0) [strings addObject:item];
    }
    return strings;
}

double doubleOption(NSDictionary* options, NSString* key, double fallback) {
    id value = options[key];
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

NSString* notificationAuthorizationStatusString(UNAuthorizationStatus status) {
    switch (status) {
        case UNAuthorizationStatusNotDetermined: return @"notDetermined";
        case UNAuthorizationStatusDenied: return @"denied";
        case UNAuthorizationStatusAuthorized: return @"authorized";
        case UNAuthorizationStatusProvisional: return @"provisional";
        default: return @"unknown";
    }
}

struct RuntimeState {
    std::mutex mutex;
    std::deque<std::string> pendingEvents;
    doof::callback<std::string(std::string)> onCall;
    doof::callback<int32_t()> drainEvents;
    NSWindow* window = nil;
    WKWebView* webView = nil;
    id delegate = nil;
    NSString* contentRoot = nil;
    NSString* menuConfigurationJson = nil;
    bool running = false;
    bool ready = false;
    bool presented = false;
    bool stopped = false;
    std::string terminalError;

    void evaluateEvent(const std::string& eventJson) {
        NSString* json = detail::stringFromUtf8(eventJson);
        NSString* script = [NSString stringWithFormat:@"window.doof&&window.doof.__emit(%@);",
                            detail::javascriptStringLiteral(json)];
        [webView evaluateJavaScript:script completionHandler:nil];
    }

    void evaluateNativeResult(NSString* requestId, BOOL ok, id value, NSString* error) {
        NSMutableDictionary* payload = [NSMutableDictionary dictionary];
        payload[@"id"] = requestId ?: @"";
        payload[@"ok"] = @(ok);
        if (ok) {
            payload[@"value"] = value ?: NSNull.null;
        } else {
            payload[@"error"] = error ?: @"Native web shell operation failed";
        }
        NSDictionary* event = @{
            @"name": @"__webshell.native.result",
            @"payload": payload,
        };
        NSString* conversionError = nil;
        NSString* json = detail::jsonStringFromObject(event, &conversionError);
        if (json != nil) evaluateEvent(detail::utf8FromString(json));
    }

    void emitMenuCommand(NSString* commandId) {
        NSDictionary* event = @{
            @"name": @"menuCommand",
            @"payload": @{ @"id": commandId ?: @"" },
        };
        NSString* conversionError = nil;
        NSString* json = detail::jsonStringFromObject(event, &conversionError);
        if (json != nil) evaluateEvent(detail::utf8FromString(json));
    }

    void emitNotificationResponse(UNNotificationResponse* response) {
        UNNotificationRequest* request = response.notification.request;
        NSMutableDictionary* payload = [NSMutableDictionary dictionary];
        payload[@"id"] = request.identifier ?: @"";
        payload[@"action"] = response.actionIdentifier ?: @"";
        NSDictionary* userInfo = request.content.userInfo;
        payload[@"userInfo"] = [NSJSONSerialization isValidJSONObject:userInfo] ? userInfo : @{};
        NSDictionary* event = @{
            @"name": @"notificationResponse",
            @"payload": payload,
        };
        NSString* conversionError = nil;
        NSString* json = detail::jsonStringFromObject(event, &conversionError);
        if (json != nil) evaluateEvent(detail::utf8FromString(json));
    }

    void becameReady() {
        std::vector<std::string> events;
        bool shouldPresent = false;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (stopped) return;
            ready = true;
            if (!presented) {
                presented = true;
                shouldPresent = true;
            }
            events.assign(pendingEvents.begin(), pendingEvents.end());
            pendingEvents.clear();
        }
        for (const auto& event : events) evaluateEvent(event);
        if (shouldPresent) {
            [window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
        }
    }

    void beganNavigation() {
        std::lock_guard<std::mutex> lock(mutex);
        ready = false;
    }

    void finish(const std::string& error = "") {
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (stopped) return;
            stopped = true;
            ready = false;
            terminalError = error;
        }
        [NSApp stop:nil];
        [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                            location:NSZeroPoint
                                       modifierFlags:0
                                           timestamp:0
                                        windowNumber:0
                                             context:nil
                                             subtype:0
                                               data1:0
                                               data2:0]
                 atStart:NO];
    }
};

}  // namespace
}  // namespace doof_webshell

@interface DoofWebShellMacDelegate : NSObject <
    WKScriptMessageHandler,
    WKNavigationDelegate,
    NSApplicationDelegate,
    NSWindowDelegate,
    UNUserNotificationCenterDelegate
> {
@public
    doof_webshell::RuntimeState* state_;
}
- (instancetype)initWithState:(doof_webshell::RuntimeState*)state;
@end

@implementation DoofWebShellMacDelegate
- (instancetype)initWithState:(doof_webshell::RuntimeState*)state {
    self = [super init];
    if (self != nil) state_ = state;
    return self;
}

- (void)userContentController:(WKUserContentController*)controller
      didReceiveScriptMessage:(WKScriptMessage*)message {
    (void)controller;
    NSString* conversionError = nil;
    NSString* request = doof_webshell::detail::jsonStringFromObject(message.body, &conversionError);
    std::string response;
    if (request == nil) {
        NSString* error = conversionError ?: @"Invalid bridge request";
        response = std::string("{\"id\":\"\",\"ok\":false,\"error\":")
            + doof_webshell::detail::utf8FromString(doof_webshell::detail::javascriptStringLiteral(error)) + "}";
    } else {
        response = state_->onCall.call(doof_webshell::detail::utf8FromString(request));
    }
    NSString* responseString = doof_webshell::detail::stringFromUtf8(response);
    NSString* script = [NSString stringWithFormat:@"window.doof&&window.doof.__resolve(%@);",
                        doof_webshell::detail::javascriptStringLiteral(responseString)];
    [state_->webView evaluateJavaScript:script completionHandler:nil];
}

- (void)webView:(WKWebView*)webView didStartProvisionalNavigation:(WKNavigation*)navigation {
    (void)webView;
    (void)navigation;
    state_->beganNavigation();
}

- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation {
    (void)webView;
    (void)navigation;
    state_->becameReady();
}

- (void)webView:(WKWebView*)webView didFailProvisionalNavigation:(WKNavigation*)navigation withError:(NSError*)error {
    (void)webView;
    (void)navigation;
    state_->finish("Failed to load web shell HTML: " + doof_webshell::detail::utf8FromString(error.localizedDescription));
}

- (void)webView:(WKWebView*)webView didFailNavigation:(WKNavigation*)navigation withError:(NSError*)error {
    (void)webView;
    (void)navigation;
    state_->finish("Web shell navigation failed: " + doof_webshell::detail::utf8FromString(error.localizedDescription));
}

- (void)webView:(WKWebView*)webView
    decidePolicyForNavigationAction:(WKNavigationAction*)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    (void)webView;
    if (!action.targetFrame.isMainFrame) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    NSURL* url = action.request.URL;
    if (url.isFileURL && doof_webshell::detail::isPathInsideRoot(url.path, state_->contentRoot)) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    NSString* scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"about"] && [url.absoluteString isEqualToString:@"about:blank"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        [NSWorkspace.sharedWorkspace openURL:url];
    }
    decisionHandler(WKNavigationActionPolicyCancel);
}

- (BOOL)windowShouldClose:(NSWindow*)sender {
    (void)sender;
    state_->finish();
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
    (void)sender;
    state_->finish();
    return NSTerminateCancel;
}

- (void)doofMenuItemSelected:(NSMenuItem*)sender {
    id value = sender.representedObject;
    if (![value isKindOfClass:NSString.class]) return;
    state_->emitMenuCommand((NSString*)value);
}

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
       willPresentNotification:(UNNotification*)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    (void)center;
    (void)notification;
    if (@available(macOS 11.0, *)) {
        completionHandler(UNNotificationPresentationOptionBanner |
                          UNNotificationPresentationOptionList |
                          UNNotificationPresentationOptionSound);
    } else {
        completionHandler(UNNotificationPresentationOptionAlert |
                          UNNotificationPresentationOptionSound);
    }
}

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
didReceiveNotificationResponse:(UNNotificationResponse*)response
         withCompletionHandler:(void (^)(void))completionHandler {
    (void)center;
    state_->emitNotificationResponse(response);
    completionHandler();
}
@end

namespace doof_webshell {

namespace {

NSArray* menuDefinitionsFromJson(NSString* menuJson, NSString** errorMessage) {
    if (menuJson == nil || menuJson.length == 0) return @[];
    NSData* data = [menuJson dataUsingEncoding:NSUTF8StringEncoding];
    NSError* error = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![root isKindOfClass:NSDictionary.class]) {
        if (errorMessage != nullptr) *errorMessage = error.localizedDescription ?: @"Menu configuration must be an object";
        return nil;
    }
    id menus = ((NSDictionary*)root)[@"menus"];
    if (![menus isKindOfClass:NSArray.class]) {
        if (errorMessage != nullptr) *errorMessage = @"Menu configuration must contain a menus array";
        return nil;
    }
    return (NSArray*)menus;
}

void addApplicationMenu(NSMenu* mainMenu, NSString* title) {
    NSMenuItem* applicationItem = [[[NSMenuItem alloc] initWithTitle:title
                                                              action:nil
                                                       keyEquivalent:@""] autorelease];
    [mainMenu addItem:applicationItem];

    NSMenu* applicationMenu = [[[NSMenu alloc] initWithTitle:title] autorelease];
    NSString* quitTitle = [@"Quit " stringByAppendingString:title];
    NSMenuItem* quitItem = [[[NSMenuItem alloc] initWithTitle:quitTitle
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"] autorelease];
    [applicationMenu addItem:quitItem];
    applicationItem.submenu = applicationMenu;
}

void installApplicationMenu(NSApplication* app, NSString* title, NSString* menuJson, id target) {
    NSMenu* mainMenu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
    addApplicationMenu(mainMenu, title);

    NSString* error = nil;
    NSArray* menus = menuDefinitionsFromJson(menuJson, &error);
    if (menus != nil) {
        for (id rawMenu in menus) {
            if (![rawMenu isKindOfClass:NSDictionary.class]) continue;
            NSDictionary* menuDefinition = (NSDictionary*)rawMenu;
            NSString* menuTitle = [menuDefinition[@"title"] isKindOfClass:NSString.class] ? menuDefinition[@"title"] : @"";
            if (menuTitle.length == 0) continue;

            NSMenuItem* menuItem = [[[NSMenuItem alloc] initWithTitle:menuTitle action:nil keyEquivalent:@""] autorelease];
            NSMenu* submenu = [[[NSMenu alloc] initWithTitle:menuTitle] autorelease];
            id items = menuDefinition[@"items"];
            if ([items isKindOfClass:NSArray.class]) {
                for (id rawItem in (NSArray*)items) {
                    if (![rawItem isKindOfClass:NSDictionary.class]) continue;
                    NSDictionary* itemDefinition = (NSDictionary*)rawItem;
                    NSString* commandId = [itemDefinition[@"id"] isKindOfClass:NSString.class] ? itemDefinition[@"id"] : @"";
                    NSString* itemTitle = [itemDefinition[@"title"] isKindOfClass:NSString.class] ? itemDefinition[@"title"] : @"";
                    if (commandId.length == 0 || itemTitle.length == 0) continue;
                    NSString* shortcut = [itemDefinition[@"shortcut"] isKindOfClass:NSString.class] ? itemDefinition[@"shortcut"] : @"";
                    NSMenuItem* command = [[[NSMenuItem alloc] initWithTitle:itemTitle
                                                                      action:@selector(doofMenuItemSelected:)
                                                               keyEquivalent:shortcut] autorelease];
                    command.target = target;
                    command.representedObject = commandId;
                    id enabled = itemDefinition[@"enabled"];
                    command.enabled = [enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : YES;
                    [submenu addItem:command];
                }
            }
            menuItem.submenu = submenu;
            [mainMenu addItem:menuItem];
        }
    }

    app.mainMenu = mainMenu;
}

}  // namespace

struct NativeWebShellApp::Impl {
    std::string htmlPath;
    std::string title;
    std::string menuConfigurationJson;
    int32_t width;
    int32_t height;
    std::shared_ptr<RuntimeState> state = std::make_shared<RuntimeState>();

    Impl(std::string path, std::string appTitle, int32_t appWidth, int32_t appHeight)
        : htmlPath(std::move(path)), title(std::move(appTitle)), width(appWidth), height(appHeight) {}
};

std::shared_ptr<NativeWebShellApp> NativeWebShellApp::create(
    const std::string& htmlPath,
    const std::string& title,
    int32_t width,
    int32_t height
) {
    return std::shared_ptr<NativeWebShellApp>(new NativeWebShellApp(htmlPath, title, width, height));
}

NativeWebShellApp::NativeWebShellApp(
    const std::string& htmlPath,
    const std::string& title,
    int32_t width,
    int32_t height
) : impl_(std::make_shared<Impl>(htmlPath, title, width, height)) {}

NativeWebShellApp::~NativeWebShellApp() = default;

doof::Result<void, std::string> NativeWebShellApp::postEvent(const std::string& eventJson) {
    auto state = impl_->state;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->stopped) return doof::Result<void, std::string>::failure("Web shell has stopped");
        if (!state->ready) {
            if (state->pendingEvents.size() >= kMaxPendingEvents) {
                return doof::Result<void, std::string>::failure("Web shell pending event queue is full");
            }
            state->pendingEvents.push_back(eventJson);
            return doof::Result<void, std::string>::success();
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ state->evaluateEvent(eventJson); });
    return doof::Result<void, std::string>::success();
}

doof::Result<void, std::string> NativeWebShellApp::beginOpenFileDialog(const std::string& requestJson) {
    if (![NSThread isMainThread]) {
        return doof::Result<void, std::string>::failure("Open file dialog must be started on the main thread");
    }
    auto state = impl_->state;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->stopped) return doof::Result<void, std::string>::failure("Web shell has stopped");
        if (state->window == nil) return doof::Result<void, std::string>::failure("Web shell window is not ready");
    }

    NSString* parseError = nil;
    NSDictionary* request = parseDialogRequest(requestJson, &parseError);
    if (request == nil) {
        return doof::Result<void, std::string>::failure(detail::utf8FromString(parseError ?: @"Invalid open file dialog request"));
    }

    NSString* requestId = dialogRequestId(request);
    NSDictionary* options = dialogOptions(request);
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = boolOption(options, @"multiple", NO);
    panel.canChooseDirectories = boolOption(options, @"directories", NO);
    panel.canChooseFiles = !panel.canChooseDirectories || boolOption(options, @"files", YES);
    NSString* title = stringOption(options, @"title");
    if (title != nil) panel.title = title;
    NSArray<NSString*>* types = stringArrayOption(options, @"types");
    if (types.count > 0) panel.allowedFileTypes = types;

    [panel beginSheetModalForWindow:state->window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) {
            state->evaluateNativeResult(requestId, YES, NSNull.null, nil);
            return;
        }
        if (panel.allowsMultipleSelection) {
            NSMutableArray<NSString*>* paths = [NSMutableArray array];
            for (NSURL* url in panel.URLs) {
                if (url.path != nil) [paths addObject:url.path];
            }
            state->evaluateNativeResult(requestId, YES, paths, nil);
            return;
        }
        state->evaluateNativeResult(requestId, YES, panel.URL.path ?: (id)NSNull.null, nil);
    }];
    return doof::Result<void, std::string>::success();
}

doof::Result<void, std::string> NativeWebShellApp::beginSaveFileDialog(const std::string& requestJson) {
    if (![NSThread isMainThread]) {
        return doof::Result<void, std::string>::failure("Save file dialog must be started on the main thread");
    }
    auto state = impl_->state;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->stopped) return doof::Result<void, std::string>::failure("Web shell has stopped");
        if (state->window == nil) return doof::Result<void, std::string>::failure("Web shell window is not ready");
    }

    NSString* parseError = nil;
    NSDictionary* request = parseDialogRequest(requestJson, &parseError);
    if (request == nil) {
        return doof::Result<void, std::string>::failure(detail::utf8FromString(parseError ?: @"Invalid save file dialog request"));
    }

    NSString* requestId = dialogRequestId(request);
    NSDictionary* options = dialogOptions(request);
    NSSavePanel* panel = [NSSavePanel savePanel];
    NSString* title = stringOption(options, @"title");
    if (title != nil) panel.title = title;
    NSString* suggestedName = stringOption(options, @"suggestedName");
    if (suggestedName != nil) panel.nameFieldStringValue = suggestedName;
    NSArray<NSString*>* types = stringArrayOption(options, @"types");
    if (types.count > 0) panel.allowedFileTypes = types;

    [panel beginSheetModalForWindow:state->window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) {
            state->evaluateNativeResult(requestId, YES, NSNull.null, nil);
            return;
        }
        state->evaluateNativeResult(requestId, YES, panel.URL.path ?: (id)NSNull.null, nil);
    }];
    return doof::Result<void, std::string>::success();
}

doof::Result<void, std::string> NativeWebShellApp::setMenuConfiguration(const std::string& menuJson) {
    NSString* error = nil;
    NSString* json = detail::stringFromUtf8(menuJson);
    if (menuDefinitionsFromJson(json, &error) == nil) {
        return doof::Result<void, std::string>::failure(detail::utf8FromString(error ?: @"Invalid menu configuration"));
    }
    impl_->menuConfigurationJson = menuJson;
    auto state = impl_->state;
    NSString* jsonCopy = [json copy];
    NSString* titleCopy = [detail::stringFromUtf8(impl_->title) copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(state->mutex);
        [state->menuConfigurationJson release];
        state->menuConfigurationJson = [jsonCopy copy];
        if (state->running && !state->stopped && state->delegate != nil) {
            installApplicationMenu(NSApplication.sharedApplication,
                                   titleCopy,
                                   state->menuConfigurationJson,
                                   state->delegate);
        }
        [jsonCopy release];
        [titleCopy release];
    });
    return doof::Result<void, std::string>::success();
}

doof::Result<void, std::string> NativeWebShellApp::beginRequestNotificationPermission(const std::string& requestJson) {
    NSString* parseError = nil;
    NSDictionary* request = parseDialogRequest(requestJson, &parseError);
    if (request == nil) {
        return doof::Result<void, std::string>::failure(
            detail::utf8FromString(parseError ?: @"Invalid notification permission request")
        );
    }

    NSString* requestId = [dialogRequestId(request) copy];
    NSDictionary* options = dialogOptions(request);
    UNAuthorizationOptions authorizationOptions = 0;
    if (boolOption(options, @"alert", YES)) authorizationOptions |= UNAuthorizationOptionAlert;
    if (boolOption(options, @"sound", YES)) authorizationOptions |= UNAuthorizationOptionSound;
    if (boolOption(options, @"badge", YES)) authorizationOptions |= UNAuthorizationOptionBadge;
    auto state = impl_->state;
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:authorizationOptions
                                                                      completionHandler:^(BOOL granted, NSError* error) {
        [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings* settings) {
            NSMutableDictionary* value = [NSMutableDictionary dictionary];
            value[@"granted"] = @(granted);
            value[@"status"] = notificationAuthorizationStatusString(settings.authorizationStatus);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error != nil) {
                    state->evaluateNativeResult(requestId, NO, nil, error.localizedDescription);
                } else {
                    state->evaluateNativeResult(requestId, YES, value, nil);
                }
                [requestId release];
            });
        }];
    }];
    return doof::Result<void, std::string>::success();
}

doof::Result<void, std::string> NativeWebShellApp::beginPostNotification(const std::string& requestJson) {
    NSString* parseError = nil;
    NSDictionary* request = parseDialogRequest(requestJson, &parseError);
    if (request == nil) {
        return doof::Result<void, std::string>::failure(
            detail::utf8FromString(parseError ?: @"Invalid post notification request")
        );
    }

    NSString* requestId = [dialogRequestId(request) copy];
    NSDictionary* options = [dialogOptions(request) retain];
    NSString* title = [stringOption(options, @"title") copy];
    if (title == nil || title.length == 0) {
        [requestId release];
        [title release];
        [options release];
        return doof::Result<void, std::string>::failure("Notification title must not be empty");
    }

    NSString* notificationId = [stringOption(options, @"id") ?: requestId copy];
    NSString* subtitle = [stringOption(options, @"subtitle") copy];
    NSString* body = [stringOption(options, @"body") copy];
    BOOL sound = boolOption(options, @"sound", YES);
    id rawBadge = options[@"badge"];
    NSNumber* badge = [rawBadge respondsToSelector:@selector(integerValue)] ? [rawBadge retain] : nil;
    id rawUserInfo = options[@"userInfo"];
    NSDictionary* userInfo = [rawUserInfo isKindOfClass:NSDictionary.class] &&
                                      [NSJSONSerialization isValidJSONObject:rawUserInfo]
                                  ? [rawUserInfo retain]
                                  : nil;
    double delaySeconds = doubleOption(options, @"delaySeconds", 0.0);
    [options release];
    auto state = impl_->state;
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings* settings) {
        if (settings.authorizationStatus == UNAuthorizationStatusDenied ||
            settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
            dispatch_async(dispatch_get_main_queue(), ^{
                state->evaluateNativeResult(requestId, NO, nil, @"Notification permission has not been granted");
                [requestId release];
                [notificationId release];
                [title release];
                [subtitle release];
                [body release];
                [badge release];
                [userInfo release];
            });
            return;
        }

        UNMutableNotificationContent* content = [[[UNMutableNotificationContent alloc] init] autorelease];
        content.title = title;
        if (subtitle != nil) content.subtitle = subtitle;
        if (body != nil) content.body = body;
        if (sound) content.sound = UNNotificationSound.defaultSound;
        if (badge != nil) content.badge = @([badge integerValue]);
        if (userInfo != nil) content.userInfo = userInfo;

        UNNotificationTrigger* trigger = nil;
        if (delaySeconds > 0.0) {
            trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:delaySeconds repeats:NO];
        }
        UNNotificationRequest* notificationRequest = [UNNotificationRequest requestWithIdentifier:notificationId
                                                                                          content:content
                                                                                          trigger:trigger];
        [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:notificationRequest
                                                             withCompletionHandler:^(NSError* error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error != nil) {
                    state->evaluateNativeResult(requestId, NO, nil, error.localizedDescription);
                } else {
                    state->evaluateNativeResult(requestId, YES, @{ @"id": notificationId }, nil);
                }
                [requestId release];
                [notificationId release];
                [title release];
                [subtitle release];
                [body release];
                [badge release];
                [userInfo release];
            });
        }];
    }];
    return doof::Result<void, std::string>::success();
}

doof::Result<void, std::string> NativeWebShellApp::beginReadClipboardText(const std::string& requestJson) {
    NSString* parseError = nil;
    NSDictionary* request = parseDialogRequest(requestJson, &parseError);
    if (request == nil) {
        return doof::Result<void, std::string>::failure(
            detail::utf8FromString(parseError ?: @"Invalid read clipboard request")
        );
    }

    NSString* requestId = dialogRequestId(request);
    NSString* text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] ?: @"";
    impl_->state->evaluateNativeResult(requestId, YES, text, nil);
    return doof::Result<void, std::string>::success();
}

doof::Result<void, std::string> NativeWebShellApp::beginWriteClipboardText(const std::string& requestJson) {
    NSString* parseError = nil;
    NSDictionary* request = parseDialogRequest(requestJson, &parseError);
    if (request == nil) {
        return doof::Result<void, std::string>::failure(
            detail::utf8FromString(parseError ?: @"Invalid write clipboard request")
        );
    }

    NSString* requestId = dialogRequestId(request);
    NSDictionary* options = dialogOptions(request);
    NSString* text = stringOption(options, @"text");
    if (text == nil) {
        return doof::Result<void, std::string>::failure("Clipboard text must be a string");
    }

    NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    BOOL ok = [pasteboard setString:text forType:NSPasteboardTypeString];
    if (!ok) {
        impl_->state->evaluateNativeResult(requestId, NO, nil, @"Could not write text to clipboard");
        return doof::Result<void, std::string>::success();
    }
    impl_->state->evaluateNativeResult(requestId, YES, @{ @"ok": @YES }, nil);
    return doof::Result<void, std::string>::success();
}

void NativeWebShellApp::requestWake() {
    auto state = impl_->state;
    dispatch_async(dispatch_get_main_queue(), ^{
        bool shouldDrain = false;
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            shouldDrain = state->running && !state->stopped;
        }
        if (shouldDrain) state->drainEvents.call();
    });
}

void NativeWebShellApp::stop() {
    auto state = impl_->state;
    dispatch_async(dispatch_get_main_queue(), ^{ state->finish(); });
}

doof::Result<void, std::string> NativeWebShellApp::run(
    doof::callback<std::string(std::string)> onCall,
    doof::callback<int32_t()> drainEvents
) {
    if (![NSThread isMainThread]) {
        return doof::Result<void, std::string>::failure("The macOS web shell must run on the main thread");
    }
    auto state = impl_->state;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->running || state->stopped) {
            return doof::Result<void, std::string>::failure("Web shell run() may only be called once");
        }
        state->running = true;
        state->onCall = std::move(onCall);
        state->drainEvents = std::move(drainEvents);
        [state->menuConfigurationJson release];
        state->menuConfigurationJson = [detail::stringFromUtf8(impl_->menuConfigurationJson) copy];
    }

    NSApplication* app = NSApplication.sharedApplication;
    NSString* title = detail::stringFromUtf8(impl_->title);

    NSString* htmlPath = detail::resolveHtmlPath(impl_->htmlPath);
    if (htmlPath == nil) {
        state->finish("Web shell HTML file was not found: " + impl_->htmlPath);
        return doof::Result<void, std::string>::failure(state->terminalError);
    }
    state->contentRoot = [[htmlPath stringByDeletingLastPathComponent] copy];

    WKWebViewConfiguration* configuration = [[[WKWebViewConfiguration alloc] init] autorelease];
    WKUserContentController* content = [[[WKUserContentController alloc] init] autorelease];
    configuration.userContentController = content;
    WKUserScript* script = [[[WKUserScript alloc] initWithSource:detail::bridgeScript()
                                                   injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                forMainFrameOnly:YES] autorelease];
    [content addUserScript:script];

    state->delegate = [[DoofWebShellMacDelegate alloc] initWithState:state.get()];
    UNUserNotificationCenter.currentNotificationCenter.delegate = state->delegate;
    [content addScriptMessageHandler:state->delegate name:@"doof"];
    NSRect frame = NSMakeRect(0, 0, impl_->width, impl_->height);
    state->webView = [[WKWebView alloc] initWithFrame:frame configuration:configuration];
    state->webView.navigationDelegate = state->delegate;
    state->window = [[NSWindow alloc] initWithContentRect:frame
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                          NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    state->window.title = title;
    state->window.contentView = state->webView;
    state->window.delegate = state->delegate;
    [state->window center];

    installApplicationMenu(app, title, state->menuConfigurationJson, state->delegate);
    app.delegate = state->delegate;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [state->webView loadFileURL:[NSURL fileURLWithPath:htmlPath]
          allowingReadAccessToURL:[NSURL fileURLWithPath:state->contentRoot isDirectory:YES]];
    state->drainEvents.call();
    [app run];

    [content removeScriptMessageHandlerForName:@"doof"];
    state->webView.navigationDelegate = nil;
    state->window.delegate = nil;
    app.delegate = nil;
    UNUserNotificationCenter.currentNotificationCenter.delegate = nil;
    app.mainMenu = nil;
    [state->window orderOut:nil];
    [state->webView release];
    [state->window close];
    [state->window release];
    [state->delegate release];
    [state->contentRoot release];
    [state->menuConfigurationJson release];
    state->webView = nil;
    state->window = nil;
    state->delegate = nil;
    state->contentRoot = nil;
    state->menuConfigurationJson = nil;

    state->drainEvents.call();
    std::lock_guard<std::mutex> lock(state->mutex);
    state->running = false;
    if (!state->terminalError.empty()) {
        return doof::Result<void, std::string>::failure(state->terminalError);
    }
    return doof::Result<void, std::string>::success();
}

}  // namespace doof_webshell

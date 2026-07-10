#include "native_webshell.hpp"
#include "native_webshell_shared.hpp"

#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <WebKit/WebKit.h>
#import <dispatch/dispatch.h>

#include <condition_variable>
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

BOOL validateMenuConfigurationJson(const std::string& menuJson, NSString** errorMessage) {
    NSData* data = [detail::stringFromUtf8(menuJson) dataUsingEncoding:NSUTF8StringEncoding];
    NSError* error = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![root isKindOfClass:NSDictionary.class]) {
        if (errorMessage != nullptr) *errorMessage = error.localizedDescription ?: @"Menu configuration must be an object";
        return NO;
    }
    id menus = ((NSDictionary*)root)[@"menus"];
    if (![menus isKindOfClass:NSArray.class]) {
        if (errorMessage != nullptr) *errorMessage = @"Menu configuration must contain a menus array";
        return NO;
    }
    return YES;
}

UIWindow* applicationWindow() {
    id delegate = UIApplication.sharedApplication.delegate;
    if ([delegate respondsToSelector:@selector(window)]) {
        UIWindow* window = [delegate window];
        if (window != nil) return window;
    }
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene* windowScene = (UIWindowScene*)scene;
        for (UIWindow* window in windowScene.windows) {
            if (window.isKeyWindow) return window;
        }
        if (windowScene.windows.firstObject != nil) return windowScene.windows.firstObject;
    }
    return nil;
}

struct RuntimeState {
    std::mutex mutex;
    std::condition_variable completion;
    std::deque<std::string> pendingEvents;
    doof::callback<std::string(std::string)> onCall;
    doof::callback<int32_t()> drainEvents;
    WKWebView* webView = nil;
    id delegate = nil;
    NSString* contentRoot = nil;
    NSString* activeDocumentPickerRequestId = nil;
    bool activeDocumentPickerAllowsMultiple = false;
    bool running = false;
    bool ready = false;
    bool presented = false;
    bool stopped = false;
    std::string terminalError;

    void evaluateEvent(const std::string& eventJson) {
        NSString* script = [NSString stringWithFormat:@"window.doof&&window.doof.__emit(%@);",
                            detail::javascriptStringLiteral(detail::stringFromUtf8(eventJson))];
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
        if (shouldPresent) webView.hidden = NO;
    }

    void beganNavigation() {
        std::lock_guard<std::mutex> lock(mutex);
        ready = false;
    }

    void finish(const std::string& error = "") {
        WKWebView* view = nil;
        id handler = nil;
        NSString* root = nil;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (stopped) return;
            stopped = true;
            ready = false;
            terminalError = error;
            view = webView;
            handler = delegate;
            root = contentRoot;
            webView = nil;
            delegate = nil;
            contentRoot = nil;
            [activeDocumentPickerRequestId release];
            activeDocumentPickerRequestId = nil;
        }
        if (view != nil) {
            [view.configuration.userContentController removeScriptMessageHandlerForName:@"doof"];
            view.navigationDelegate = nil;
            [view removeFromSuperview];
            [view release];
        }
        if (UNUserNotificationCenter.currentNotificationCenter.delegate == handler) {
            UNUserNotificationCenter.currentNotificationCenter.delegate = nil;
        }
        [handler release];
        [root release];
        completion.notify_all();
    }
};

}  // namespace
}  // namespace doof_webshell

@interface DoofWebShellIOSDelegate : NSObject <
    WKScriptMessageHandler,
    WKNavigationDelegate,
    UIDocumentPickerDelegate,
    UNUserNotificationCenterDelegate
> {
@public
    doof_webshell::RuntimeState* state_;
}
- (instancetype)initWithState:(doof_webshell::RuntimeState*)state;
@end

@implementation DoofWebShellIOSDelegate
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
    NSString* script = [NSString stringWithFormat:@"window.doof&&window.doof.__resolve(%@);",
                        doof_webshell::detail::javascriptStringLiteral(doof_webshell::detail::stringFromUtf8(response))];
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
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
    decisionHandler(WKNavigationActionPolicyCancel);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {
    (void)controller;
    NSString* requestId = state_->activeDocumentPickerRequestId ?: @"";
    state_->evaluateNativeResult(requestId, YES, NSNull.null, nil);
    [state_->activeDocumentPickerRequestId release];
    state_->activeDocumentPickerRequestId = nil;
    state_->activeDocumentPickerAllowsMultiple = false;
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    (void)controller;
    NSString* requestId = state_->activeDocumentPickerRequestId ?: @"";
    if (state_->activeDocumentPickerAllowsMultiple) {
        NSMutableArray<NSString*>* paths = [NSMutableArray array];
        for (NSURL* url in urls) {
            if (url.path != nil) [paths addObject:url.path];
        }
        state_->evaluateNativeResult(requestId, YES, paths, nil);
    } else {
        NSURL* url = urls.firstObject;
        state_->evaluateNativeResult(requestId, YES, url.path ?: (id)NSNull.null, nil);
    }
    [state_->activeDocumentPickerRequestId release];
    state_->activeDocumentPickerRequestId = nil;
    state_->activeDocumentPickerAllowsMultiple = false;
}

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
       willPresentNotification:(UNNotification*)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    (void)center;
    (void)notification;
    if (@available(iOS 14.0, *)) {
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
        if (state->stopped) return doof::Failure<std::string>{"Web shell has stopped"};
        if (!state->ready) {
            if (state->pendingEvents.size() >= kMaxPendingEvents) {
                return doof::Failure<std::string>{"Web shell pending event queue is full"};
            }
            state->pendingEvents.push_back(eventJson);
            return doof::Success<void>{};
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ state->evaluateEvent(eventJson); });
    return doof::Success<void>{};
}

doof::Result<void, std::string> NativeWebShellApp::beginOpenFileDialog(const std::string& requestJson) {
    __block std::string startError;
    auto state = impl_->state;
    void (^startDialog)(void) = ^{
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->stopped) {
                startError = "Web shell has stopped";
                return;
            }
            if (state->webView == nil || state->delegate == nil) {
                startError = "Web shell view is not ready";
                return;
            }
            if (state->activeDocumentPickerRequestId != nil) {
                startError = "A document picker is already active";
                return;
            }
        }

        NSString* parseError = nil;
        NSDictionary* request = parseDialogRequest(requestJson, &parseError);
        if (request == nil) {
            startError = detail::utf8FromString(parseError ?: @"Invalid open file dialog request");
            return;
        }

        UIWindow* window = applicationWindow();
        UIViewController* presenter = window.rootViewController;
        if (presenter == nil) {
            startError = "UIApplication root view is not ready";
            return;
        }
        while (presenter.presentedViewController != nil) presenter = presenter.presentedViewController;

        NSDictionary* options = dialogOptions(request);
        NSArray<NSString*>* types = stringArrayOption(options, @"types");
        if (types.count == 0) types = @[ @"public.item" ];
        UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:types
                                                                                                        inMode:UIDocumentPickerModeOpen];
        picker.delegate = (id<UIDocumentPickerDelegate>)state->delegate;
        if ([picker respondsToSelector:@selector(setAllowsMultipleSelection:)]) {
            picker.allowsMultipleSelection = boolOption(options, @"multiple", NO);
        }
        NSString* title = stringOption(options, @"title");
        if (title != nil) picker.title = title;

        state->activeDocumentPickerRequestId = [dialogRequestId(request) copy];
        state->activeDocumentPickerAllowsMultiple = boolOption(options, @"multiple", NO);
        [presenter presentViewController:picker animated:YES completion:nil];
        [picker release];
    };

    if ([NSThread isMainThread]) startDialog();
    else dispatch_sync(dispatch_get_main_queue(), startDialog);

    if (!startError.empty()) return doof::Failure<std::string>{startError};
    return doof::Success<void>{};
}

doof::Result<void, std::string> NativeWebShellApp::beginSaveFileDialog(const std::string& requestJson) {
    (void)requestJson;
    return doof::Failure<std::string>{"Save file dialogs are not yet supported by the iOS web shell"};
}

doof::Result<void, std::string> NativeWebShellApp::setMenuConfiguration(const std::string& menuJson) {
    NSString* error = nil;
    if (!validateMenuConfigurationJson(menuJson, &error)) {
        return doof::Failure<std::string>{detail::utf8FromString(error ?: @"Invalid menu configuration")};
    }
    impl_->menuConfigurationJson = menuJson;
    return doof::Success<void>{};
}

doof::Result<void, std::string> NativeWebShellApp::beginRequestNotificationPermission(const std::string& requestJson) {
    NSString* parseError = nil;
    NSDictionary* request = parseDialogRequest(requestJson, &parseError);
    if (request == nil) {
        return doof::Failure<std::string>{detail::utf8FromString(parseError ?: @"Invalid notification permission request")};
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
    return doof::Success<void>{};
}

doof::Result<void, std::string> NativeWebShellApp::beginPostNotification(const std::string& requestJson) {
    NSString* parseError = nil;
    NSDictionary* request = parseDialogRequest(requestJson, &parseError);
    if (request == nil) {
        return doof::Failure<std::string>{detail::utf8FromString(parseError ?: @"Invalid post notification request")};
    }

    NSString* requestId = [dialogRequestId(request) copy];
    NSDictionary* options = [dialogOptions(request) retain];
    NSString* title = [stringOption(options, @"title") copy];
    if (title == nil || title.length == 0) {
        [requestId release];
        [title release];
        [options release];
        return doof::Failure<std::string>{"Notification title must not be empty"};
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
    return doof::Success<void>{};
}

doof::Result<void, std::string> NativeWebShellApp::beginReadClipboardText(const std::string& requestJson) {
    NSString* parseError = nil;
    NSDictionary* request = parseDialogRequest(requestJson, &parseError);
    if (request == nil) {
        return doof::Failure<std::string>{detail::utf8FromString(parseError ?: @"Invalid read clipboard request")};
    }

    __block NSString* requestId = nil;
    __block NSString* text = nil;
    void (^readClipboard)(void) = ^{
        requestId = [dialogRequestId(request) copy];
        text = [UIPasteboard.generalPasteboard.string copy] ?: [@"" copy];
    };
    if ([NSThread isMainThread]) readClipboard();
    else dispatch_sync(dispatch_get_main_queue(), readClipboard);

    impl_->state->evaluateNativeResult(requestId, YES, text, nil);
    [requestId release];
    [text release];
    return doof::Success<void>{};
}

doof::Result<void, std::string> NativeWebShellApp::beginWriteClipboardText(const std::string& requestJson) {
    NSString* parseError = nil;
    NSDictionary* request = parseDialogRequest(requestJson, &parseError);
    if (request == nil) {
        return doof::Failure<std::string>{detail::utf8FromString(parseError ?: @"Invalid write clipboard request")};
    }

    NSDictionary* options = dialogOptions(request);
    NSString* text = stringOption(options, @"text");
    if (text == nil) {
        return doof::Failure<std::string>{"Clipboard text must be a string"};
    }

    __block NSString* requestId = nil;
    NSString* textCopy = [text copy];
    void (^writeClipboard)(void) = ^{
        requestId = [dialogRequestId(request) copy];
        UIPasteboard.generalPasteboard.string = textCopy;
    };
    if ([NSThread isMainThread]) writeClipboard();
    else dispatch_sync(dispatch_get_main_queue(), writeClipboard);

    impl_->state->evaluateNativeResult(requestId, YES, @{ @"ok": @YES }, nil);
    [requestId release];
    [textCopy release];
    return doof::Success<void>{};
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
    auto state = impl_->state;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->running || state->stopped) {
            return doof::Failure<std::string>{"Web shell run() may only be called once"};
        }
        state->running = true;
        state->onCall = std::move(onCall);
        state->drainEvents = std::move(drainEvents);
    }

    __block NSString* installError = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSString* htmlPath = detail::resolveHtmlPath(impl_->htmlPath);
        if (htmlPath == nil) {
            installError = [[NSString alloc] initWithFormat:@"Web shell HTML file was not found: %@",
                            detail::stringFromUtf8(impl_->htmlPath)];
            return;
        }
        UIWindow* window = applicationWindow();
        UIViewController* root = window.rootViewController;
        if (window == nil || root == nil) {
            installError = [@"UIApplication root view is not ready" copy];
            return;
        }

        state->contentRoot = [[htmlPath stringByDeletingLastPathComponent] copy];
        WKWebViewConfiguration* configuration = [[[WKWebViewConfiguration alloc] init] autorelease];
        WKUserContentController* content = [[[WKUserContentController alloc] init] autorelease];
        configuration.userContentController = content;
        WKUserScript* script = [[[WKUserScript alloc] initWithSource:detail::bridgeScript()
                                                       injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                    forMainFrameOnly:YES] autorelease];
        [content addUserScript:script];
        state->delegate = [[DoofWebShellIOSDelegate alloc] initWithState:state.get()];
        UNUserNotificationCenter.currentNotificationCenter.delegate = state->delegate;
        [content addScriptMessageHandler:state->delegate name:@"doof"];
        state->webView = [[WKWebView alloc] initWithFrame:root.view.bounds configuration:configuration];
        state->webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        state->webView.navigationDelegate = state->delegate;
        state->webView.hidden = YES;
        [root.view addSubview:state->webView];
        [state->webView loadFileURL:[NSURL fileURLWithPath:htmlPath]
              allowingReadAccessToURL:[NSURL fileURLWithPath:state->contentRoot isDirectory:YES]];
    });

    if (installError != nil) {
        std::string error = detail::utf8FromString(installError);
        [installError release];
        dispatch_sync(dispatch_get_main_queue(), ^{ state->finish(error); });
        return doof::Failure<std::string>{error};
    }

    state->drainEvents.call();
    std::unique_lock<std::mutex> lock(state->mutex);
    state->completion.wait(lock, [&state] { return state->stopped; });
    state->running = false;
    std::string error = state->terminalError;
    lock.unlock();
    state->drainEvents.call();
    if (!error.empty()) return doof::Failure<std::string>{error};
    return doof::Success<void>{};
}

}  // namespace doof_webshell

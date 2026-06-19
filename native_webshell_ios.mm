#include "native_webshell.hpp"
#include "native_webshell_shared.hpp"

#import <UIKit/UIKit.h>
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
        }
        if (view != nil) {
            [view.configuration.userContentController removeScriptMessageHandlerForName:@"doof"];
            view.navigationDelegate = nil;
            [view removeFromSuperview];
            [view release];
        }
        [handler release];
        [root release];
        completion.notify_all();
    }
};

}  // namespace
}  // namespace doof_webshell

@interface DoofWebShellIOSDelegate : NSObject <WKScriptMessageHandler, WKNavigationDelegate> {
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
@end

namespace doof_webshell {

struct NativeWebShellApp::Impl {
    std::string htmlPath;
    std::string title;
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
            return doof::Result<void, std::string>::failure("Web shell run() may only be called once");
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
        return doof::Result<void, std::string>::failure(error);
    }

    state->drainEvents.call();
    std::unique_lock<std::mutex> lock(state->mutex);
    state->completion.wait(lock, [&state] { return state->stopped; });
    state->running = false;
    std::string error = state->terminalError;
    lock.unlock();
    state->drainEvents.call();
    if (!error.empty()) return doof::Result<void, std::string>::failure(error);
    return doof::Result<void, std::string>::success();
}

}  // namespace doof_webshell

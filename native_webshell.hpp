#pragma once

#include "doof_runtime.hpp"

#include <cstdint>
#include <memory>
#include <string>

namespace doof_webshell {

class NativeWebShellApp {
public:
    static std::shared_ptr<NativeWebShellApp> create(
        const std::string& htmlPath,
        const std::string& title,
        int32_t width,
        int32_t height
    );

    ~NativeWebShellApp();

    doof::Result<void, std::string> postEvent(const std::string& eventJson);
    doof::Result<void, std::string> beginOpenFileDialog(const std::string& requestJson);
    doof::Result<void, std::string> beginSaveFileDialog(const std::string& requestJson);
    doof::Result<void, std::string> setMenuConfiguration(const std::string& menuJson);
    doof::Result<void, std::string> beginRequestNotificationPermission(const std::string& requestJson);
    doof::Result<void, std::string> beginPostNotification(const std::string& requestJson);
    doof::Result<void, std::string> beginReadClipboardText(const std::string& requestJson);
    doof::Result<void, std::string> beginWriteClipboardText(const std::string& requestJson);
    void requestWake();
    void stop();
    doof::Result<void, std::string> run(
        doof::callback<std::string(std::string)> onCall,
        doof::callback<int32_t()> drainEvents
    );

private:
    NativeWebShellApp(
        const std::string& htmlPath,
        const std::string& title,
        int32_t width,
        int32_t height
    );

    struct Impl;
    std::shared_ptr<Impl> impl_;
};

}  // namespace doof_webshell

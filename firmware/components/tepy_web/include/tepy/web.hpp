#pragma once
#include "esp_http_server.h"
#include "tepy/ble.hpp"
#include "tepy/config.hpp"
#include "tepy/network.hpp"
#include "tepy/ota.hpp"
#include <functional>

namespace tepy {
struct WebServices {
    ConfigStore &config;
    BleKeyboard &ble;
    Network &network;
    OtaUpdater &ota;
    std::function<std::string()> status;
    std::function<bool()> begin_maintenance;
    std::function<void()> end_maintenance;
    std::function<void()> reboot;
};
class WebServer {
  public:
    explicit WebServer(WebServices services) : services_(std::move(services)) {}
    esp_err_t start();

  private:
    static esp_err_t route(httpd_req_t *request);
    esp_err_t handle(httpd_req_t *request);
    bool authorized(httpd_req_t *request) const;
    WebServices services_;
    httpd_handle_t server_{};
};
} // namespace tepy

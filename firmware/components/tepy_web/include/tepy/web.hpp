#pragma once
#include "esp_http_server.h"
#include "tepy/management.hpp"
#include "tepy/ota.hpp"
#include <functional>

namespace tepy {
class WebServer {
  public:
    WebServer(Management &management, OtaUpdater &ota) : management_(management), ota_(ota) {}
    esp_err_t start();

  private:
    static esp_err_t route(httpd_req_t *request);
    esp_err_t handle(httpd_req_t *request);
    bool authorized(httpd_req_t *request) const;
    Management &management_;
    OtaUpdater &ota_;
    httpd_handle_t server_{};
};
} // namespace tepy

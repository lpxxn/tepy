#include "tepy/web.hpp"
#include "esp_timer.h"
#include "tepy/json.hpp"
#include <array>
#include <cstring>

extern const uint8_t page_start[] asm("_binary_index_html_start");
extern const uint8_t page_end[] asm("_binary_index_html_end");
namespace tepy {
namespace {
esp_err_t respond(httpd_req_t *req, const std::string &data, const char *status = "200 OK") {
    httpd_resp_set_status(req, status);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_hdr(req, "X-Content-Type-Options", "nosniff");
    return httpd_resp_send(req, data.data(), data.size());
}
esp_err_t error(httpd_req_t *req, std::string_view code, const char *status = "400 Bad Request") {
    auto root = object();
    cJSON_AddStringToObject(root.get(), "error", std::string(code).c_str());
    return respond(req, stringify(root.get()), status);
}
bool read_body(httpd_req_t *req, std::string &data, size_t limit) {
    if (req->content_len > limit)
        return false;
    data.resize(req->content_len);
    size_t offset = 0;
    const auto deadline = esp_timer_get_time() + 15000000;
    while (offset < data.size()) {
        int count = httpd_req_recv(req, data.data() + offset, data.size() - offset);
        if (count == HTTPD_SOCK_ERR_TIMEOUT && esp_timer_get_time() < deadline)
            continue;
        if (count <= 0)
            return false;
        offset += count;
    }
    return true;
}
std::string header(httpd_req_t *req, const char *key, size_t limit = 512) {
    const auto length = httpd_req_get_hdr_value_len(req, key);
    if (!length || length > limit)
        return {};
    std::string value(length + 1, '\0');
    if (httpd_req_get_hdr_value_str(req, key, value.data(), value.size()) != ESP_OK)
        return {};
    value.resize(length);
    return value;
}
struct Wipe {
    std::string &value;
    ~Wipe() { secure_clear(value.data(), value.size()); }
};
struct Maintenance {
    Management &owner;
    ~Maintenance() { owner.end_maintenance(); }
};
} // namespace
esp_err_t WebServer::start() {
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.stack_size = 12288;
    config.max_uri_handlers = 5;
    config.lru_purge_enable = true;
    config.recv_wait_timeout = 5;
    config.send_wait_timeout = 5;
    config.uri_match_fn = httpd_uri_match_wildcard;
    auto err = httpd_start(&server_, &config);
    if (err != ESP_OK)
        return err;
    for (auto method : {HTTP_GET, HTTP_POST, HTTP_PATCH}) {
        httpd_uri_t uri{};
        uri.uri = "/*";
        uri.method = method;
        uri.handler = route;
        uri.user_ctx = this;
        err = httpd_register_uri_handler(server_, &uri);
        if (err != ESP_OK)
            return err;
    }
    return ESP_OK;
}
bool WebServer::authorized(httpd_req_t *req) const {
    auto authorization = header(req, "Authorization", 80);
    Wipe wipe{authorization};
    if (!authorization.starts_with("Bearer ") ||
        !management_.authenticate(std::string_view(authorization).substr(7)))
        return false;
    const auto origin = header(req, "Origin");
    return origin.empty() || origin == "http://" + header(req, "Host");
}
esp_err_t WebServer::route(httpd_req_t *req) {
    return static_cast<WebServer *>(req->user_ctx)->handle(req);
}
esp_err_t WebServer::handle(httpd_req_t *req) {
    const std::string_view path(req->uri);
    if (path == "/" && req->method == HTTP_GET) {
        httpd_resp_set_type(req, "text/html; charset=utf-8");
        httpd_resp_set_hdr(req, "X-Frame-Options", "DENY");
        httpd_resp_set_hdr(
            req, "Content-Security-Policy",
            "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
            "frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
        httpd_resp_set_hdr(req, "Cache-Control", "no-store");
        return httpd_resp_send(req, reinterpret_cast<const char *>(page_start),
                               page_end - page_start);
    }
    if (!path.starts_with("/api/v1/"))
        return error(req, "not_found", "404 Not Found");
    if (!authorized(req))
        return error(req, "unauthorized", "401 Unauthorized");
    const auto dispatch = [&](std::string_view method, std::string_view params = "{}") {
        auto result = management_.dispatch(method, params);
        auto parsed = parse_json(result);
        const auto issue = text(field(parsed.get(), "error"));
        const char *status = issue.empty()                                  ? "200 OK"
                             : issue == "busy" || issue == "already_bonded" ? "409 Conflict"
                                                                            : "400 Bad Request";
        return respond(req, result, status);
    };
    if (req->method == HTTP_GET) {
        if (path == "/api/v1/status")
            return dispatch("status.get");
        if (path == "/api/v1/config")
            return dispatch("config.get");
        if (path == "/api/v1/wifi/scan")
            return dispatch("wifi.scan");
    }
    if (req->method == HTTP_PATCH && path == "/api/v1/config") {
        std::string body;
        Wipe wipe{body};
        if (!read_body(req, body, 16384))
            return error(req, "invalid_body");
        return dispatch("config.patch", body);
    }
    if (req->method != HTTP_POST)
        return error(req, "not_found", "404 Not Found");
    if (path == "/api/v1/ota") {
        if (header(req, "Content-Type") != "application/octet-stream")
            return error(req, "invalid_content_type");
        if (!management_.begin_maintenance())
            return error(req, "busy", "409 Conflict");
        Maintenance guard{management_};
        auto deadline = esp_timer_get_time() + 120000000;
        auto issue = ota_.upload(req->content_len, [&](char *buffer, size_t size) {
            while (esp_timer_get_time() < deadline) {
                auto count = httpd_req_recv(req, buffer, size);
                if (count != HTTPD_SOCK_ERR_TIMEOUT)
                    return count;
            }
            return -1;
        });
        if (!issue.empty())
            return error(req, issue);
        auto result = respond(req, "{\"ok\":true,\"rebooting\":true}");
        management_.reboot();
        return result;
    }
    if (path == "/api/v1/ble/passkey") {
        std::string body;
        Wipe wipe{body};
        if (!read_body(req, body, 128))
            return error(req, "invalid_body");
        return dispatch("ble.passkey", body);
    }
    if (req->content_len)
        return error(req, "unexpected_body");
    if (path == "/api/v1/ble/pair" || path == "/api/v1/ble/clear" || path == "/api/v1/reboot") {
        return dispatch(path == "/api/v1/ble/pair"    ? "ble.pair"
                        : path == "/api/v1/ble/clear" ? "ble.clear"
                                                      : "reboot");
    }
    return error(req, "not_found", "404 Not Found");
}
} // namespace tepy

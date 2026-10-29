#pragma once
#include "esp_err.h"
#include <mutex>
#include <string>
#include <string_view>

namespace tepy {
std::string random_hex(size_t bytes);
struct Config {
    std::string ssid, wifi_password, mqtt_uri, mqtt_username, mqtt_password, mqtt_ca;
    std::string ntp_server{"pool.ntp.org"};
    std::string admin_password, ap_password;
    unsigned key_delay_ms{20};
};
class ConfigStore {
  public:
    esp_err_t init(bool &created);
    Config snapshot() const;
    std::string public_json() const;
    std::string_view patch(std::string_view input);
    bool authenticate(std::string_view password) const;

  private:
    esp_err_t persist(const Config &config);
    mutable std::mutex mutex_;
    Config config_;
};
} // namespace tepy

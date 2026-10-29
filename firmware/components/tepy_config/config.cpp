#include "tepy/config.hpp"
#include "bootloader_random.h"
#include "esp_random.h"
#include "nvs.h"
#include "tepy/json.hpp"
#include <array>
#include <cmath>

namespace tepy {
std::string random_hex(size_t bytes) {
    std::string result(bytes * 2, '0');
    for (size_t i = 0; i < bytes; ++i) {
        uint8_t value;
        esp_fill_random(&value, 1);
        result[2 * i] = "0123456789abcdef"[value >> 4];
        result[2 * i + 1] = "0123456789abcdef"[value & 15];
    }
    return result;
}
namespace {
struct Nvs {
    nvs_handle_t handle{};
    ~Nvs() {
        if (handle)
            nvs_close(handle);
    }
};
bool assign(const cJSON *obj, const char *key, std::string &target, size_t max) {
    auto *item = field(obj, key);
    if (!item)
        return true;
    if (!cJSON_IsString(item) || text(item).size() > max)
        return false;
    target = text(item);
    return true;
}
std::string_view update(const cJSON *root, Config &cfg, bool storage) {
    auto *version = field(root, "v");
    if (!cJSON_IsNumber(version) || version->valuedouble != 1)
        return "unsupported_config_version";
    if (!fields_only(
            root, storage
                      ? std::initializer_list<std::string_view>{"v", "wifi", "mqtt", "ntp_server",
                                                                "key_delay_ms", "admin_password",
                                                                "ap_password"}
                      : std::initializer_list<std::string_view>{"v", "wifi", "mqtt", "ntp_server",
                                                                "key_delay_ms", "admin_password"}))
        return "invalid_config";
    if (auto *wifi = field(root, "wifi")) {
        if (!fields_only(wifi, {"ssid", "password"}) || !assign(wifi, "ssid", cfg.ssid, 32) ||
            !assign(wifi, "password", cfg.wifi_password, 63))
            return "invalid_wifi";
    }
    if (!cfg.wifi_password.empty() && cfg.wifi_password.size() < 8)
        return "invalid_wifi_password";
    if (auto *mqtt = field(root, "mqtt")) {
        if (!fields_only(mqtt, {"uri", "username", "password", "ca"}) ||
            !assign(mqtt, "uri", cfg.mqtt_uri, 256) ||
            !assign(mqtt, "username", cfg.mqtt_username, 128) ||
            !assign(mqtt, "password", cfg.mqtt_password, 256) ||
            !assign(mqtt, "ca", cfg.mqtt_ca, 8192))
            return "invalid_mqtt";
    }
    if (!cfg.mqtt_uri.empty()) {
        if (!cfg.mqtt_uri.starts_with("mqtt://") && !cfg.mqtt_uri.starts_with("mqtts://"))
            return "invalid_mqtt_uri";
        auto authority = std::string_view(cfg.mqtt_uri).substr(cfg.mqtt_uri.find("://") + 3);
        if (authority.empty() || authority.find('@') != authority.npos ||
            authority.find_first_of(" \t\r\n/?#") != authority.npos)
            return "invalid_mqtt_uri";
    }
    if (!cfg.mqtt_ca.empty() &&
        (cfg.mqtt_ca.find("-----BEGIN CERTIFICATE-----") == std::string::npos ||
         cfg.mqtt_ca.find("PRIVATE KEY") != std::string::npos))
        return "invalid_ca";
    if (!assign(root, "ntp_server", cfg.ntp_server, 128) || cfg.ntp_server.empty() ||
        cfg.ntp_server.find_first_of(" \r\n\t") != std::string::npos)
        return "invalid_ntp_server";
    if (auto *delay = field(root, "key_delay_ms")) {
        if (!cJSON_IsNumber(delay) || !std::isfinite(delay->valuedouble) ||
            std::floor(delay->valuedouble) != delay->valuedouble || delay->valuedouble < 5 ||
            delay->valuedouble > 200)
            return "invalid_key_delay";
        cfg.key_delay_ms = static_cast<unsigned>(delay->valuedouble);
    }
    if (!assign(root, "admin_password", cfg.admin_password, 64) || cfg.admin_password.size() < 16)
        return "invalid_admin_password";
    for (unsigned char c : cfg.admin_password)
        if (c < 33 || c > 126)
            return "invalid_admin_password";
    if (storage &&
        (!assign(root, "ap_password", cfg.ap_password, 63) || cfg.ap_password.size() < 8))
        return "invalid_ap_password";
    return {};
}
std::string encode(const Config &cfg, bool redact) {
    auto root = object();
    cJSON_AddNumberToObject(root.get(), "v", 1);
    auto *wifi = cJSON_AddObjectToObject(root.get(), "wifi");
    cJSON_AddStringToObject(wifi, "ssid", cfg.ssid.c_str());
    auto *mqtt = cJSON_AddObjectToObject(root.get(), "mqtt");
    cJSON_AddStringToObject(mqtt, "uri", cfg.mqtt_uri.c_str());
    cJSON_AddStringToObject(mqtt, "username", cfg.mqtt_username.c_str());
    cJSON_AddStringToObject(mqtt, "ca", cfg.mqtt_ca.c_str());
    cJSON_AddStringToObject(root.get(), "ntp_server", cfg.ntp_server.c_str());
    cJSON_AddNumberToObject(root.get(), "key_delay_ms", cfg.key_delay_ms);
    if (redact) {
        cJSON_AddBoolToObject(wifi, "password_set", !cfg.wifi_password.empty());
        cJSON_AddBoolToObject(mqtt, "password_set", !cfg.mqtt_password.empty());
        cJSON_AddBoolToObject(root.get(), "admin_password_set", !cfg.admin_password.empty());
    } else {
        cJSON_AddStringToObject(wifi, "password", cfg.wifi_password.c_str());
        cJSON_AddStringToObject(mqtt, "password", cfg.mqtt_password.c_str());
        cJSON_AddStringToObject(root.get(), "admin_password", cfg.admin_password.c_str());
        cJSON_AddStringToObject(root.get(), "ap_password", cfg.ap_password.c_str());
    }
    return stringify(root.get());
}
} // namespace
esp_err_t ConfigStore::init(bool &created) {
    created = false;
    Nvs nvs;
    auto error = nvs_open("tepy", NVS_READWRITE, &nvs.handle);
    if (error != ESP_OK)
        return error;
    size_t size = 0;
    error = nvs_get_str(nvs.handle, "config", nullptr, &size);
    if (error == ESP_ERR_NVS_NOT_FOUND) {
        // Config initialization runs before Wi-Fi/BLE/ADC initialization.
        bootloader_random_enable();
        config_.admin_password = random_hex(16);
        config_.ap_password = random_hex(8);
        bootloader_random_disable();
        error = persist(config_);
        created = error == ESP_OK;
        return error;
    }
    if (error != ESP_OK)
        return error;
    if (size > 20000)
        return ESP_ERR_INVALID_SIZE;
    std::string data(size, '\0');
    error = nvs_get_str(nvs.handle, "config", data.data(), &size);
    if (error != ESP_OK)
        return error;
    data.resize(size - 1);
    auto parsed = parse_json(data);
    secure_clear(data.data(), data.size());
    if (!parsed)
        return ESP_ERR_INVALID_ARG;
    auto validation = update(parsed.get(), config_, true);
    if (validation == "unsupported_config_version")
        return ESP_ERR_NOT_SUPPORTED;
    return validation.empty() ? ESP_OK : ESP_ERR_INVALID_ARG;
}
esp_err_t ConfigStore::persist(const Config &cfg) {
    Nvs nvs;
    auto error = nvs_open("tepy", NVS_READWRITE, &nvs.handle);
    if (error != ESP_OK)
        return error;
    auto data = encode(cfg, false);
    if (data.empty())
        return ESP_ERR_NO_MEM;
    error = nvs_set_str(nvs.handle, "config", data.c_str());
    secure_clear(data.data(), data.size());
    return error == ESP_OK ? nvs_commit(nvs.handle) : error;
}
Config ConfigStore::snapshot() const {
    std::lock_guard lock(mutex_);
    return config_;
}
std::string ConfigStore::public_json() const {
    std::lock_guard lock(mutex_);
    return encode(config_, true);
}
std::string_view ConfigStore::patch(std::string_view input) {
    if (input.size() > 16384)
        return "invalid_config";
    auto root = parse_json(input);
    if (!root)
        return "invalid_config";
    std::lock_guard lock(mutex_);
    auto candidate = config_;
    auto error = update(root.get(), candidate, false);
    if (!error.empty())
        return error;
    if (persist(candidate) != ESP_OK)
        return "storage_error";
    config_ = std::move(candidate);
    return {};
}
bool ConfigStore::authenticate(std::string_view value) const {
    std::lock_guard lock(mutex_);
    unsigned mismatch = static_cast<unsigned>(value.size() ^ config_.admin_password.size());
    for (size_t i = 0; i < config_.admin_password.size(); ++i)
        mismatch |= static_cast<unsigned char>(config_.admin_password[i]) ^
                    (i < value.size() ? static_cast<unsigned char>(value[i]) : 0);
    return mismatch == 0;
}
} // namespace tepy

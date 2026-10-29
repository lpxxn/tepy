#include "tepy/network.hpp"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_netif_sntp.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "mdns.h"
#include "tepy/json.hpp"
#include <array>
#include <cstring>
#include <sys/time.h>

namespace tepy {
Network *Network::instance_ = nullptr;
int64_t unix_ms() {
    timeval tv{};
    gettimeofday(&tv, nullptr);
    return static_cast<int64_t>(tv.tv_sec) * 1000 + tv.tv_usec / 1000;
}
esp_err_t Network::init(Config config, std::string id) {
    instance_ = this;
    config_ = std::move(config);
    id_ = std::move(id);
    auto err = esp_netif_init();
    if (err != ESP_OK)
        return err;
    err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE)
        return err;
    if (!esp_netif_create_default_wifi_sta() || !esp_netif_create_default_wifi_ap())
        return ESP_ERR_NO_MEM;
    err = esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, event, this);
    if (err != ESP_OK)
        return err;
    err = esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, event, this);
    if (err != ESP_OK)
        return err;
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    err = esp_wifi_init(&init);
    if (err != ESP_OK)
        return err;
    err = esp_wifi_set_storage(WIFI_STORAGE_RAM);
    if (err != ESP_OK)
        return err;
    wifi_config_t sta{};
    std::memcpy(sta.sta.ssid, config_.ssid.data(), config_.ssid.size());
    std::memcpy(sta.sta.password, config_.wifi_password.data(), config_.wifi_password.size());
    sta.sta.pmf_cfg.capable = true;
    sta.sta.pmf_cfg.required = false;
    wifi_config_t ap{};
    const auto ssid = "Tepy-" + id_.substr(id_.size() - 6);
    std::memcpy(ap.ap.ssid, ssid.data(), ssid.size());
    ap.ap.ssid_len = ssid.size();
    std::memcpy(ap.ap.password, config_.ap_password.data(), config_.ap_password.size());
    ap.ap.authmode = WIFI_AUTH_WPA2_PSK;
    ap.ap.max_connection = 2;
    ap.ap.channel = 1;
    hotspot_ = config_.ssid.empty();
    err = esp_wifi_set_mode(WIFI_MODE_APSTA);
    if (err != ESP_OK)
        return err;
    // Do not submit an empty STA SSID on first boot: only the setup AP is needed.
    if (!config_.ssid.empty()) {
        err = esp_wifi_set_config(WIFI_IF_STA, &sta);
        if (err != ESP_OK)
            return err;
    }
    err = esp_wifi_set_config(WIFI_IF_AP, &ap);
    if (err != ESP_OK)
        return err;
    if (!hotspot_) {
        err = esp_wifi_set_mode(WIFI_MODE_STA);
        if (err != ESP_OK)
            return err;
    }
    esp_sntp_config_t sntp = ESP_NETIF_SNTP_DEFAULT_CONFIG(config_.ntp_server.c_str());
    sntp.start = false;
    sntp.sync_cb = [](timeval *) {
        if (instance_)
            instance_->time_ready_ = true;
    };
    err = esp_netif_sntp_init(&sntp);
    if (err != ESP_OK)
        return err;
    err = esp_wifi_start();
    if (err != ESP_OK)
        return err;
    esp_wifi_set_ps(WIFI_PS_MIN_MODEM);
    err = mdns_init();
    if (err != ESP_OK)
        return err;
    const auto host = "tepy-" + id_;
    err = mdns_hostname_set(host.c_str());
    if (err != ESP_OK)
        return err;
    err = mdns_instance_name_set("Tepy BLE keyboard");
    if (err != ESP_OK)
        return err;
    err = mdns_service_add(nullptr, "_http", "_tcp", 80, nullptr, 0);
    if (err != ESP_OK)
        return err;
    disconnected_since_ = esp_timer_get_time();
    return ESP_OK;
}
void Network::event(void *arg, esp_event_base_t base, int32_t event, void *data) {
    auto &self = *static_cast<Network *>(arg);
    if (base == WIFI_EVENT && event == WIFI_EVENT_STA_DISCONNECTED) {
        self.connected_ = false;
        std::lock_guard lock(self.mutex_);
        self.ip_.clear();
    } else if (base == WIFI_EVENT && event == WIFI_EVENT_SCAN_DONE) {
        self.scan_done_ = true;
        self.scan_running_ = false;
    } else if (base == IP_EVENT && event == IP_EVENT_STA_GOT_IP) {
        auto *got = static_cast<ip_event_got_ip_t *>(data);
        char address[16];
        snprintf(address, sizeof(address), IPSTR, IP2STR(&got->ip_info.ip));
        {
            std::lock_guard lock(self.mutex_);
            self.ip_ = address;
        }
        self.connected_ = true;
        ESP_LOGI("network", "IP %s", address);
        esp_netif_sntp_start();
    }
}
void Network::tick() {
    const auto now = esp_timer_get_time();
    if (connected_) {
        disconnected_since_ = now;
        if (hotspot_ && !manual_hotspot_) {
            if (esp_wifi_set_mode(WIFI_MODE_STA) == ESP_OK)
                hotspot_ = false;
        }
    } else if (!config_.ssid.empty()) {
        if (now - last_connect_ > 5000000 && !scan_running_) {
            last_connect_ = now;
            esp_wifi_connect();
        }
        if (now - disconnected_since_ > 30000000 && !hotspot_)
            open_hotspot();
    }
}
void Network::open_hotspot() {
    manual_hotspot_ = true;
    if (!hotspot_ && esp_wifi_set_mode(WIFI_MODE_APSTA) == ESP_OK)
        hotspot_ = true;
}
std::string Network::ip() const {
    std::lock_guard lock(mutex_);
    return ip_;
}
std::string Network::scan() {
    auto root = object();
    if (scan_done_.exchange(false)) {
        uint16_t count = 20;
        std::array<wifi_ap_record_t, 20> aps{};
        auto error = esp_wifi_scan_get_ap_records(&count, aps.data());
        auto *list = cJSON_AddArrayToObject(root.get(), "networks");
        if (error == ESP_OK)
            for (unsigned i = 0; i < count; ++i) {
                auto *item = cJSON_CreateObject();
                cJSON_AddItemToArray(list, item);
                cJSON_AddStringToObject(item, "ssid", reinterpret_cast<const char *>(aps[i].ssid));
                cJSON_AddNumberToObject(item, "rssi", aps[i].rssi);
                cJSON_AddBoolToObject(item, "secured", aps[i].authmode != WIFI_AUTH_OPEN);
            }
        cJSON_AddBoolToObject(root.get(), "scanning", false);
    } else {
        if (!scan_running_.exchange(true)) {
            wifi_scan_config_t cfg{};
            if (esp_wifi_scan_start(&cfg, false) != ESP_OK)
                scan_running_ = false;
        }
        cJSON_AddBoolToObject(root.get(), "scanning", scan_running_.load());
    }
    return stringify(root.get());
}
} // namespace tepy

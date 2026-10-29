#pragma once
#include "esp_event.h"
#include "tepy/config.hpp"
#include <atomic>
#include <mutex>
#include <string>

namespace tepy {
class Network {
  public:
    esp_err_t init(Config config, std::string device_id);
    void tick();
    void open_hotspot();
    bool connected() const { return connected_; }
    bool time_ready() const { return time_ready_; }
    bool hotspot() const { return hotspot_; }
    std::string ip() const;
    std::string scan();

  private:
    static void event(void *, esp_event_base_t, int32_t, void *);
    Config config_;
    std::string id_;
    mutable std::mutex mutex_;
    std::string ip_;
    std::atomic<bool> connected_{false}, hotspot_{false}, manual_hotspot_{false},
        time_ready_{false}, scan_running_{false}, scan_done_{false};
    int64_t disconnected_since_{};
    int64_t last_connect_{};
    static Network *instance_;
};
int64_t unix_ms();
} // namespace tepy

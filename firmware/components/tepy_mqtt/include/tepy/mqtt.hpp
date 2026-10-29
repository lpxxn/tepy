#pragma once
#include "mqtt_client.h"
#include "tepy/config.hpp"
#include <atomic>
#include <functional>
#include <mutex>

namespace tepy {
class MqttTransport {
  public:
    using Handler = std::function<void(std::string_view, bool)>;
    esp_err_t init(Config config, std::string id, Handler handler);
    void set_state_builder(std::function<std::string()> builder) {
        state_builder_ = std::move(builder);
    }
    void tick(bool network_ready);
    bool connected() const { return connected_; }
    std::string session() const;
    void reply(std::string_view id, std::string_view status, std::string_view error);
    void publish_state();

  private:
    static void event(void *, esp_event_base_t, int32_t, void *);
    esp_mqtt_client_handle_t client_{};
    Config config_;
    std::string prefix_, command_topic_, reply_topic_, state_topic_, will_;
    mutable std::mutex mutex_;
    std::string session_;
    Handler handler_;
    std::function<std::string()> state_builder_;
    std::string input_;
    size_t received_{}, expected_{};
    bool receiving_{false}, retained_{false}, started_{false};
    std::atomic<bool> connected_{false};
    int64_t last_state_{};
};
} // namespace tepy

#include "tepy/mqtt.hpp"
#include "esp_crt_bundle.h"
#include "esp_timer.h"
#include "tepy/json.hpp"

namespace tepy {
esp_err_t MqttTransport::init(Config config, std::string id, Handler handler) {
    config_ = std::move(config);
    handler_ = std::move(handler);
    prefix_ = "tepy/" + id;
    command_topic_ = prefix_ + "/cmd";
    reply_topic_ = prefix_ + "/reply";
    state_topic_ = prefix_ + "/state";
    input_.reserve(4096);
    auto will = object();
    cJSON_AddNumberToObject(will.get(), "v", 1);
    cJSON_AddStringToObject(will.get(), "device_id", id.c_str());
    cJSON_AddStringToObject(will.get(), "session", "");
    cJSON_AddBoolToObject(will.get(), "online", false);
    cJSON_AddBoolToObject(will.get(), "time_ready", false);
    will_ = stringify(will.get());
    if (config_.mqtt_uri.empty())
        return ESP_OK;
    esp_mqtt_client_config_t cfg{};
    cfg.broker.address.uri = config_.mqtt_uri.c_str();
    if (config_.mqtt_uri.starts_with("mqtts://")) {
        if (config_.mqtt_ca.empty())
            cfg.broker.verification.crt_bundle_attach = esp_crt_bundle_attach;
        else
            cfg.broker.verification.certificate = config_.mqtt_ca.c_str();
    }
    cfg.credentials.client_id = id.c_str();
    cfg.credentials.username =
        config_.mqtt_username.empty() ? nullptr : config_.mqtt_username.c_str();
    cfg.credentials.authentication.password =
        config_.mqtt_password.empty() ? nullptr : config_.mqtt_password.c_str();
    cfg.session.disable_clean_session = false;
    cfg.session.protocol_ver = MQTT_PROTOCOL_V_3_1_1;
    cfg.session.last_will.topic = state_topic_.c_str();
    cfg.session.last_will.msg = will_.c_str();
    cfg.session.last_will.msg_len = will_.size();
    cfg.session.last_will.qos = 1;
    cfg.session.last_will.retain = true;
    cfg.network.reconnect_timeout_ms = 5000;
    cfg.buffer.size = 2048;
    cfg.buffer.out_size = 2048;
    cfg.task.stack_size = 8192;
    client_ = esp_mqtt_client_init(&cfg);
    if (!client_)
        return ESP_ERR_NO_MEM;
    return esp_mqtt_client_register_event(client_, MQTT_EVENT_ANY, event, this);
}
std::string MqttTransport::session() const {
    std::lock_guard lock(mutex_);
    return session_;
}
void MqttTransport::tick(bool network_ready) {
    if (!client_)
        return;
    if (!started_ && network_ready)
        started_ = esp_mqtt_client_start(client_) == ESP_OK;
    if (connected_ && esp_timer_get_time() - last_state_ > 5000000) {
        last_state_ = esp_timer_get_time();
        publish_state();
    }
}
void MqttTransport::publish_state() {
    if (!connected_ || !state_builder_)
        return;
    const auto json = state_builder_();
    esp_mqtt_client_enqueue(client_, state_topic_.c_str(), json.c_str(), json.size(), 1, true,
                            false);
}
void MqttTransport::reply(std::string_view id, std::string_view status, std::string_view error) {
    if (!connected_)
        return;
    auto root = object();
    cJSON_AddNumberToObject(root.get(), "v", 1);
    cJSON_AddStringToObject(root.get(), "id", std::string(id).c_str());
    cJSON_AddStringToObject(root.get(), "status", std::string(status).c_str());
    cJSON_AddStringToObject(root.get(), "error", std::string(error).c_str());
    const auto json = stringify(root.get());
    esp_mqtt_client_enqueue(client_, reply_topic_.c_str(), json.c_str(), json.size(), 1, false,
                            false);
}
void MqttTransport::event(void *arg, esp_event_base_t, int32_t code, void *raw) {
    auto &self = *static_cast<MqttTransport *>(arg);
    auto *event = static_cast<esp_mqtt_event_handle_t>(raw);
    if (code == MQTT_EVENT_CONNECTED) {
        {
            std::lock_guard lock(self.mutex_);
            self.session_ = random_hex(16);
        }
        self.connected_ = true;
        esp_mqtt_client_subscribe(self.client_, self.command_topic_.c_str(), 1);
        self.publish_state();
    } else if (code == MQTT_EVENT_DISCONNECTED) {
        self.connected_ = false;
        {
            std::lock_guard lock(self.mutex_);
            self.session_.clear();
        }
        secure_clear(self.input_.data(), self.input_.size());
        self.input_.clear();
        self.receiving_ = false;
    } else if (code == MQTT_EVENT_DATA) {
        if (event->current_data_offset == 0) {
            secure_clear(self.input_.data(), self.input_.size());
            self.input_.clear();
            self.received_ = 0;
            self.expected_ = event->total_data_len;
            self.retained_ = event->retain;
            self.receiving_ =
                event->topic &&
                std::string_view(event->topic, event->topic_len) == self.command_topic_ &&
                self.expected_ > 0 && self.expected_ <= 4096;
            if (!self.receiving_) {
                self.reply("", "rejected", "invalid_command");
                return;
            }
        }
        if (!self.receiving_)
            return;
        if (event->current_data_offset < 0 ||
            static_cast<size_t>(event->current_data_offset) != self.received_ ||
            event->data_len < 0 || self.received_ + event->data_len > self.expected_) {
            self.receiving_ = false;
            secure_clear(self.input_.data(), self.input_.size());
            self.input_.clear();
            return;
        }
        self.input_.append(event->data, event->data_len);
        self.received_ += event->data_len;
        if (self.received_ == self.expected_) {
            self.handler_(self.input_, self.retained_);
            secure_clear(self.input_.data(), self.input_.size());
            self.input_.clear();
            self.receiving_ = false;
        }
    }
}
} // namespace tepy

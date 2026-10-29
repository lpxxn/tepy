#include "driver/gpio.h"
#include "esp_app_desc.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "tepy/ble.hpp"
#include "tepy/config.hpp"
#include "tepy/core.hpp"
#include "tepy/json.hpp"
#include "tepy/mqtt.hpp"
#include "tepy/network.hpp"
#include "tepy/ota.hpp"
#include "tepy/web.hpp"
#include <atomic>
#include <memory>
#include <mutex>
#include <new>

namespace tepy {
class PinnedKeyboard final : public Keyboard {
  public:
    explicit PinnedKeyboard(BleKeyboard &source) : source_(source), epoch_(source.epoch()) {}
    bool ready() const override { return source_.epoch() == epoch_ && source_.ready(); }
    bool send(const Report &report) override { return ready() && source_.send(report); }
    void wait(unsigned ms) override { source_.wait(ms); }

  private:
    BleKeyboard &source_;
    uint32_t epoch_;
};
struct CommandDelete {
    void operator()(Command *command) const {
        if (command) {
            command->clear();
            delete command;
        }
    }
};
class Application {
  public:
    Application()
        : web_({config_, ble_, network_, ota_, [this] { return status(); },
                [this] { return maintenance(); }, [this] { busy_ = false; },
                [this] { reboot_at_ = esp_timer_get_time() + 1000000; }}) {}
    esp_err_t start() {
        bool created = false;
        auto error = config_.init(created);
        if (error != ESP_OK)
            return error;
        key_delay_ms_ = config_.snapshot().key_delay_ms;
        uint8_t mac[6]{};
        error = esp_read_mac(mac, ESP_MAC_WIFI_STA);
        if (error != ESP_OK)
            return error;
        char id[13];
        snprintf(id, sizeof(id), "%02x%02x%02x%02x%02x%02x", mac[0], mac[1], mac[2], mac[3], mac[4],
                 mac[5]);
        id_ = id;
        if (created)
            print_recovery();
        error = ble_.init("Tepy-" + id_.substr(6));
        if (error != ESP_OK)
            return error;
        error = network_.init(config_.snapshot(), id_);
        if (error != ESP_OK)
            return error;
        queue_ = xQueueCreate(1, sizeof(Command *));
        if (!queue_)
            return ESP_ERR_NO_MEM;
        if (xTaskCreate(worker, "tepy_input", 6144, this, 5, nullptr) != pdPASS)
            return ESP_ERR_NO_MEM;
        mqtt_.set_state_builder([this] { return status(); });
        error = mqtt_.init(config_.snapshot(), id_, [this](std::string_view value, bool retained) {
            admit(value, retained);
        });
        if (error != ESP_OK)
            return error;
        error = web_.start();
        if (error != ESP_OK)
            return error;
        gpio_config_t button{};
        button.pin_bit_mask = 1ULL << CONFIG_TEPY_RECOVERY_GPIO;
        button.mode = GPIO_MODE_INPUT;
        button.pull_up_en = GPIO_PULLUP_ENABLE;
        error = gpio_config(&button);
        if (error != ESP_OK)
            return error;
        for (unsigned i = 0; i < 50 && !ble_.initialized(); ++i)
            vTaskDelay(pdMS_TO_TICKS(100));
        if (!ble_.initialized())
            return ESP_ERR_TIMEOUT;
        if (xTaskCreate(supervisor, "tepy_service", 6144, this, 3, nullptr) != pdPASS)
            return ESP_ERR_NO_MEM;
        return ota_.confirm_boot();
    }

  private:
    bool maintenance() {
        bool expected = false;
        return !reboot_at_ && busy_.compare_exchange_strong(expected, true);
    }
    void print_recovery() {
        const auto cfg = config_.snapshot();
        printf("\nTEPY LOCAL SETUP\nDevice: %s\nAP: Tepy-%s\nAP password: %s\nAdmin token: "
               "%s\nhttp://192.168.4.1\n\n",
               id_.c_str(), id_.size() >= 6 ? id_.substr(id_.size() - 6).c_str() : "",
               cfg.ap_password.c_str(), cfg.admin_password.c_str());
    }
    std::string status() {
        auto root = object();
        cJSON_AddNumberToObject(root.get(), "v", 1);
        cJSON_AddStringToObject(root.get(), "device_id", id_.c_str());
        cJSON_AddStringToObject(root.get(), "firmware", esp_app_get_description()->version);
        auto session = mqtt_.session();
        cJSON_AddStringToObject(root.get(), "session", session.c_str());
        cJSON_AddBoolToObject(root.get(), "online", mqtt_.connected());
        cJSON_AddBoolToObject(root.get(), "time_ready", network_.time_ready());
        cJSON_AddNumberToObject(root.get(), "now", unix_ms());
        cJSON_AddBoolToObject(root.get(), "busy", busy_.load());
        auto *wifi = cJSON_AddObjectToObject(root.get(), "wifi");
        cJSON_AddBoolToObject(wifi, "connected", network_.connected());
        cJSON_AddBoolToObject(wifi, "hotspot", network_.hotspot());
        cJSON_AddStringToObject(wifi, "ip", network_.ip().c_str());
        auto *mqtt = cJSON_AddObjectToObject(root.get(), "mqtt");
        cJSON_AddBoolToObject(mqtt, "connected", mqtt_.connected());
        auto *ble = cJSON_AddObjectToObject(root.get(), "ble");
        cJSON_AddBoolToObject(ble, "connected", ble_.connected());
        cJSON_AddBoolToObject(ble, "ready", ble_.ready());
        cJSON_AddBoolToObject(ble, "bonded", ble_.bonded());
        cJSON_AddBoolToObject(ble, "pairing_open", ble_.pairing_open());
        cJSON_AddBoolToObject(ble, "passkey_pending", ble_.pairing_pending());
        cJSON_AddBoolToObject(ble, "pnp_id_present", ble_.pnp_present());
        cJSON_AddStringToObject(ble, "protocol_mode",
                                ble_.protocol() == hid::boot_protocol ? "boot" : "report");
        cJSON_AddBoolToObject(ble, "report_subscribed", ble_.report_subscribed());
        cJSON_AddBoolToObject(ble, "boot_subscribed", ble_.boot_subscribed());
        auto *reads = cJSON_AddArrayToObject(ble, "host_reads");
        const auto read_mask = ble_.host_read_mask();
        for (size_t i = 0; i < hid::attribute_count; ++i)
            if (read_mask & (uint32_t{1} << i))
                cJSON_AddItemToArray(
                    reads,
                    cJSON_CreateString(hid::attribute_name(static_cast<hid::Attribute>(i)).data()));
        cJSON_AddNumberToObject(ble, "tx_completed", ble_.tx_completed());
        cJSON_AddNumberToObject(ble, "tx_errors", ble_.tx_errors());
        return stringify(root.get());
    }
    void admit(std::string_view input, bool retained) {
        Command cmd;
        auto issue = parse_command(input, cmd);
        const auto reject = [&](std::string_view error) {
            mqtt_.reply(cmd.id.data(), "rejected", error);
            cmd.clear();
        };
        if (!issue.empty()) {
            reject(issue);
            return;
        }
        auto session = mqtt_.session();
        issue = validate_envelope(cmd, session, unix_ms(), network_.time_ready(), retained);
        if (!issue.empty()) {
            reject(issue);
            return;
        }
        if (!ble_.ready()) {
            reject("ble_not_ready");
            return;
        }
        if (!maintenance()) {
            reject("busy");
            return;
        }
        {
            std::lock_guard lock(gate_);
            if (dedup_session_ != session) {
                dedup_.clear();
                dedup_session_ = session;
            }
            issue = dedup_.remember(cmd, unix_ms());
        }
        if (!issue.empty()) {
            busy_ = false;
            reject(issue);
            return;
        }
        auto *copy = new (std::nothrow) Command(cmd);
        if (!copy || xQueueSend(queue_, &copy, 0) != pdPASS) {
            if (copy) {
                copy->clear();
                delete copy;
            }
            busy_ = false;
            reject("busy");
            return;
        }
        cmd.clear();
    }
    static void worker(void *arg) {
        auto &app = *static_cast<Application *>(arg);
        while (true) {
            Command *pointer = nullptr;
            if (xQueueReceive(app.queue_, &pointer, portMAX_DELAY) != pdTRUE)
                continue;
            std::unique_ptr<Command, CommandDelete> cmd(pointer);
            auto issue = validate_envelope(*cmd, app.mqtt_.session(), unix_ms(),
                                           app.network_.time_ready(), false);
            if (issue.empty()) {
                PinnedKeyboard keyboard(app.ble_);
                issue = execute(*cmd, keyboard, app.key_delay_ms_, [&] {
                    return !app.reboot_at_ && app.mqtt_.connected() &&
                           app.mqtt_.session() == cmd->session.data();
                });
            }
            app.mqtt_.reply(cmd->id.data(), issue.empty() ? "sent" : "failed", issue);
            cmd.reset();
            app.busy_ = false;
        }
    }
    static void supervisor(void *arg) {
        auto &app = *static_cast<Application *>(arg);
        int64_t pressed = 0;
        bool handled = false;
        while (true) {
            app.network_.tick();
            // TLS certificates and action freshness both require a valid clock.
            app.mqtt_.tick(app.network_.connected() && app.network_.time_ready());
            const auto now = esp_timer_get_time();
            if (app.reboot_at_ && now >= app.reboot_at_)
                esp_restart();
            if (gpio_get_level(static_cast<gpio_num_t>(CONFIG_TEPY_RECOVERY_GPIO)) == 0) {
                if (!pressed)
                    pressed = now;
                if (!handled && now - pressed >= 3000000) {
                    app.network_.open_hotspot();
                    app.print_recovery();
                    handled = true;
                }
            } else {
                pressed = 0;
                handled = false;
            }
            vTaskDelay(pdMS_TO_TICKS(100));
        }
    }
    ConfigStore config_;
    BleKeyboard ble_;
    Network network_;
    MqttTransport mqtt_;
    OtaUpdater ota_;
    WebServer web_;
    std::string id_, dedup_session_;
    QueueHandle_t queue_{};
    std::mutex gate_;
    Deduplicator dedup_;
    std::atomic<bool> busy_{false};
    std::atomic<int64_t> reboot_at_{0};
    unsigned key_delay_ms_{20};
};
} // namespace tepy
extern "C" void app_main() {
    // Never erase user settings or bonds automatically on an NVS error.
    ESP_ERROR_CHECK(nvs_flash_init());
    static tepy::Application app;
    ESP_ERROR_CHECK(app.start());
}

#include "tepy/serial.hpp"
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "tepy/json.hpp"
#include "tepy/serial_protocol.hpp"
#include <array>
#include <cstdio>

namespace tepy {
esp_err_t SerialServer::start() {
#if CONFIG_TEPY_SERIAL_ENABLED
    if (!usb_serial_jtag_is_driver_installed()) {
        usb_serial_jtag_driver_config_t config{};
        config.rx_buffer_size = 4096;
        config.tx_buffer_size = 4096;
        const auto err = usb_serial_jtag_driver_install(&config);
        if (err != ESP_OK)
            return err;
    }
    // Both log output and framed replies use the same VFS / FILE locking.
    usb_serial_jtag_vfs_use_driver();
    if (xTaskCreate(task, "tepy_serial", 8192, this, 2, nullptr) != pdPASS)
        return ESP_ERR_NO_MEM;
#endif
    return ESP_OK;
}
void SerialServer::task(void *self) {
    auto &owner = *static_cast<SerialServer *>(self);
    serial::Decoder decoder([&](std::string_view input) {
        auto result = serial::reply(
            input, [&](std::string_view token) { return owner.management_.authenticate(token); },
            [&](std::string_view method, std::string_view params) {
                return owner.management_.dispatch(method, params);
            });
        flockfile(stdout);
        printf("\n@tepy:%s\n", result.c_str());
        fflush(stdout);
        funlockfile(stdout);
        secure_clear(result.data(), result.size());
    });
    std::array<char, 256> buffer{};
    int64_t last_byte = 0;
    while (true) {
        const auto count =
            usb_serial_jtag_read_bytes(buffer.data(), buffer.size(), pdMS_TO_TICKS(100));
        const auto now = esp_timer_get_time();
        if (last_byte && now - last_byte > 5000000) {
            decoder.reset();
            last_byte = 0;
        }
        if (count > 0) {
            decoder.feed({buffer.data(), static_cast<size_t>(count)});
            secure_clear(buffer.data(), buffer.size());
            last_byte = now;
        }
    }
}
} // namespace tepy

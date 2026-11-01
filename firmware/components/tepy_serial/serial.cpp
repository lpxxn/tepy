#include "tepy/serial.hpp"
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "mbedtls/base64.h"
#include "tepy/json.hpp"
#include "tepy/serial_protocol.hpp"
#include "tepy/serial_upload.hpp"
#include <array>
#include <cmath>
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
    if (xTaskCreate(task, "tepy_serial", 16384, this, 2, nullptr) != pdPASS)
        return ESP_ERR_NO_MEM;
#endif
    return ESP_OK;
}
void SerialServer::task(void *self) {
    auto &owner = *static_cast<SerialServer *>(self);
    serial::Upload upload(
        {[&] { return owner.management_.begin_maintenance(); },
         [&] { owner.management_.end_maintenance(); },
         [&](size_t size, std::string_view hash) { return owner.ota_.begin(size, hash); },
         [&](std::string_view bytes) { return owner.ota_.write(bytes); },
         [&] {
             auto issue = owner.ota_.finish();
             if (issue.empty())
                 owner.management_.reboot();
             return issue;
         },
         [&] { owner.ota_.abort(); }});
    const auto error = [](std::string_view code) {
        auto json = object();
        cJSON_AddStringToObject(json.get(), "error", std::string(code).c_str());
        return stringify(json.get());
    };
    const auto integer = [](const cJSON *value, size_t maximum) {
        return cJSON_IsNumber(value) && value->valuedouble >= 0 && value->valuedouble <= maximum &&
               std::floor(value->valuedouble) == value->valuedouble;
    };
    serial::Decoder decoder([&](std::string_view input) {
        upload.expire(esp_timer_get_time() / 1000);
        auto result = serial::reply(
            input, [&](std::string_view token) { return owner.management_.authenticate(token); },
            [&](std::string_view method, std::string_view params) {
                const auto now = esp_timer_get_time() / 1000;
                if (method == "ota.begin") {
                    auto body = parse_json(params);
                    if (!fields_only(body.get(), {"device_id", "session", "size", "sha256"}) ||
                        !integer(field(body.get(), "size"), 4 * 1024 * 1024))
                        return error("invalid_upload");
                    auto state = parse_json(owner.management_.dispatch("status.get", "{}"));
                    if (text(field(body.get(), "device_id")) !=
                            text(field(state.get(), "device_id")) ||
                        text(field(body.get(), "session")) !=
                            text(field(state.get(), "boot_session")))
                        return error("wrong_device_session");
                    std::array<uint8_t, 16> random{};
                    esp_fill_random(random.data(), random.size());
                    constexpr char hex[] = "0123456789abcdef";
                    std::string id(32, '0');
                    for (size_t i = 0; i < random.size(); ++i) {
                        id[i * 2] = hex[random[i] >> 4];
                        id[i * 2 + 1] = hex[random[i] & 15];
                    }
                    auto issue = upload.begin(
                        id, static_cast<size_t>(field(body.get(), "size")->valuedouble),
                        text(field(body.get(), "sha256")), now);
                    if (!issue.empty())
                        return error(issue);
                    auto reply = object();
                    cJSON_AddStringToObject(reply.get(), "upload_id", id.c_str());
                    cJSON_AddNumberToObject(reply.get(), "next_offset", 0);
                    cJSON_AddNumberToObject(reply.get(), "max_chunk_bytes",
                                            serial::upload_chunk_size);
                    return stringify(reply.get());
                }
                if (method == "ota.write" || method == "ota.finish" || method == "ota.abort") {
                    auto body = parse_json(params);
                    const auto id = text(field(body.get(), "upload_id"));
                    std::string_view issue;
                    if (method == "ota.write") {
                        const auto encoded = text(field(body.get(), "data"));
                        std::array<unsigned char, serial::upload_chunk_size> bytes{};
                        size_t count{};
                        if (!fields_only(body.get(), {"upload_id", "offset", "data"}) ||
                            !integer(field(body.get(), "offset"), 4 * 1024 * 1024) ||
                            encoded.empty() || encoded.size() > 4096 ||
                            mbedtls_base64_decode(
                                bytes.data(), bytes.size(), &count,
                                reinterpret_cast<const unsigned char *>(encoded.data()),
                                encoded.size()) != 0) {
                            upload.abort(id);
                            return error("invalid_chunk");
                        }
                        issue = upload.write(
                            id, static_cast<size_t>(field(body.get(), "offset")->valuedouble),
                            {reinterpret_cast<char *>(bytes.data()), count}, now);
                    } else {
                        if (!fields_only(body.get(), {"upload_id"}))
                            return error("invalid_upload");
                        issue = method == "ota.finish" ? upload.finish(id, now) : upload.abort(id);
                    }
                    if (!issue.empty())
                        return error(issue);
                    if (method == "ota.finish") {
                        return std::string("{\"ok\":true,\"rebooting\":true}");
                    }
                    auto reply = object();
                    cJSON_AddNumberToObject(reply.get(), "next_offset", upload.received());
                    return stringify(reply.get());
                }
                if (upload.active() && method != "status.get" && method != "config.get")
                    return error("busy");
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
        upload.expire(now / 1000);
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

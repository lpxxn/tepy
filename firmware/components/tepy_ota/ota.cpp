#include "tepy/ota.hpp"
#include "esp_app_desc.h"
#include "esp_ota_ops.h"
#include <array>
#include <cstring>

namespace tepy {
namespace {
struct Transaction {
    esp_ota_handle_t handle{};
    bool active{false};
    ~Transaction() {
        if (active)
            esp_ota_abort(handle);
    }
};
} // namespace
std::string_view OtaUpdater::upload(size_t length, const Reader &read) {
    auto *partition = esp_ota_get_next_update_partition(nullptr);
    if (!partition || length < sizeof(esp_app_desc_t) + 32 || length > partition->size)
        return "invalid_image_size";
    Transaction tx;
    if (esp_ota_begin(partition, length, &tx.handle) != ESP_OK)
        return "ota_begin_error";
    tx.active = true;
    std::array<char, 4096> buffer{};
    size_t received = 0;
    while (received < length) {
        const auto count = read(buffer.data(), std::min(buffer.size(), length - received));
        if (count <= 0 || static_cast<size_t>(count) > length - received)
            return "upload_interrupted";
        if (esp_ota_write(tx.handle, buffer.data(), count) != ESP_OK)
            return "invalid_image";
        received += count;
    }
    tx.active = false;
    if (esp_ota_end(tx.handle) != ESP_OK)
        return "invalid_image";
    esp_app_desc_t description{};
    if (esp_ota_get_partition_description(partition, &description) != ESP_OK ||
        std::strncmp(description.project_name, "tepy", sizeof(description.project_name)) != 0)
        return "wrong_project";
    if (esp_ota_set_boot_partition(partition) != ESP_OK)
        return "ota_activate_error";
    return {};
}
esp_err_t OtaUpdater::confirm_boot() {
    esp_ota_img_states_t state{};
    auto *running = esp_ota_get_running_partition();
    if (!running)
        return ESP_FAIL;
    auto err = esp_ota_get_state_partition(running, &state);
    if (err == ESP_ERR_NOT_FOUND)
        return ESP_OK;
    if (err != ESP_OK)
        return err;
    return state == ESP_OTA_IMG_PENDING_VERIFY ? esp_ota_mark_app_valid_cancel_rollback() : ESP_OK;
}
} // namespace tepy

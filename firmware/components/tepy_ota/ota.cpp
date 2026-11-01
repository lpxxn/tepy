#include "tepy/ota.hpp"
#include "esp_app_desc.h"
#include "esp_ota_ops.h"
#include <array>
#include <cstring>

namespace tepy {
void OtaUpdater::abort() {
    if (active_)
        esp_ota_abort(handle_);
    psa_hash_abort(&hash_);
    active_ = false;
    partition_ = nullptr;
    expected_ = received_ = 0;
    digest_.clear();
}
std::string_view OtaUpdater::begin(size_t length, std::string_view sha256) {
    if (active_)
        return "busy";
    abort();
    partition_ = esp_ota_get_next_update_partition(nullptr);
    if (!partition_ || length < sizeof(esp_app_desc_t) + 32 || length > partition_->size)
        return "invalid_image_size";
    if (!sha256.empty()) {
        if (sha256.size() != 64)
            return "invalid_digest";
        for (char c : sha256)
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
                return "invalid_digest";
    }
    if (psa_crypto_init() != PSA_SUCCESS ||
        psa_hash_setup(&hash_, PSA_ALG_SHA_256) != PSA_SUCCESS) {
        abort();
        return "hash_error";
    }
    if (esp_ota_begin(partition_, length, &handle_) != ESP_OK) {
        abort();
        return "ota_begin_error";
    }
    active_ = true;
    expected_ = length;
    digest_ = sha256;
    return {};
}
std::string_view OtaUpdater::write(std::string_view bytes) {
    if (!active_ || bytes.empty() || bytes.size() > expected_ - received_)
        return "invalid_chunk";
    if (esp_ota_write(handle_, bytes.data(), bytes.size()) != ESP_OK)
        return "invalid_image";
    if (psa_hash_update(&hash_, reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size()) !=
        PSA_SUCCESS)
        return "hash_error";
    received_ += bytes.size();
    return {};
}
std::string_view OtaUpdater::finish() {
    if (!active_ || received_ != expected_)
        return "incomplete_upload";
    std::array<uint8_t, 32> hash{};
    size_t count{};
    if (psa_hash_finish(&hash_, hash.data(), hash.size(), &count) != PSA_SUCCESS ||
        count != hash.size())
        return "hash_error";
    constexpr char hex[] = "0123456789abcdef";
    std::array<char, 64> encoded{};
    for (size_t i = 0; i < hash.size(); ++i) {
        encoded[i * 2] = hex[hash[i] >> 4];
        encoded[i * 2 + 1] = hex[hash[i] & 15];
    }
    if (!digest_.empty() && std::string_view(encoded.data(), encoded.size()) != digest_)
        return "digest_mismatch";
    // esp_ota_end consumes the handle on success and failure. Activation is always last.
    active_ = false;
    if (esp_ota_end(handle_) != ESP_OK)
        return "invalid_image";
    esp_app_desc_t description{};
    if (esp_ota_get_partition_description(partition_, &description) != ESP_OK ||
        std::strncmp(description.project_name, "tepy", sizeof(description.project_name)) != 0)
        return "wrong_project";
    if (esp_ota_set_boot_partition(partition_) != ESP_OK)
        return "ota_activate_error";
    return {};
}
std::string_view OtaUpdater::upload(size_t length, const Reader &read) {
    if (auto issue = begin(length); !issue.empty())
        return issue;
    struct Guard {
        OtaUpdater &owner;
        ~Guard() { owner.abort(); }
    } guard{*this};
    std::array<char, 4096> buffer{};
    while (received_ < length) {
        const auto count = read(buffer.data(), std::min(buffer.size(), length - received_));
        if (count <= 0 || static_cast<size_t>(count) > length - received_)
            return "upload_interrupted";
        if (auto issue = write({buffer.data(), static_cast<size_t>(count)}); !issue.empty())
            return issue;
    }
    return finish();
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

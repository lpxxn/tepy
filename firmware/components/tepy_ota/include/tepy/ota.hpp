#pragma once
#include "esp_err.h"
#include "esp_ota_ops.h"
#include "psa/crypto.h"
#include <functional>
#include <string>
#include <string_view>

namespace tepy {
class OtaUpdater {
  public:
    OtaUpdater() = default;
    ~OtaUpdater() { abort(); }
    OtaUpdater(const OtaUpdater &) = delete;
    OtaUpdater &operator=(const OtaUpdater &) = delete;
    using Reader = std::function<int(char *, size_t)>;
    std::string_view upload(size_t length, const Reader &read);
    // Caller holds the application's maintenance lease for this entire transaction.
    std::string_view begin(size_t length, std::string_view sha256 = {});
    std::string_view write(std::string_view bytes);
    std::string_view finish();
    void abort();
    esp_err_t confirm_boot();

  private:
    const esp_partition_t *partition_{};
    esp_ota_handle_t handle_{};
    bool active_{};
    size_t expected_{}, received_{};
    std::string digest_;
    psa_hash_operation_t hash_ = PSA_HASH_OPERATION_INIT;
};
} // namespace tepy

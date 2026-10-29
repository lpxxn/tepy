#pragma once
#include "esp_err.h"
#include <functional>
#include <string_view>

namespace tepy {
class OtaUpdater {
  public:
    using Reader = std::function<int(char *, size_t)>;
    std::string_view upload(size_t length, const Reader &read);
    esp_err_t confirm_boot();
};
} // namespace tepy

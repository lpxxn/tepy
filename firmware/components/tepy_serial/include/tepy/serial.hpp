#pragma once
#include "esp_err.h"
#include "tepy/management.hpp"
#include "tepy/ota.hpp"

namespace tepy {
class SerialServer {
  public:
    SerialServer(Management &management, OtaUpdater &ota) : management_(management), ota_(ota) {}
    esp_err_t start();

  private:
    static void task(void *self);
    Management &management_;
    OtaUpdater &ota_;
};
} // namespace tepy

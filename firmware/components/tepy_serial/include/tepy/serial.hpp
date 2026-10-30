#pragma once
#include "esp_err.h"
#include "tepy/management.hpp"

namespace tepy {
class SerialServer {
  public:
    explicit SerialServer(Management &management) : management_(management) {}
    esp_err_t start();

  private:
    static void task(void *self);
    Management &management_;
};
} // namespace tepy

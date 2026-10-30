#pragma once
#include "tepy/ble.hpp"
#include "tepy/config.hpp"
#include "tepy/network.hpp"
#include <functional>

namespace tepy {
struct ManagementServices {
    ConfigStore &config;
    BleKeyboard &ble;
    Network &network;
    std::function<std::string()> status;
    std::function<bool()> begin_maintenance;
    std::function<void()> end_maintenance;
    std::function<void()> reboot;
};
class Management {
  public:
    explicit Management(ManagementServices services) : services_(std::move(services)) {}
    bool authenticate(std::string_view token) const { return services_.config.authenticate(token); }
    std::string dispatch(std::string_view method, std::string_view params);
    bool begin_maintenance() { return services_.begin_maintenance(); }
    void end_maintenance() { services_.end_maintenance(); }
    void reboot() { services_.reboot(); }

  private:
    ManagementServices services_;
};
} // namespace tepy

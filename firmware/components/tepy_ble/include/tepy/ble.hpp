#pragma once
#include "esp_err.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_uuid.h"
#include "nimble/nimble_npl.h"
#include "tepy/core.hpp"
#include "tepy/hid_profile.hpp"
#include <atomic>
#include <mutex>
#include <string>

namespace tepy {
class BleKeyboard final : public Keyboard {
  public:
    esp_err_t init(std::string name);
    bool ready() const override {
        return hid::input_ready(connected_, encrypted_, protocol_, report_subscribed_,
                                boot_subscribed_);
    }
    bool send(const Report &) override;
    void wait(unsigned milliseconds) override;
    bool connected() const { return connected_; }
    bool bonded() const { return bonded_; }
    bool pairing_pending() const { return passkey_pending_; }
    bool pairing_open() const;
    uint32_t epoch() const { return epoch_; }
    bool initialized() const { return synced_; }
    uint8_t protocol() const { return protocol_; }
    bool report_subscribed() const { return report_subscribed_; }
    bool boot_subscribed() const { return boot_subscribed_; }
    bool pnp_present() const { return pnp_present_; }
    uint32_t host_read_mask() const { return host_read_mask_; }
    uint32_t tx_completed() const { return tx_completed_; }
    uint32_t tx_errors() const { return tx_errors_; }
    void open_pairing();
    void clear_bond();
    bool provide_passkey(std::string_view value);

  private:
    static BleKeyboard *instance_;
    static void sync();
    static void reset(int reason);
    static int gap(ble_gap_event *event, void *arg);
    static void host_task(void *);
    static void control(ble_npl_event *);
    static int access(uint16_t, uint16_t, ble_gatt_access_ctxt *, void *);
    static void registered(ble_gatt_register_ctxt *, void *);
    esp_err_t register_services();
    void reset_profile();
    void advertise();
    void refresh_bond();
    void queue_control();
    std::string name_;
    ble_npl_event control_event_{};
    ble_addr_t peer_{};
    uint16_t report_handle_{}, boot_handle_{}, protocol_handle_{};
    std::array<uint16_t, hid::attribute_count> handles_{};
    struct Binding {
        BleKeyboard *owner{};
        hid::Attribute attribute{};
    };
    std::array<Binding, hid::attribute_count> bindings_{};
    std::array<ble_uuid16_t, hid::attribute_count> uuids_{};
    std::array<ble_gatt_chr_def, 9> hid_characteristics_{};
    std::array<ble_gatt_chr_def, 6> dis_characteristics_{};
    std::array<ble_gatt_dsc_def, 2> input_descriptors_{}, output_descriptors_{};
    std::array<ble_gatt_svc_def, 3> services_{};
    std::mutex profile_mutex_;
    hid::Profile profile_;
    std::atomic<uint32_t> host_read_mask_{0}, tx_completed_{0}, tx_errors_{0};
    std::atomic<bool> report_subscribed_{false}, boot_subscribed_{false}, pnp_present_{false};
    std::atomic<uint8_t> protocol_{hid::report_protocol};
    uint8_t address_type_{};
    std::atomic<uint16_t> connection_{BLE_HS_CONN_HANDLE_NONE};
    std::atomic<bool> connected_{false}, encrypted_{false}, bonded_{false}, synced_{false},
        passkey_pending_{false};
    std::atomic<bool> request_clear_{false}, request_pair_{false};
    std::atomic<int> submitted_passkey_{-1};
    std::atomic<int64_t> pair_until_{0};
    std::atomic<uint32_t> epoch_{0};
};
} // namespace tepy

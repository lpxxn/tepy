#include "tepy/ble.hpp"
#include "esp_app_desc.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "host/ble_sm.h"
#include "host/ble_store.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include <cstring>
#include <memory>
#include <span>

extern "C" void ble_store_config_init(void);
namespace tepy {
BleKeyboard *BleKeyboard::instance_ = nullptr;
namespace {
struct MbufDelete {
    void operator()(os_mbuf *value) const { os_mbuf_free_chain(value); }
};
using Mbuf = std::unique_ptr<os_mbuf, MbufDelete>;
bool local_value_equals(uint16_t handle, std::span<const uint8_t> expected) {
    os_mbuf *raw = nullptr;
    const int rc = ble_att_svr_read_local(handle, &raw);
    Mbuf value(raw);
    if (rc != 0 || !value || OS_MBUF_PKTLEN(value.get()) != expected.size())
        return false;
    std::array<uint8_t, 128> flat{};
    uint16_t length = 0;
    if (expected.size() > flat.size() ||
        ble_hs_mbuf_to_flat(value.get(), flat.data(), flat.size(), &length) != 0)
        return false;
    return length == expected.size() && std::equal(expected.begin(), expected.end(), flat.begin());
}
} // namespace
esp_err_t BleKeyboard::init(std::string name) {
    if (instance_)
        return ESP_ERR_INVALID_STATE;
    instance_ = this;
    name_ = std::move(name);
    auto result = nimble_port_init();
    if (result != ESP_OK)
        return result;
    ble_npl_event_init(&control_event_, control, this);
    ble_hs_cfg.sync_cb = sync;
    ble_hs_cfg.reset_cb = reset;
    ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_KEYBOARD_ONLY;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 1;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    // Do not evict an existing host automatically when the one-bond store is full.
    ble_hs_cfg.store_status_cb = nullptr;
    ble_store_config_init();
    result = register_services();
    if (result != ESP_OK)
        return result;
    nimble_port_freertos_init(host_task);
    return ESP_OK;
}
void BleKeyboard::host_task(void *) {
    nimble_port_run();
    nimble_port_freertos_deinit();
}
void BleKeyboard::reset(int) {
    auto &self = *instance_;
    self.synced_ = false;
    self.connected_ = false;
    self.encrypted_ = false;
    self.report_subscribed_ = false;
    self.boot_subscribed_ = false;
    self.protocol_ = hid::report_protocol;
    self.pnp_present_ = false;
    self.passkey_pending_ = false;
    ++self.epoch_;
    self.reset_profile();
}
void BleKeyboard::refresh_bond() {
    ble_addr_t peers[1]{};
    int count = 0;
    if (ble_store_util_bonded_peers(peers, &count, 1) == 0 && count > 0) {
        peer_ = peers[0];
        bonded_ = true;
    } else
        bonded_ = false;
}
void BleKeyboard::sync() {
    auto &self = *instance_;
    if (ble_hs_util_ensure_addr(0) != 0 || ble_hs_id_infer_auto(0, &self.address_type_) != 0)
        return;
    self.refresh_bond();
    self.report_handle_ = self.handles_[static_cast<size_t>(hid::Attribute::input)];
    self.boot_handle_ = self.handles_[static_cast<size_t>(hid::Attribute::boot_input)];
    self.protocol_handle_ = self.handles_[static_cast<size_t>(hid::Attribute::protocol)];
    if (!self.report_handle_ || !self.boot_handle_ || !self.protocol_handle_) {
        ESP_LOGE("ble", "keyboard GATT reports not registered");
        return;
    }
    const auto pnp_handle = self.handles_[static_cast<size_t>(hid::Attribute::pnp)];
    self.pnp_present_ = pnp_handle && local_value_equals(pnp_handle, hid::pnp_value);
    for (size_t i = 0; i < hid::attribute_count; ++i) {
        const auto attribute = static_cast<hid::Attribute>(i);
        if (attribute == hid::Attribute::control)
            continue; // Write-only characteristic.
        const auto expected = self.profile_.read(attribute);
        if (!self.handles_[i] || !local_value_equals(self.handles_[i], expected)) {
            ESP_LOGE("ble", "HID profile readback failed: %.*s",
                     int(hid::attribute_name(attribute).size()),
                     hid::attribute_name(attribute).data());
            return;
        }
    }
    const ble_uuid16_t service_uuid = BLE_UUID16_INIT(0x1812);
    const ble_uuid16_t map_uuid = BLE_UUID16_INIT(0x2a4b);
    const ble_uuid16_t invalid_external = BLE_UUID16_INIT(0x2907);
    uint16_t unexpected = 0;
    if (ble_gatts_find_dsc(&service_uuid.u, &map_uuid.u, &invalid_external.u, &unexpected) == 0) {
        ESP_LOGE("ble", "Unexpected External Report Reference in keyboard-only map");
        return;
    }
    self.synced_ = true;
    ESP_LOGI("ble",
             "HID profile ready: PnP=0x%04x report=%u boot=%u protocol=%u bytes=%u external=none "
             "security=encrypted",
             pnp_handle, self.report_handle_, self.boot_handle_, self.protocol_handle_,
             unsigned(Report{}.size()));
    ble_svc_gatt_changed(1, 0xffff);
    // New hosts require an explicit web pairing window, including first boot.
    self.advertise();
}
bool BleKeyboard::pairing_open() const {
    return esp_timer_get_time() < pair_until_;
}
void BleKeyboard::advertise() {
    if (!synced_ || connected_)
        return;
    if (ble_gap_adv_active())
        ble_gap_adv_stop();
    ble_hs_adv_fields fields{};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.appearance = hid::keyboard_appearance;
    fields.appearance_is_present = 1;
    ble_uuid16_t hid_uuid = BLE_UUID16_INIT(0x1812);
    fields.uuids16 = &hid_uuid;
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;
    if (ble_gap_adv_set_fields(&fields) != 0)
        return;
    ble_hs_adv_fields response{};
    response.name = reinterpret_cast<const uint8_t *>(name_.c_str());
    response.name_len = name_.size();
    response.name_is_complete = 1;
    if (ble_gap_adv_rsp_set_fields(&response) != 0)
        return;
    ble_gap_adv_params params{};
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    params.itvl_min = BLE_GAP_ADV_ITVL_MS(30);
    params.itvl_max = BLE_GAP_ADV_ITVL_MS(50);
    const int rc = ble_gap_adv_start(address_type_, nullptr, BLE_HS_FOREVER, &params, gap, this);
    if (rc)
        ESP_LOGW("ble", "advertising error=%d", rc);
}
int BleKeyboard::gap(ble_gap_event *event, void *arg) {
    auto &self = *static_cast<BleKeyboard *>(arg);
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT: {
        if (event->connect.status != 0) {
            self.advertise();
            break;
        }
        self.connection_ = event->connect.conn_handle;
        self.connected_ = true;
        self.encrypted_ = false;
        self.protocol_ = hid::report_protocol;
        ++self.epoch_;
        self.report_subscribed_ = false;
        self.boot_subscribed_ = false;
        self.reset_profile();
        ble_gap_conn_desc desc{};
        if (ble_gap_conn_find(self.connection_, &desc) != 0)
            break;
        self.refresh_bond();
        bool allowed = self.bonded_ ? desc.peer_id_addr.type == self.peer_.type &&
                                          std::memcmp(desc.peer_id_addr.val, self.peer_.val, 6) == 0
                                    : self.pairing_open();
        if (!allowed) {
            ble_gap_terminate(self.connection_, BLE_ERR_REM_USER_CONN_TERM);
            break;
        }
        ble_gap_security_initiate(self.connection_);
        break;
    }
    case BLE_GAP_EVENT_DISCONNECT:
        self.connected_ = false;
        self.encrypted_ = false;
        self.protocol_ = hid::report_protocol;
        self.report_subscribed_ = false;
        self.boot_subscribed_ = false;
        self.reset_profile();
        self.passkey_pending_ = false;
        self.submitted_passkey_ = -1;
        self.connection_ = BLE_HS_CONN_HANDLE_NONE;
        ++self.epoch_;
        self.refresh_bond();
        self.advertise();
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        self.advertise();
        break;
    case BLE_GAP_EVENT_ENC_CHANGE: {
        ble_gap_conn_desc desc{};
        const bool found = ble_gap_conn_find(event->enc_change.conn_handle, &desc) == 0;
        ESP_LOGI("ble", "HID link security status=%d encrypted=%d authenticated=%d bonded=%d",
                 event->enc_change.status, int(found && desc.sec_state.encrypted),
                 int(found && desc.sec_state.authenticated), int(found && desc.sec_state.bonded));
        if (event->enc_change.status == 0 && found && desc.sec_state.encrypted &&
            desc.sec_state.authenticated) {
            self.encrypted_ = true;
            self.passkey_pending_ = false;
            self.pair_until_ = 0;
            self.refresh_bond();
        } else {
            self.encrypted_ = false;
            ble_gap_terminate(self.connection_, BLE_ERR_AUTH_FAIL);
        }
        break;
    }
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == self.report_handle_)
            self.report_subscribed_ = event->subscribe.cur_notify != 0;
        if (event->subscribe.attr_handle == self.boot_handle_)
            self.boot_subscribed_ = event->subscribe.cur_notify != 0;
        ESP_LOGI("ble", "HID subscription handle=%u report=%d boot=%d mode=%u",
                 event->subscribe.attr_handle, int(self.report_subscribed_.load()),
                 int(self.boot_subscribed_.load()), unsigned(self.protocol_.load()));
        break;
    case BLE_GAP_EVENT_NOTIFY_TX:
        if (!event->notify_tx.indication && (event->notify_tx.attr_handle == self.report_handle_ ||
                                             event->notify_tx.attr_handle == self.boot_handle_)) {
            if (event->notify_tx.status == 0)
                ++self.tx_completed_;
            else {
                ++self.tx_errors_;
                ESP_LOGW("ble", "HID notification completion error=%d handle=%u",
                         event->notify_tx.status, event->notify_tx.attr_handle);
            }
        }
        break;
    case BLE_GAP_EVENT_REPEAT_PAIRING:
        return BLE_GAP_REPEAT_PAIRING_IGNORE;
    case BLE_GAP_EVENT_PASSKEY_ACTION:
        if (event->passkey.params.action == BLE_SM_IOACT_INPUT && self.pairing_open() &&
            !self.bonded_)
            self.passkey_pending_ = true;
        else
            ble_gap_terminate(self.connection_, BLE_ERR_AUTH_FAIL);
        break;
    default:
        break;
    }
    return 0;
}
void BleKeyboard::queue_control() {
    if (synced_)
        ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &control_event_);
}
void BleKeyboard::open_pairing() {
    request_pair_ = true;
    queue_control();
}
void BleKeyboard::clear_bond() {
    encrypted_ = false;
    ++epoch_;
    request_clear_ = true;
    queue_control();
}
bool BleKeyboard::provide_passkey(std::string_view value) {
    if (!passkey_pending_ || !pairing_open() || value.size() != 6)
        return false;
    int code = 0;
    for (auto c : value) {
        if (c < '0' || c > '9')
            return false;
        code = code * 10 + c - '0';
    }
    submitted_passkey_ = code;
    queue_control();
    return true;
}
void BleKeyboard::control(ble_npl_event *event) {
    auto &self = *static_cast<BleKeyboard *>(ble_npl_event_get_arg(event));
    if (self.request_clear_.exchange(false)) {
        self.pair_until_ = 0;
        self.passkey_pending_ = false;
        self.encrypted_ = false;
        if (self.connected_)
            ble_gap_terminate(self.connection_, BLE_ERR_REM_USER_CONN_TERM);
        ble_store_clear();
        self.refresh_bond();
    }
    if (self.request_pair_.exchange(false)) {
        self.refresh_bond();
        if (!self.bonded_)
            self.pair_until_ = esp_timer_get_time() + 120000000;
        self.advertise();
    }
    const int code = self.submitted_passkey_.exchange(-1);
    if (code >= 0 && self.passkey_pending_ && self.pairing_open()) {
        ble_sm_io io{};
        io.action = BLE_SM_IOACT_INPUT;
        io.passkey = static_cast<uint32_t>(code);
        if (ble_sm_inject_io(self.connection_, &io) == 0)
            self.passkey_pending_ = false;
    }
}
bool BleKeyboard::send(const Report &input) {
    if (!ready())
        return false;
    const auto mode = protocol_.load();
    const auto handle = mode == hid::boot_protocol ? boot_handle_ : report_handle_;
    {
        std::lock_guard lock(profile_mutex_);
        profile_.input(input);
    }
    auto *packet = ble_hs_mbuf_from_flat(input.data(), input.size());
    if (!packet) {
        ++tx_errors_;
        return false;
    }
    const auto rc = ble_gatts_notify_custom(connection_, handle, packet);
    if (rc != 0) {
        ++tx_errors_;
        ESP_LOGW("ble", "HID notification submit error=%d handle=%u", rc, handle);
    }
    return rc == 0;
}
void BleKeyboard::wait(unsigned milliseconds) {
    vTaskDelay(pdMS_TO_TICKS(milliseconds));
}
} // namespace tepy

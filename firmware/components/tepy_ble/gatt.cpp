#include "esp_app_desc.h"
#include "esp_log.h"
#include "host/ble_hs.h"
#include "services/bas/ble_svc_bas.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "tepy/ble.hpp"

namespace tepy {
namespace {
const ble_uuid16_t hid_uuid = BLE_UUID16_INIT(0x1812);
const ble_uuid16_t dis_uuid = BLE_UUID16_INIT(0x180a);
ble_gatt_chr_flags flags(uint16_t properties) {
    ble_gatt_chr_flags value = 0;
    if (properties & hid::Read)
        value |= BLE_GATT_CHR_F_READ;
    if (properties & hid::Write)
        value |= BLE_GATT_CHR_F_WRITE;
    if (properties & hid::WriteWithoutResponse)
        value |= BLE_GATT_CHR_F_WRITE_NO_RSP;
    if (properties & hid::Notify)
        value |= BLE_GATT_CHR_F_NOTIFY;
    if (properties & hid::ReadEncrypted)
        value |= BLE_GATT_CHR_F_READ_ENC;
    if (properties & hid::WriteEncrypted)
        value |= BLE_GATT_CHR_F_WRITE_ENC;
    if (properties & hid::NotifyEncrypted)
        value |= BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC;
    return value;
}
} // namespace
esp_err_t BleKeyboard::register_services() {
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_svc_bas_init();
    ble_svc_bas_battery_level_set(100);
    if (ble_svc_gap_device_name_set(name_.c_str()) != 0 ||
        ble_svc_gap_device_appearance_set(hid::keyboard_appearance) != 0)
        return ESP_FAIL;
    profile_.identity(name_, esp_app_get_description()->version);
    for (size_t i = 0; i < bindings_.size(); ++i) {
        bindings_[i] = {this, static_cast<hid::Attribute>(i)};
        uuids_[i].u.type = BLE_UUID_TYPE_16;
    }
    const auto configure = [&](ble_gatt_chr_def &target, const hid::Characteristic &definition) {
        const auto i = static_cast<size_t>(definition.value);
        uuids_[i].value = definition.uuid;
        target.uuid = &uuids_[i].u;
        target.access_cb = access;
        target.arg = &bindings_[i];
        target.flags = flags(definition.properties);
        target.val_handle = &handles_[i];
        if (definition.reference != hid::Attribute::count) {
            const auto ref = static_cast<size_t>(definition.reference);
            uuids_[ref].value = hid::reference_uuid;
            auto &descriptors = definition.value == hid::Attribute::input ? input_descriptors_
                                                                          : output_descriptors_;
            descriptors[0].uuid = &uuids_[ref].u;
            descriptors[0].att_flags =
                BLE_ATT_F_READ |
                ((hid::reference_properties & hid::ReadEncrypted) ? BLE_ATT_F_READ_ENC : 0);
            descriptors[0].access_cb = access;
            descriptors[0].arg = &bindings_[ref];
            target.descriptors = descriptors.data();
        }
    };
    for (size_t i = 0; i < hid::characteristics.size(); ++i)
        configure(hid_characteristics_[i], hid::characteristics[i]);
    for (size_t i = 0; i < hid::device_information.size(); ++i)
        configure(dis_characteristics_[i], hid::device_information[i]);
    services_[0].type = BLE_GATT_SVC_TYPE_PRIMARY;
    services_[0].uuid = &dis_uuid.u;
    services_[0].characteristics = dis_characteristics_.data();
    services_[1].type = BLE_GATT_SVC_TYPE_PRIMARY;
    services_[1].uuid = &hid_uuid.u;
    services_[1].characteristics = hid_characteristics_.data();
    ble_hs_cfg.gatts_register_cb = registered;
    ble_hs_cfg.gatts_register_arg = this;
    if (ble_gatts_count_cfg(services_.data()) != 0 || ble_gatts_add_svcs(services_.data()) != 0)
        return ESP_FAIL;
    return ESP_OK;
}
void BleKeyboard::registered(ble_gatt_register_ctxt *context, void *arg) {
    auto &self = *static_cast<BleKeyboard *>(arg);
    void *binding = nullptr;
    uint16_t handle = 0;
    if (context->op == BLE_GATT_REGISTER_OP_CHR) {
        binding = context->chr.chr_def->arg;
        handle = context->chr.val_handle;
    } else if (context->op == BLE_GATT_REGISTER_OP_DSC) {
        binding = context->dsc.dsc_def->arg;
        handle = context->dsc.handle;
    }
    // GAP/GATT/BAS use their own callback arguments. Only inspect our bindings.
    for (size_t i = 0; i < self.bindings_.size(); ++i)
        if (binding == &self.bindings_[i]) {
            self.handles_[i] = handle;
            break;
        }
}
int BleKeyboard::access(uint16_t connection, uint16_t handle, ble_gatt_access_ctxt *context,
                        void *arg) {
    auto &binding = *static_cast<Binding *>(arg);
    auto &self = *binding.owner;
    const auto attribute = binding.attribute;
    const auto index = static_cast<size_t>(attribute);
    if (connection != BLE_HS_CONN_HANDLE_NONE && !self.adopt_connection(connection, "gatt"))
        return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    if (context->op == BLE_GATT_ACCESS_OP_READ_CHR || context->op == BLE_GATT_ACCESS_OP_READ_DSC) {
        std::lock_guard lock(self.profile_mutex_);
        const auto value = self.profile_.read(attribute);
        if (value.empty())
            return BLE_ATT_ERR_READ_NOT_PERMITTED;
        if (connection != BLE_HS_CONN_HANDLE_NONE) {
            const auto previous = self.host_read_mask_.fetch_or(uint32_t{1} << index);
            if (!(previous & (uint32_t{1} << index)))
                ESP_LOGI("ble", "HID peer read %.*s handle=%u length=%u",
                         int(hid::attribute_name(attribute).size()),
                         hid::attribute_name(attribute).data(), handle, unsigned(value.size()));
        }
        return os_mbuf_append(context->om, value.data(), value.size()) == 0
                   ? 0
                   : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (context->op != BLE_GATT_ACCESS_OP_WRITE_CHR)
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    if (OS_MBUF_PKTLEN(context->om) != 1)
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    uint8_t byte = 0;
    uint16_t length = 0;
    if (ble_hs_mbuf_to_flat(context->om, &byte, 1, &length) != 0 || length != 1)
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    hid::WriteError error;
    {
        std::lock_guard lock(self.profile_mutex_);
        error = self.profile_.write(attribute, {&byte, 1});
        if (error == hid::WriteError::none && attribute == hid::Attribute::protocol)
            self.protocol_ = self.profile_.protocol();
    }
    switch (error) {
    case hid::WriteError::not_permitted:
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    case hid::WriteError::length:
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    case hid::WriteError::value:
        return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
    default:
        break;
    }
    if (attribute == hid::Attribute::protocol)
        ESP_LOGI("ble", "HID protocol mode=%u", unsigned(self.protocol_.load()));
    return 0;
}
void BleKeyboard::reset_profile() {
    std::lock_guard lock(profile_mutex_);
    profile_.reset_connection();
    protocol_ = hid::report_protocol;
    host_read_mask_ = 0;
    tx_completed_ = 0;
    tx_errors_ = 0;
}
} // namespace tepy

#include "tepy/hid_profile.hpp"

namespace tepy::hid {
namespace {
std::span<const uint8_t> bytes(std::string_view value) {
    return {reinterpret_cast<const uint8_t *>(value.data()), value.size()};
}
} // namespace
std::string_view attribute_name(Attribute attribute) {
    constexpr std::array<std::string_view, attribute_count> names{
        "information", "report_map",   "control",     "protocol",        "input",
        "output",      "boot_input",   "boot_output", "input_reference", "output_reference",
        "pnp",         "manufacturer", "model",       "serial",          "firmware"};
    const auto index = static_cast<size_t>(attribute);
    return index < names.size() ? names[index] : "unknown";
}
void Profile::reset_connection() {
    input_ = {};
    leds_[0] = 0;
    protocol_[0] = report_protocol;
    control_[0] = 1;
}
std::span<const uint8_t> Profile::read(Attribute attribute) const {
    switch (attribute) {
    case Attribute::information:
        return information;
    case Attribute::report_map:
        return report_map;
    case Attribute::input_reference:
        return input_reference;
    case Attribute::output_reference:
        return output_reference;
    case Attribute::pnp:
        return pnp_value;
    case Attribute::input:
    case Attribute::boot_input:
        return input_;
    case Attribute::output:
    case Attribute::boot_output:
        return leds_;
    case Attribute::protocol:
        return protocol_;
    case Attribute::manufacturer:
        return bytes("Tepy");
    case Attribute::model:
    case Attribute::serial:
        return bytes(name_);
    case Attribute::firmware:
        return bytes(firmware_);
    default:
        return {};
    }
}
WriteError Profile::write(Attribute attribute, std::span<const uint8_t> value) {
    if (attribute != Attribute::output && attribute != Attribute::boot_output &&
        attribute != Attribute::control && attribute != Attribute::protocol)
        return WriteError::not_permitted;
    if (value.size() != 1)
        return WriteError::length;
    if (attribute == Attribute::protocol || attribute == Attribute::control) {
        if (value[0] > 1)
            return WriteError::value;
        if (attribute == Attribute::protocol)
            protocol_[0] = value[0];
        else
            control_[0] = value[0];
    } else
        leds_[0] = value[0];
    return WriteError::none;
}
} // namespace tepy::hid

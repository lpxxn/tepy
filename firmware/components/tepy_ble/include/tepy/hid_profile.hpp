#pragma once
#include "tepy/core.hpp"
#include <array>
#include <cstdint>
#include <span>
#include <string_view>

namespace tepy::hid {
inline constexpr uint8_t report_id = 1;
inline constexpr uint8_t boot_protocol = 0;
inline constexpr uint8_t report_protocol = 1;
inline constexpr uint16_t keyboard_appearance = 0x03c1;
inline constexpr uint16_t vendor_id = 0x303a;
inline constexpr uint16_t product_id = 0x4001;
inline constexpr uint16_t device_version = 0x0103;

// DIS PnP ID is exactly seven binary bytes, serialized with an explicit length.
inline constexpr std::array<uint8_t, 7> pnp_value{2,
                                                  vendor_id & 0xff,
                                                  vendor_id >> 8,
                                                  product_id & 0xff,
                                                  product_id >> 8,
                                                  device_version & 0xff,
                                                  device_version >> 8};

inline constexpr std::array<uint8_t, 4> information{0x11, 0x01, 0x00, 0x03};
inline constexpr std::array<uint8_t, 2> input_reference{report_id, 1};
inline constexpr std::array<uint8_t, 2> output_reference{report_id, 2};

enum class Attribute : uint8_t {
    information,
    report_map,
    control,
    protocol,
    input,
    output,
    boot_input,
    boot_output,
    input_reference,
    output_reference,
    pnp,
    manufacturer,
    model,
    serial,
    firmware,
    count
};
inline constexpr size_t attribute_count = static_cast<size_t>(Attribute::count);
enum Property : uint16_t {
    Read = 0x02,
    WriteWithoutResponse = 0x04,
    Write = 0x08,
    Notify = 0x10,
    ReadEncrypted = 0x100,
    WriteEncrypted = 0x200,
    NotifyEncrypted = 0x400
};
struct Characteristic {
    Attribute value;
    uint16_t uuid;
    uint16_t properties;
    Attribute reference{Attribute::count};
};
// macOS initializes its HID device after reading the map and subscribing. Gate
// the whole HID service, including CCCD writes, until SMP has encrypted the link.
// Protecting only input reads does not protect metadata reads or CCCD writes.
inline constexpr uint16_t reference_properties = Read | ReadEncrypted;
inline constexpr std::array<Characteristic, 8> characteristics{
    {{Attribute::information, 0x2a4a, Read | ReadEncrypted},
     {Attribute::report_map, 0x2a4b, Read | ReadEncrypted},
     {Attribute::control, 0x2a4c, WriteWithoutResponse | WriteEncrypted},
     {Attribute::protocol, 0x2a4e, Read | WriteWithoutResponse | ReadEncrypted | WriteEncrypted},
     {Attribute::input, 0x2a4d, Read | Notify | ReadEncrypted | NotifyEncrypted,
      Attribute::input_reference},
     {Attribute::output, 0x2a4d,
      Read | Write | WriteWithoutResponse | ReadEncrypted | WriteEncrypted,
      Attribute::output_reference},
     {Attribute::boot_input, 0x2a22, Read | Notify | ReadEncrypted | NotifyEncrypted},
     {Attribute::boot_output, 0x2a32,
      Read | Write | WriteWithoutResponse | ReadEncrypted | WriteEncrypted}}};
inline constexpr std::array<Characteristic, 5> device_information{
    {{Attribute::pnp, 0x2a50, Read},
     {Attribute::manufacturer, 0x2a29, Read},
     {Attribute::model, 0x2a24, Read},
     {Attribute::serial, 0x2a25, Read},
     {Attribute::firmware, 0x2a26, Read}}};
inline constexpr uint16_t reference_uuid = 0x2908;
// There is deliberately no 0x2907 External Report Reference: our map describes
// only reports in the HID service. Battery Level is a separate BAS value.

enum class WriteError { none, not_permitted, length, value };
std::string_view attribute_name(Attribute attribute);
class Profile {
  public:
    void identity(std::string_view name, std::string_view firmware) {
        name_ = name;
        firmware_ = firmware;
    }
    void reset_connection();
    std::span<const uint8_t> read(Attribute attribute) const;
    WriteError write(Attribute attribute, std::span<const uint8_t> bytes);
    void input(const Report &report) { input_ = report; }
    uint8_t protocol() const { return protocol_[0]; }

  private:
    std::string_view name_, firmware_;
    Report input_{};
    std::array<uint8_t, 1> leds_{0}, protocol_{report_protocol}, control_{1};
};

// Report ID belongs in descriptor 0x2908, not the eight-byte notification body.
inline constexpr auto report_map = std::to_array<uint8_t>(
    {0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, report_id, 0x05, 0x07, 0x19, 0xe0, 0x29,
     0xe7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95,      0x08, 0x81, 0x02, 0x95, 0x01,
     0x75, 0x08, 0x81, 0x01, 0x95, 0x05, 0x75, 0x01,      0x05, 0x08, 0x19, 0x01, 0x29,
     0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91,      0x01, 0x95, 0x06, 0x75, 0x08,
     0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00,      0x29, 0x65, 0x81, 0x00, 0xc0});

constexpr bool input_ready(bool connected, bool encrypted, uint8_t protocol, bool report_subscribed,
                           bool boot_subscribed) {
    return connected && encrypted &&
           ((protocol == report_protocol && report_subscribed) ||
            (protocol == boot_protocol && boot_subscribed));
}
} // namespace tepy::hid

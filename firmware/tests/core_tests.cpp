#include "esp_hid_common.h"
#include "tepy/core.hpp"
#include "tepy/hid_profile.hpp"
#include "tepy/json.hpp"
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>

using namespace tepy;
namespace {
unsigned checks = 0;
void check(bool condition, const char *label) {
    ++checks;
    if (!condition) {
        std::cerr << "FAIL: " << label << '\n';
        std::exit(1);
    }
}
constexpr auto session = "0123456789abcdef0123456789abcdef";
constexpr int64_t now = 1800000000000;
std::string make_command(std::string_view type, const cJSON *payload) {
    auto root = object();
    cJSON_AddNumberToObject(root.get(), "v", 1);
    cJSON_AddStringToObject(root.get(), "id", "test-1");
    cJSON_AddStringToObject(root.get(), "session", session);
    cJSON_AddNumberToObject(root.get(), "expires_at", now + 10000);
    cJSON_AddStringToObject(root.get(), "type", std::string(type).c_str());
    cJSON_AddItemToObject(root.get(), "payload", cJSON_Duplicate(payload, true));
    return stringify(root.get());
}
std::string typed(std::string_view value, bool enter = false) {
    auto payload = object();
    cJSON_AddStringToObject(payload.get(), "text", std::string(value).c_str());
    cJSON_AddBoolToObject(payload.get(), "press_enter", enter);
    return make_command("type_text", payload.get());
}
struct FakeKeyboard final : Keyboard {
    bool active = true;
    int failure = -1;
    int drop_wait = -1;
    unsigned waits = 0;
    std::vector<Report> reports;
    bool ready() const override { return active; }
    bool send(const Report &report) override {
        if (!active || static_cast<int>(reports.size()) == failure)
            return false;
        reports.push_back(report);
        return true;
    }
    void wait(unsigned ms) override {
        check(ms == 20, "key delay");
        if (static_cast<int>(++waits) == drop_wait)
            active = false;
    }
};
void mapping_tests() {
    for (int c = 32; c <= 126; ++c)
        check(ascii_stroke(static_cast<char>(c)).has_value(), "all ASCII printable mapped");
    for (int c = 0; c < 32; ++c)
        check(!ascii_stroke(static_cast<char>(c)), "control text rejected");
    check(!ascii_stroke(127) && !ascii_stroke(static_cast<char>(0xff)), "non printable rejected");
    // Independent HID reference vectors for the most error-prone US symbol positions.
    struct Vector {
        char value;
        uint8_t key;
        bool shift;
    };
    constexpr Vector vectors[]{
        {'a', 4, false},  {'A', 4, true},   {'0', 39, false},  {'1', 30, false},  {'+', 46, true},
        {'=', 46, false}, {'"', 52, true},  {'\'', 52, false}, {'\\', 49, false}, {'|', 49, true},
        {'~', 53, true},  {'`', 53, false}, {'@', 31, true},   {'(', 38, true},   {')', 39, true},
        {'[', 47, false}, {'{', 47, true},  {']', 48, false},  {'}', 48, true},   {'?', 56, true},
        {' ', 44, false}};
    for (auto v : vectors) {
        auto s = ascii_stroke(v.value);
        check(s && s->key == v.key && s->modifier == (v.shift ? 2 : 0), "HID symbol reference");
    }
    check(named_stroke("F12")->key == 69, "F12 code");
    check(named_stroke("ENTER")->key == 40, "enter code");
    check(!named_stroke("F13"), "unknown key");
    check(modifier("GUI") == 8 && modifier("ALT") == 4, "Mac modifiers");
}
void hid_profile_tests() {
    auto *parsed = esp_hid_parse_report_map(hid::report_map.data(), hid::report_map.size());
    check(parsed != nullptr, "actual SDK parses keyboard report descriptor");
    check(parsed->appearance == hid::keyboard_appearance, "SDK identifies keyboard appearance");
    check(parsed->usage == ESP_HID_USAGE_KEYBOARD, "SDK identifies keyboard usage");
    unsigned inputs = 0, outputs = 0;
    for (unsigned i = 0; i < parsed->reports_len; ++i) {
        const auto &report = parsed->reports[i];
        check(report.report_id == hid::report_id, "report reference ID agrees with descriptor");
        if (report.report_type == ESP_HID_REPORT_TYPE_INPUT) {
            ++inputs;
            check(report.value_len == sizeof(Report),
                  "report and boot inputs are exactly eight bytes");
        } else if (report.report_type == ESP_HID_REPORT_TYPE_OUTPUT) {
            ++outputs;
            check(report.value_len == 1, "LED output is one byte");
        }
    }
    check(inputs == 2 && outputs == 2, "report and boot keyboard formats present");
    std::free(parsed->reports);
    std::free(parsed);
    const uint8_t expected_pnp[]{2, 0x3a, 0x30, 0x01, 0x40, 0x05, 0x01};
    check(std::memcmp(expected_pnp, hid::pnp_value.data(), 7) == 0,
          "PnP ID is little endian seven-byte wire data");
    check(hid::pnp_value.size() == 7, "PnP is exactly seven raw bytes without a terminator");
    check(!hid::input_ready(true, true, hid::report_protocol, false, true),
          "boot-only subscription cannot enable report protocol");
    check(!hid::input_ready(true, true, hid::boot_protocol, true, false),
          "report-only subscription cannot enable boot protocol");
    check(hid::input_ready(true, true, hid::report_protocol, true, false),
          "report protocol uses its own CCCD");
    check(hid::input_ready(true, true, hid::boot_protocol, false, true),
          "boot protocol uses its own CCCD");
    check(!hid::input_ready(false, true, hid::report_protocol, true, true),
          "disconnected profile is not ready");
    check(!hid::input_ready(true, false, hid::report_protocol, true, true),
          "unencrypted profile is not ready");
    check(!hid::input_ready(true, true, 2, true, true), "unknown protocol is not ready");
    check(hid::accept_security_event(0, true, true, true, false),
          "fresh authenticated pairing accepted");
    check(hid::accept_security_event(0, true, true, true, true), "bonded encryption restored");
    check(hid::accept_security_event(13, true, true, true, true),
          "redundant SMP timeout preserves an authenticated encrypted bonded link");
    check(!hid::accept_security_event(13, true, false, true, true),
          "timeout cannot waive encryption");
    check(!hid::accept_security_event(13, true, true, false, true),
          "timeout cannot waive MITM authentication");
    check(!hid::accept_security_event(13, true, true, true, false),
          "unbonded timeout is a failure");
    check(!hid::accept_security_event(13, false, true, true, true),
          "stale connection cannot waive timeout");
    check(!hid::accept_security_event(1028, true, true, true, true),
          "confirm mismatch remains fatal");
    check(!hid::accept_security_event(0, true, true, false, true),
          "encrypted unauthenticated pairing rejected");
    check(!hid::accept_security_event(0, true, false, true, true),
          "unencrypted success event rejected");
}
void gatt_contract_tests() {
    using A = hid::Attribute;
    hid::Profile profile;
    profile.identity("Tepy-test", "0.1.5");
    const std::array<uint8_t, 4> info{0x11, 0x01, 0, 3};
    const auto equals = [](std::span<const uint8_t> left, std::span<const uint8_t> right) {
        return left.size() == right.size() && std::equal(left.begin(), left.end(), right.begin());
    };
    check(equals(profile.read(A::information), info),
          "HID Information is four bytes including remote wake flags");
    check(profile.read(A::pnp).size() == 7, "actual PnP accessor returns seven bytes");
    check(equals(profile.read(A::report_map), hid::report_map),
          "GATT Report Map equals parsed map");
    check(equals(profile.read(A::input_reference), std::array<uint8_t, 2>{1, 1}),
          "input reference contains report ID and input type");
    check(equals(profile.read(A::output_reference), std::array<uint8_t, 2>{1, 2}),
          "output reference contains report ID and output type");
    check(equals(profile.read(A::input), Report{}), "initial report input is eight zeros");
    check(equals(profile.read(A::boot_input), Report{}), "initial boot input is eight zeros");
    check(profile.read(A::output).size() == 1 && profile.read(A::output)[0] == 0,
          "initial LED report is one zero");
    check(profile.read(A::boot_output).size() == 1, "initial boot LED report length");
    check(profile.read(A::model).size() == 9 && profile.read(A::model)[0] == 'T',
          "readable Tepy model identity");
    check(profile.read(A::firmware).size() == 5, "readable firmware version");
    check(profile.read(A::control).empty(), "control point is write-only");
    Report pressed{};
    pressed[2] = 4;
    profile.input(pressed);
    check(equals(profile.read(A::input), pressed), "read report retains current input value");
    check(equals(profile.read(A::boot_input), pressed),
          "boot and report share the same eight-byte body");
    const uint8_t zero = 0, one = 1, two = 2, leds = 3;
    check(profile.write(A::protocol, {&two, 1}) == hid::WriteError::value,
          "invalid protocol rejected");
    check(profile.protocol() == 1, "invalid protocol does not mutate state");
    check(profile.write(A::protocol, {}) == hid::WriteError::length,
          "zero-length protocol rejected");
    check(profile.write(A::protocol, {&zero, 1}) == hid::WriteError::none &&
              profile.protocol() == 0,
          "boot protocol accepted");
    check(profile.write(A::protocol, {&one, 1}) == hid::WriteError::none && profile.protocol() == 1,
          "report protocol accepted");
    check(profile.write(A::input, {&one, 1}) == hid::WriteError::not_permitted,
          "remote input writes prohibited");
    check(profile.write(A::output, {&leds, 1}) == hid::WriteError::none &&
              profile.read(A::boot_output)[0] == 3,
          "LED writes visible through boot accessor");
    check(profile.write(A::boot_output, {&zero, 1}) == hid::WriteError::none &&
              profile.read(A::output)[0] == 0,
          "boot LED writes visible through report accessor");
    check(profile.write(A::control, {&two, 1}) == hid::WriteError::value,
          "invalid control point rejected");
    check(profile.write(A::control, {&zero, 1}) == hid::WriteError::none, "suspend accepted");
    profile.reset_connection();
    check(equals(profile.read(A::input), Report{}) && profile.protocol() == 1,
          "disconnect resets key and protocol state");
    unsigned references = 0;
    for (const auto &definition : hid::characteristics) {
        check(definition.uuid != 0x2907,
              "no service UUID masquerades as external report characteristic");
        if (definition.properties & hid::Read)
            check(definition.properties & hid::ReadEncrypted,
                  "all HID reads wait for link encryption before host initialization");
        if (definition.properties & (hid::Write | hid::WriteWithoutResponse))
            check(definition.properties & hid::WriteEncrypted,
                  "all HID writes require link encryption");
        if (definition.properties & hid::Notify)
            check(definition.properties & hid::NotifyEncrypted,
                  "CCCD writes require encryption independently of input-read permissions");
        if (definition.reference != A::count) {
            ++references;
            check(hid::reference_uuid == 0x2908, "only Report Reference descriptors emitted");
        }
        if (definition.value == A::input)
            check((definition.properties & 0x1f) == 0x12,
                  "input characteristic is read/notify without write");
        if (definition.value == A::output)
            check((definition.properties & 0x1f) == 0x0e, "output characteristic properties");
        if (definition.value == A::control)
            check((definition.properties & 0x1f) == 0x04,
                  "control point only write without response");
        if (definition.value == A::protocol)
            check((definition.properties & 0x1f) == 0x06, "protocol properties follow HOGP");
    }
    check(references == 2,
          "only keyboard input and output references, no external battery reference");
    check(hid::reference_properties & hid::ReadEncrypted,
          "Report Reference descriptors wait for link encryption");
    bool pnp = false;
    for (const auto &d : hid::device_information)
        if (d.value == A::pnp)
            pnp = d.uuid == 0x2a50 && d.properties == hid::Read;
    check(pnp, "Device Information publishes readable PnP ID");
}
void parser_tests() {
    Command command;
    auto payload = object();
    auto input = make_command("wake", payload.get());
    check(parse_command(input, command).empty(), "parse wake");
    check(command.type == CommandType::wake, "wake kind");
    check(parse_command(input + "garbage", command) == "invalid_command", "trailing garbage");
    check(parse_command(input + " \n", command).empty(), "trailing whitespace");
    check(parse_command("{}", command) == "invalid_command", "missing fields");
    check(parse_command(std::string(4097, 'x'), command) == "invalid_command", "payload bound");
    check(parse_command(std::string(40, '[') + "0" + std::string(40, ']'), command) ==
              "invalid_command",
          "deep JSON rejected without stack overflow");
    check(parse_command(typed("hello + = \\\""), command).empty(), "symbols text");
    check(parse_command(typed(std::string(512, 'a')), command).empty(), "512 text accepted");
    check(parse_command(typed(std::string(513, 'a')), command) == "invalid_command", "text bound");
    check(parse_command(typed(""), command) == "invalid_command", "empty text");
    check(parse_command(typed("line\nbreak"), command) == "unsupported_character",
          "newline text rejected");
    check(parse_command(typed("\xe4\xb8\xad"), command) == "unsupported_character",
          "Chinese rejected");
    auto bad = parse_json(input);
    cJSON_AddNumberToObject(bad.get(), "v", 1);
    check(parse_command(stringify(bad.get()), command) == "invalid_command",
          "duplicate JSON fields");
    bad = parse_json(input);
    cJSON_SetNumberValue(field(bad.get(), "v"), 2);
    check(parse_command(stringify(bad.get()), command) == "invalid_command", "version rejected");
    bad = parse_json(input);
    cJSON_AddBoolToObject(bad.get(), "unknown", true);
    check(parse_command(stringify(bad.get()), command) == "invalid_command", "unknown root field");
    bad = parse_json(input);
    cJSON_SetNumberValue(field(bad.get(), "expires_at"), 1.5);
    check(parse_command(stringify(bad.get()), command) == "invalid_command",
          "fractional timestamp");
    auto text_input = typed("x");
    auto pos = text_input.find("\"x\"");
    text_input.replace(pos, 3, "\"x\\u0000y\"");
    check(parse_command(text_input, command) == "invalid_command", "escaped null rejected");
    auto key = object();
    cJSON_AddStringToObject(key.get(), "key", "a");
    auto *mods = cJSON_AddArrayToObject(key.get(), "modifiers");
    cJSON_AddItemToArray(mods, cJSON_CreateString("GUI"));
    check(parse_command(make_command("key", key.get()), command).empty() &&
              command.stroke.modifier == 8,
          "key with command modifier");
    cJSON_AddItemToArray(mods, cJSON_CreateString("GUI"));
    check(parse_command(make_command("key", key.get()), command) == "invalid_command",
          "duplicate modifier");
    command.clear();
    check(command.text[0] == 0 && command.id[0] == 0 && command.text_length == 0, "clear command");
}
void gate_tests() {
    Command cmd;
    auto payload = object();
    check(parse_command(make_command("wake", payload.get()), cmd).empty(), "gate command");
    check(validate_envelope(cmd, session, now, true, false).empty(), "valid envelope");
    check(validate_envelope(cmd, session, now, false, false) == "time_not_ready", "unsynced");
    check(validate_envelope(cmd, session, now, true, true) == "retained_command", "retained");
    check(validate_envelope(cmd, "another", now, true, false) == "old_session", "session");
    check(validate_envelope(cmd, session, cmd.expires_at, true, false) == "expired",
          "expiry boundary");
    cmd.expires_at = now + 30000;
    check(validate_envelope(cmd, session, now, true, false).empty(), "30 second limit");
    ++cmd.expires_at;
    check(validate_envelope(cmd, session, now, true, false) == "expired", "future limit");
    cmd.expires_at = now + 10000;
    Deduplicator dedup;
    check(dedup.remember(cmd, now).empty(), "first id");
    check(dedup.remember(cmd, now) == "duplicate", "repeat id");
    for (unsigned i = 1; i < 128; ++i) {
        snprintf(cmd.id.data(), cmd.id.size(), "req-%u", i);
        check(dedup.remember(cmd, now).empty(), "fill cache");
    }
    snprintf(cmd.id.data(), cmd.id.size(), "overflow");
    check(dedup.remember(cmd, now) == "dedup_full", "do not evict active ids");
    check(dedup.remember(cmd, now + 10000).empty(), "reuse expired slot");
    dedup.clear();
    check(dedup.remember(cmd, now).empty(), "clear for reconnect");
}
void executor_tests() {
    Command cmd;
    check(parse_command(typed("aa+", true), cmd).empty(), "execution parse");
    FakeKeyboard keyboard;
    check(execute(cmd, keyboard, 20).empty(), "text execution");
    check(keyboard.reports.size() == 8, "3 chars plus enter with releases");
    check(keyboard.reports[0][2] == 4 && keyboard.reports[1] == Report{} &&
              keyboard.reports[2][2] == 4,
          "repeat key released");
    check(keyboard.reports[4][0] == 2 && keyboard.reports[4][2] == 46, "plus output");
    check(keyboard.reports[6][2] == 40 && keyboard.reports[7] == Report{}, "enter last");
    FakeKeyboard offline;
    offline.active = false;
    check(execute(cmd, offline, 20) == "ble_not_ready" && offline.reports.empty(),
          "offline no report");
    FakeKeyboard drop;
    drop.drop_wait = 1;
    check(execute(cmd, drop, 20) == "interrupted" && drop.reports.size() == 1,
          "disconnect stops text");
    FakeKeyboard cancel;
    bool valid = true;
    check(execute(cmd, cancel, 20,
                  [&] {
                      if (cancel.waits > 0)
                          valid = false;
                      return valid;
                  }) == "interrupted",
          "session loss cancels");
    check(cancel.reports.size() == 3 && cancel.reports[1] == Report{} &&
              cancel.reports[2] == Report{},
          "release on session loss");
    FakeKeyboard failure;
    failure.failure = 0;
    check(execute(cmd, failure, 20) == "interrupted", "transport failure");
    auto payload = object();
    parse_command(make_command("wake", payload.get()), cmd);
    FakeKeyboard wake;
    check(execute(cmd, wake, 20).empty() && wake.reports[0][0] == 2 && wake.reports[0][2] == 0,
          "wake shift without text");
    cmd.type = CommandType::text;
    cmd.text_length = 2;
    cmd.text[0] = 'a';
    cmd.text[1] = '\n';
    FakeKeyboard invalid;
    check(execute(cmd, invalid, 20) == "unsupported_character" && invalid.reports.empty(),
          "typed callers fully validated before output");
    cmd.text_length = 513;
    check(execute(cmd, invalid, 20) == "invalid_command", "typed caller length bound");
}
} // namespace
int main(int argc, char **argv) {
    if (argc == 2) { // Validate a protocol fixture using the production parser.
        Command command;
        std::string input = argv[1];
        return parse_command(input, command).empty() ? 0 : 1;
    }
    mapping_tests();
    hid_profile_tests();
    gatt_contract_tests();
    parser_tests();
    gate_tests();
    executor_tests();
    std::cout << "PASS: " << checks << " core checks\n";
    return 0;
}

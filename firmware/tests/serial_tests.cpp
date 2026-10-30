#include "tepy/json.hpp"
#include "tepy/serial_protocol.hpp"
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {
unsigned checks = 0;
void check(bool value, const char *name) {
    ++checks;
    if (!value) {
        std::cerr << "FAILED: " << name << '\n';
        std::exit(1);
    }
}
} // namespace
int main() {
    using namespace tepy;
    std::vector<std::string> messages;
    serial::Decoder decoder([&](std::string_view value) { messages.emplace_back(value); });
    decoder.feed("boot logs\n@tep");
    decoder.feed("y:{\"v\":1}\r\n@tepy:{}\n");
    check(messages.size() == 2 && messages[0] == "{\"v\":1}", "fragmented frames and CRLF");
    decoder.feed("@tepy:" + std::string(serial::max_json_bytes + 2, 'x') + "@tepy:{}\n@tepy:{}\n");
    check(messages.size() == 3, "oversize line discarded until newline");
    decoder.feed("@tepy:partial");
    decoder.reset();
    decoder.feed("@tepy:{}\n");
    check(messages.size() == 4 && messages.back() == "{}", "timeout reset permits next frame");
    const std::string valid =
        R"({"v":1,"id":"request-1","method":"config.patch","token":"ExampleAdminTokenOnly0000","params":{"v":1,"wifi":{"password":"examplepass"}}})";
    unsigned calls = 0;
    const auto authenticate = [](std::string_view token) {
        return token == "ExampleAdminTokenOnly0000";
    };
    const auto dispatch = [&](std::string_view method, std::string_view params) {
        ++calls;
        check(method == "config.patch", "method forwarded");
        auto parsed = parse_json(params);
        check(text(field(field(parsed.get(), "wifi"), "password")) == "examplepass",
              "params forwarded without loss");
        return R"({"ok":true,"reboot_required":true})";
    };
    auto response = serial::reply(valid, authenticate, dispatch);
    auto parsed = parse_json(response);
    check(cJSON_IsTrue(field(parsed.get(), "ok")) && calls == 1, "authenticated dispatch");
    check(response.find("ExampleAdmin") == std::string::npos &&
              response.find("examplepass") == std::string::npos,
          "no credential reflection");
    check(text(field(parsed.get(), "id")) == "request-1" && field(parsed.get(), "result"),
          "correlated result");
    const auto rejected = [&](std::string request, std::string_view code) {
        const auto old_calls = calls;
        auto result = parse_json(serial::reply(request, authenticate, dispatch));
        check(cJSON_IsFalse(field(result.get(), "ok")) &&
                  text(field(result.get(), "error")) == code && calls == old_calls,
              "invalid request never dispatched");
    };
    rejected("{}", "invalid_request");
    rejected("[]", "invalid_request");
    rejected("not json", "invalid_request");
    rejected(valid + "{}", "invalid_request");
    auto modified = valid;
    modified.replace(modified.find("\"v\":1"), 5, "\"v\":2");
    rejected(modified, "unsupported_version");
    modified = valid;
    modified.replace(modified.find("ExampleAdminTokenOnly0000"), 24, "wrong");
    rejected(modified, "unauthorized");
    modified = valid;
    modified.insert(1, "\"v\":1,");
    rejected(modified, "invalid_request");
    modified = valid;
    modified.insert(1, "\"extra\":1,");
    rejected(modified, "invalid_request");
    modified = valid;
    modified.replace(modified.find("request-1"), 9, "bad id");
    rejected(modified, "invalid_request");
    rejected(std::string(serial::max_json_bytes + 1, 'x'), "frame_too_large");
    auto failure = parse_json(
        serial::reply(valid, authenticate, [](auto, auto) { return R"({"error":"busy"})"; }));
    check(text(field(failure.get(), "error")) == "busy" && !field(failure.get(), "result"),
          "service error propagated");
    auto broken = parse_json(serial::reply(valid, authenticate, [](auto, auto) { return "[]"; }));
    check(text(field(broken.get(), "error")) == "internal_error",
          "invalid service response rejected");
    std::cout << "PASS: " << checks << " serial protocol checks\n";
}

#include "tepy/management.hpp"
#include "tepy/json.hpp"

namespace tepy {
namespace {
std::string error(std::string_view code) {
    auto result = object();
    cJSON_AddStringToObject(result.get(), "error", std::string(code).c_str());
    return stringify(result.get());
}
struct Maintenance {
    Management &owner;
    ~Maintenance() { owner.end_maintenance(); }
};
} // namespace
std::string Management::dispatch(std::string_view method, std::string_view params) {
    auto body = parse_json(params);
    if (!body || !cJSON_IsObject(body.get()))
        return error("invalid_body");
    if (method == "config.patch") {
        const auto issue = services_.config.patch(params);
        return issue.empty() ? "{\"ok\":true,\"reboot_required\":true}" : error(issue);
    }
    if (method == "ble.passkey") {
        if (!fields_only(body.get(), {"passkey"}) ||
            !services_.ble.provide_passkey(text(field(body.get(), "passkey"))))
            return error("invalid_passkey");
        return "{\"ok\":true}";
    }
    if (!fields_only(body.get(), {}))
        return error("unexpected_body");
    if (method == "status.get")
        return services_.status();
    if (method == "config.get")
        return services_.config.public_json();
    if (method == "wifi.scan")
        return services_.network.scan();
    if (method != "ble.pair" && method != "ble.clear" && method != "reboot")
        return error("unknown_method");
    if (!begin_maintenance())
        return error("busy");
    Maintenance guard{*this};
    if (method == "ble.pair") {
        if (services_.ble.bonded())
            return error("already_bonded");
        services_.ble.open_pairing();
    } else if (method == "ble.clear")
        services_.ble.clear_bond();
    else
        reboot();
    return "{\"ok\":true}";
}
} // namespace tepy

#include "tepy/core.hpp"
#include "tepy/json.hpp"
#include <cmath>
#include <cstring>

namespace tepy {
std::optional<Stroke> ascii_stroke(char ch) {
    if (ch >= 'a' && ch <= 'z')
        return Stroke{0, static_cast<uint8_t>(4 + ch - 'a')};
    if (ch >= 'A' && ch <= 'Z')
        return Stroke{2, static_cast<uint8_t>(4 + ch - 'A')};
    if (ch >= '1' && ch <= '9')
        return Stroke{0, static_cast<uint8_t>(30 + ch - '1')};
    if (ch == '0')
        return Stroke{0, 39};
    constexpr std::string_view plain = " -=[]\\;'`,./";
    constexpr std::array<uint8_t, 12> codes{44, 45, 46, 47, 48, 49, 51, 52, 53, 54, 55, 56};
    constexpr std::string_view shifted = "_+{}|:\"~<>?";
    constexpr std::array<uint8_t, 11> shifted_codes{45, 46, 47, 48, 49, 51, 52, 53, 54, 55, 56};
    if (auto p = plain.find(ch); p != plain.npos)
        return Stroke{0, codes[p]};
    if (auto p = shifted.find(ch); p != shifted.npos)
        return Stroke{2, shifted_codes[p]};
    constexpr std::string_view numbers = "!@#$%^&*()";
    if (auto p = numbers.find(ch); p != numbers.npos)
        return Stroke{2, static_cast<uint8_t>(30 + p)};
    return {};
}
std::optional<Stroke> named_stroke(std::string_view name) {
    if (name.size() == 1)
        return ascii_stroke(name.front());
    constexpr std::array<std::pair<std::string_view, uint8_t>, 15> keys{{{"ENTER", 40},
                                                                         {"ESC", 41},
                                                                         {"BACKSPACE", 42},
                                                                         {"TAB", 43},
                                                                         {"SPACE", 44},
                                                                         {"HOME", 74},
                                                                         {"PAGEUP", 75},
                                                                         {"DELETE", 76},
                                                                         {"END", 77},
                                                                         {"PAGEDOWN", 78},
                                                                         {"RIGHT", 79},
                                                                         {"LEFT", 80},
                                                                         {"DOWN", 81},
                                                                         {"UP", 82},
                                                                         {"CAPSLOCK", 57}}};
    for (auto [n, k] : keys)
        if (n == name)
            return Stroke{0, k};
    for (unsigned i = 1; i <= 12; ++i)
        if (name == "F" + std::to_string(i))
            return Stroke{0, static_cast<uint8_t>(57 + i)};
    return {};
}
std::optional<uint8_t> modifier(std::string_view name) {
    if (name == "CTRL")
        return 1;
    if (name == "SHIFT")
        return 2;
    if (name == "ALT")
        return 4;
    if (name == "GUI")
        return 8;
    return {};
}
std::string_view parse_command(std::string_view input, Command &out) {
    out.clear();
    if (input.empty() || input.size() > 4096)
        return "invalid_command";
    auto root = parse_json(input);
    if (!root || !fields_only(root.get(), {"v", "id", "session", "expires_at", "type", "payload"}))
        return "invalid_command";
    const auto id = text(field(root.get(), "id"));
    if (id.empty() || id.size() > 64)
        return "invalid_command";
    for (auto c : id)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              c == '-' || c == '_' || c == '.'))
            return "invalid_command";
    std::memcpy(out.id.data(), id.data(), id.size());
    auto *version = field(root.get(), "v");
    auto session = text(field(root.get(), "session"));
    auto *expiry = field(root.get(), "expires_at");
    if (!cJSON_IsNumber(version) || version->valuedouble != 1 || session.size() != 32 ||
        !cJSON_IsNumber(expiry) || !std::isfinite(expiry->valuedouble) ||
        expiry->valuedouble <= 0 || expiry->valuedouble > 9007199254740991.0 ||
        std::floor(expiry->valuedouble) != expiry->valuedouble)
        return "invalid_command";
    for (auto c : session)
        if (!((c >= 'a' && c <= 'f') || (c >= '0' && c <= '9')))
            return "invalid_command";
    std::memcpy(out.session.data(), session.data(), session.size());
    out.expires_at = static_cast<int64_t>(expiry->valuedouble);
    auto type = text(field(root.get(), "type"));
    auto *payload = field(root.get(), "payload");
    if (type == "wake") {
        if (!fields_only(payload, {}))
            return "invalid_command";
        out.type = CommandType::wake;
    } else if (type == "type_text") {
        if (!fields_only(payload, {"text", "press_enter"}) ||
            !cJSON_IsString(field(payload, "text")))
            return "invalid_command";
        auto value = text(field(payload, "text"));
        if (value.empty() || value.size() > 512)
            return "invalid_command";
        for (auto c : value)
            if (!ascii_stroke(c))
                return "unsupported_character";
        auto *enter = field(payload, "press_enter");
        if (enter && !cJSON_IsBool(enter))
            return "invalid_command";
        out.type = CommandType::text;
        out.text_length = value.size();
        std::memcpy(out.text.data(), value.data(), value.size());
        out.press_enter = cJSON_IsTrue(enter);
    } else if (type == "key") {
        if (!fields_only(payload, {"key", "modifiers"}))
            return "invalid_command";
        auto stroke = named_stroke(text(field(payload, "key")));
        if (!stroke)
            return "unsupported_character";
        uint8_t seen = 0;
        auto *mods = field(payload, "modifiers");
        if (mods && !cJSON_IsArray(mods))
            return "invalid_command";
        for (auto *p = mods ? mods->child : nullptr; p; p = p->next) {
            auto m = modifier(text(p));
            if (!m || (*m & seen))
                return "invalid_command";
            seen |= *m;
        }
        stroke->modifier |= seen;
        out.type = CommandType::key;
        out.stroke = *stroke;
    } else
        return "invalid_command";
    return {};
}
std::string_view validate_envelope(const Command &cmd, std::string_view session, int64_t now,
                                   bool ready, bool retained) {
    if (retained)
        return "retained_command";
    if (!ready)
        return "time_not_ready";
    if (session.empty() || session != cmd.session.data())
        return "old_session";
    if (cmd.expires_at <= now || cmd.expires_at - now > 30000)
        return "expired";
    return {};
}
std::string_view Deduplicator::remember(const Command &cmd, int64_t now) {
    Entry *slot = nullptr;
    for (auto &entry : entries_) {
        if (entry.expiry <= now) {
            if (!slot)
                slot = &entry;
        } else if (std::string_view(entry.id.data()) == cmd.id.data())
            return "duplicate";
    }
    if (!slot)
        return "dedup_full";
    slot->id = cmd.id;
    slot->expiry = cmd.expires_at;
    return {};
}
void Deduplicator::clear() {
    entries_ = {};
}
std::string_view execute(const Command &cmd, Keyboard &keyboard, unsigned delay,
                         const std::function<bool()> &valid) {
    if (cmd.type == CommandType::text) {
        if (cmd.text_length == 0 || cmd.text_length > 512)
            return "invalid_command";
        for (size_t i = 0; i < cmd.text_length; ++i)
            if (!ascii_stroke(cmd.text[i]))
                return "unsupported_character";
    }
    if (!keyboard.ready())
        return "ble_not_ready";
    const auto tap = [&](Stroke stroke) -> bool {
        if (!valid() || !keyboard.ready())
            return false;
        Report report{};
        report[0] = stroke.modifier;
        report[2] = stroke.key;
        if (!keyboard.send(report))
            return false;
        keyboard.wait(delay);
        // Release even if the MQTT session was lost during the key-down interval.
        if (!keyboard.send(Report{}))
            return false;
        keyboard.wait(delay);
        return valid() && keyboard.ready();
    };
    bool ok = true;
    if (cmd.type == CommandType::wake)
        ok = tap({2, 0});
    else if (cmd.type == CommandType::key)
        ok = tap(cmd.stroke);
    else {
        for (size_t i = 0; i < cmd.text_length && ok; ++i) {
            auto stroke = ascii_stroke(cmd.text[i]);
            if (!stroke)
                return "unsupported_character";
            ok = tap(*stroke);
        }
        if (ok && cmd.press_enter)
            ok = tap({0, 40});
    }
    if (!ok) {
        if (keyboard.ready())
            keyboard.send(Report{});
        return "interrupted";
    }
    return {};
}
} // namespace tepy

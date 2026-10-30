#include "tepy/serial_protocol.hpp"
#include "tepy/json.hpp"
#include <cctype>

namespace tepy::serial {
Decoder::~Decoder() {
    reset();
}
void Decoder::reset() {
    secure_clear(line_.data(), line_.size());
    line_.clear();
    dropping_ = false;
}
void Decoder::feed(std::string_view bytes) {
    for (char c : bytes) {
        if (c == '\n') {
            if (!dropping_) {
                if (!line_.empty() && line_.back() == '\r')
                    line_.pop_back();
                if (line_.starts_with(prefix))
                    receive_(std::string_view(line_).substr(prefix.size()));
            }
            reset();
        } else if (!dropping_) {
            if (line_.size() >= prefix.size() + max_json_bytes + 1) {
                reset();
                dropping_ = true;
            } else
                line_ += c;
        }
    }
}
std::string reply(std::string_view request, const Authenticate &authenticate,
                  const Dispatch &dispatch) {
    auto output = object();
    cJSON_AddNumberToObject(output.get(), "v", 1);
    cJSON_AddStringToObject(output.get(), "id", "");
    const auto fail = [&](const char *code) {
        cJSON_AddBoolToObject(output.get(), "ok", false);
        cJSON_AddStringToObject(output.get(), "error", code);
        return stringify(output.get());
    };
    if (request.size() > max_json_bytes)
        return fail("frame_too_large");
    auto root = parse_json(request);
    if (!root || !fields_only(root.get(), {"v", "id", "method", "token", "params"}))
        return fail("invalid_request");
    const auto id = text(field(root.get(), "id"));
    if (id.empty() || id.size() > 64)
        return fail("invalid_request");
    for (unsigned char c : id)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              c == '-' || c == '_' || c == '.'))
            return fail("invalid_request");
    cJSON_ReplaceItemInObjectCaseSensitive(output.get(), "id",
                                           cJSON_CreateString(std::string(id).c_str()));
    const auto *version = field(root.get(), "v");
    if (!cJSON_IsNumber(version) || version->valuedouble != 1)
        return fail("unsupported_version");
    const auto method = text(field(root.get(), "method"));
    const auto token = text(field(root.get(), "token"));
    const auto *params = field(root.get(), "params");
    if (method.empty() || method.size() > 32 || !cJSON_IsString(field(root.get(), "token")) ||
        token.size() > 64 || !cJSON_IsObject(params))
        return fail("invalid_request");
    if (!authenticate(token))
        return fail("unauthorized");
    auto encoded = stringify(params);
    auto result_text = dispatch(method, encoded);
    secure_clear(encoded.data(), encoded.size());
    auto result = parse_json(result_text);
    secure_clear(result_text.data(), result_text.size());
    if (!result || !cJSON_IsObject(result.get()))
        return fail("internal_error");
    if (const auto *issue = field(result.get(), "error")) {
        if (!cJSON_IsString(issue))
            return fail("internal_error");
        return fail(issue->valuestring);
    }
    cJSON_AddBoolToObject(output.get(), "ok", true);
    cJSON_AddItemToObject(output.get(), "result", result.release());
    return stringify(output.get());
}
} // namespace tepy::serial

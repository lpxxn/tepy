#pragma once
#include <cJSON.h>
#include <cstdlib>
#include <memory>
#include <string>
#include <string_view>

namespace tepy {
inline void secure_clear(void *ptr, size_t size) {
    auto *p = static_cast<volatile unsigned char *>(ptr);
    while (size--)
        *p++ = 0;
}
inline void wipe_json(cJSON *item) {
    for (auto *p = item; p; p = p->next) {
        if (p->child)
            wipe_json(p->child);
        if (cJSON_IsString(p) && p->valuestring)
            secure_clear(p->valuestring, std::char_traits<char>::length(p->valuestring));
    }
}
struct JsonDelete {
    void operator()(cJSON *p) const {
        wipe_json(p);
        cJSON_Delete(p);
    }
};
using Json = std::unique_ptr<cJSON, JsonDelete>;
inline Json object() {
    return Json(cJSON_CreateObject());
}
inline Json parse_json(std::string_view input) {
    if (input.find('\0') != std::string_view::npos ||
        input.find("\\u0000") != std::string_view::npos)
        return {};
    std::string copy(input);
    Json value(cJSON_ParseWithLengthOpts(copy.c_str(), copy.size() + 1, nullptr, true));
    secure_clear(copy.data(), copy.size());
    return value;
}
inline std::string stringify(const cJSON *p) {
    char *text = cJSON_PrintUnformatted(p);
    if (!text)
        return {};
    std::string result(text);
    secure_clear(text, result.size());
    cJSON_free(text);
    return result;
}
inline cJSON *field(const cJSON *p, const char *name) {
    return cJSON_GetObjectItemCaseSensitive(p, name);
}
inline std::string_view text(const cJSON *p) {
    return cJSON_IsString(p) && p->valuestring ? std::string_view(p->valuestring)
                                               : std::string_view{};
}
inline bool fields_only(const cJSON *p, std::initializer_list<std::string_view> allowed) {
    if (!cJSON_IsObject(p))
        return false;
    for (auto *item = p->child; item; item = item->next) {
        bool found = false;
        for (auto name : allowed)
            if (item->string && name == item->string)
                found = true;
        if (!found)
            return false;
        for (auto *next = item->next; next; next = next->next)
            if (next->string && std::string_view(item->string) == next->string)
                return false;
    }
    return true;
}
} // namespace tepy

#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string_view>

namespace tepy {
using Report = std::array<uint8_t, 8>;
struct Stroke {
    uint8_t modifier{};
    uint8_t key{};
};
std::optional<Stroke> ascii_stroke(char value);
std::optional<Stroke> named_stroke(std::string_view name);
std::optional<uint8_t> modifier(std::string_view name);
enum class CommandType { wake, text, key };
struct Command {
    std::array<char, 65> id{};
    std::array<char, 33> session{};
    int64_t expires_at{};
    CommandType type{CommandType::wake};
    std::array<char, 513> text{};
    size_t text_length{};
    bool press_enter{};
    Stroke stroke{};
    void clear() {
        volatile auto *p = reinterpret_cast<volatile unsigned char *>(this);
        for (size_t i = 0; i < sizeof(*this); ++i)
            p[i] = 0;
    }
};
std::string_view parse_command(std::string_view input, Command &output);
std::string_view validate_envelope(const Command &command, std::string_view session, int64_t now_ms,
                                   bool time_ready, bool retained);
class Deduplicator {
  public:
    std::string_view remember(const Command &command, int64_t now_ms);
    void clear();

  private:
    struct Entry {
        std::array<char, 65> id{};
        int64_t expiry{};
    };
    std::array<Entry, 128> entries_{};
};
class Keyboard {
  public:
    virtual ~Keyboard() = default;
    virtual bool ready() const = 0;
    virtual bool send(const Report &report) = 0;
    virtual void wait(unsigned milliseconds) = 0;
};
std::string_view execute(
    const Command &command, Keyboard &keyboard, unsigned delay_ms,
    const std::function<bool()> &valid = [] { return true; });
} // namespace tepy

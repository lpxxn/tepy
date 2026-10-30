#pragma once
#include <functional>
#include <string>
#include <string_view>

namespace tepy::serial {
inline constexpr std::string_view prefix = "@tepy:";
inline constexpr size_t max_json_bytes = 20000;
// This parser consumes a stream, never echoes it, and drops oversized lines until LF.
class Decoder {
  public:
    using Receive = std::function<void(std::string_view)>;
    explicit Decoder(Receive receive) : receive_(std::move(receive)) {}
    ~Decoder();
    void feed(std::string_view bytes);
    void reset();

  private:
    Receive receive_;
    std::string line_;
    bool dropping_{};
};
using Authenticate = std::function<bool(std::string_view)>;
using Dispatch = std::function<std::string(std::string_view, std::string_view)>;
// Returns only a reply envelope; no request token or params are reflected.
std::string reply(std::string_view request, const Authenticate &authenticate,
                  const Dispatch &dispatch);
} // namespace tepy::serial

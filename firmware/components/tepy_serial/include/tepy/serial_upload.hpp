#pragma once
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>

namespace tepy::serial {
inline constexpr size_t upload_chunk_size = 3072;
// Hardware-independent transaction rules; the backend owns hashing and flash writes.
struct UploadBackend {
    std::function<bool()> acquire;
    std::function<void()> release;
    std::function<std::string_view(size_t, std::string_view)> begin;
    std::function<std::string_view(std::string_view)> write;
    std::function<std::string_view()> finish;
    std::function<void()> abort;
};
class Upload {
  public:
    explicit Upload(UploadBackend backend) : backend_(std::move(backend)) {}
    Upload(const Upload &) = delete;
    Upload &operator=(const Upload &) = delete;
    ~Upload() { cancel(); }
    std::string_view begin(std::string_view id, size_t size, std::string_view digest, int64_t now);
    std::string_view write(std::string_view id, size_t offset, std::string_view data, int64_t now);
    std::string_view finish(std::string_view id, int64_t now);
    std::string_view abort(std::string_view id);
    void expire(int64_t now);
    bool active() const { return !id_.empty(); }
    size_t received() const { return received_; }

  private:
    void cancel();
    UploadBackend backend_;
    std::string id_;
    size_t total_{}, received_{};
    int64_t started_{}, last_{};
};
} // namespace tepy::serial

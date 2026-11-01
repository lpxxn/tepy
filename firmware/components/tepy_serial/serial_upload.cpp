#include "tepy/serial_upload.hpp"

namespace tepy::serial {
namespace {
bool hex(std::string_view text, size_t size) {
    if (text.size() != size)
        return false;
    for (char c : text)
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
            return false;
    return true;
}
} // namespace
void Upload::cancel() {
    if (!active())
        return;
    backend_.abort();
    id_.clear();
    total_ = received_ = 0;
    backend_.release();
}
void Upload::expire(int64_t now) {
    if (active() && (now - last_ >= 30000 || now - started_ >= 600000))
        cancel();
}
std::string_view Upload::begin(std::string_view id, size_t size, std::string_view digest,
                               int64_t now) {
    expire(now);
    if (active())
        return "busy";
    if (!hex(id, 32) || !hex(digest, 64) || size <= 288 || size > 4 * 1024 * 1024)
        return "invalid_upload";
    if (!backend_.acquire())
        return "busy";
    id_ = id;
    total_ = size;
    received_ = 0;
    started_ = last_ = now;
    auto issue = backend_.begin(size, digest);
    if (!issue.empty())
        cancel();
    return issue;
}
std::string_view Upload::write(std::string_view id, size_t offset, std::string_view data,
                               int64_t now) {
    expire(now);
    if (!active() || id != id_)
        return "invalid_upload_id";
    if (offset != received_ || data.empty() || data.size() > upload_chunk_size ||
        data.size() > total_ - received_) {
        cancel();
        return "invalid_chunk";
    }
    auto issue = backend_.write(data);
    if (!issue.empty()) {
        cancel();
        return issue;
    }
    received_ += data.size();
    last_ = now;
    return {};
}
std::string_view Upload::finish(std::string_view id, int64_t now) {
    expire(now);
    if (!active() || id != id_)
        return "invalid_upload_id";
    if (received_ != total_) {
        cancel();
        return "incomplete_upload";
    }
    const auto issue = backend_.finish();
    cancel(); // abort is safe after backend finish too; always release the lease.
    return issue;
}
std::string_view Upload::abort(std::string_view id) {
    if (!active() || id != id_)
        return "invalid_upload_id";
    cancel();
    return {};
}
} // namespace tepy::serial

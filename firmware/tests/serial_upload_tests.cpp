#include "tepy/serial_upload.hpp"
#include <cstdlib>
#include <iostream>

namespace {
void check(bool value, const char *name) {
    if (!value) {
        std::cerr << "FAILED: " << name << '\n';
        std::exit(1);
    }
}
struct Fixture {
    bool locked{}, blocked{};
    unsigned begins{}, finishes{}, activated{}, aborts{};
    std::string data, fail_begin, fail_write, fail_finish;
    tepy::serial::Upload upload{{[&] {
                                     if (blocked || locked)
                                         return false;
                                     return locked = true;
                                 },
                                 [&] { locked = false; },
                                 [&](size_t size, std::string_view digest) -> std::string_view {
                                     check(size == 4000 && digest == std::string(64, 'a'),
                                           "metadata forwarded");
                                     ++begins;
                                     data.clear();
                                     return fail_begin;
                                 },
                                 [&](std::string_view value) -> std::string_view {
                                     data += value;
                                     return fail_write;
                                 },
                                 [&]() -> std::string_view {
                                     ++finishes;
                                     if (fail_finish.empty())
                                         ++activated;
                                     return fail_finish;
                                 },
                                 [&] { ++aborts; }}};
};
const std::string id(32, 'b'), other(32, 'c'), hash(64, 'a');
} // namespace
int main() {
    {
        Fixture f;
        check(f.upload.begin(id, 4000, hash, 100).empty() && f.locked, "begin holds maintenance");
        check(f.upload.write(other, 0, "x", 101) == "invalid_upload_id" && f.upload.active(),
              "wrong ID cannot take over");
        check(f.upload.write(id, 0, std::string(3072, 'x'), 102).empty(), "first chunk");
        check(f.upload.received() == 3072 && f.locked, "acknowledged progress");
        check(f.upload.write(id, 3072, std::string(928, 'y'), 103).empty(), "last chunk");
        check(f.upload.finish(id, 104).empty(), "complete commit");
        check(f.data.size() == 4000 && f.activated == 1 && !f.locked && !f.upload.active(),
              "exact data and release");
        check(f.upload.finish(id, 105) == "invalid_upload_id" && f.activated == 1,
              "no repeated commit");
    }
    for (int kind = 0; kind < 5; ++kind) {
        Fixture f;
        check(f.upload.begin(id, 4000, hash, 100).empty(), "failure test begin");
        if (kind == 0)
            check(f.upload.write(id, 1, "x", 101) == "invalid_chunk", "offset rejected");
        if (kind == 1)
            check(f.upload.write(id, 0, std::string(3073, 'x'), 101) == "invalid_chunk",
                  "oversized chunk rejected");
        if (kind == 2)
            check(f.upload.finish(id, 101) == "incomplete_upload", "incomplete cannot finish");
        if (kind == 3) {
            f.upload.expire(30100);
            check(!f.upload.active(), "idle timeout");
        }
        if (kind == 4)
            check(f.upload.abort(id).empty(), "explicit abort");
        check(!f.locked && !f.upload.active() && f.activated == 0,
              "failure leaves old boot and releases lease");
    }
    {
        Fixture f;
        f.blocked = true;
        check(f.upload.begin(id, 4000, hash, 100) == "busy" && f.begins == 0,
              "busy never erases flash");
        f.blocked = false;
        f.fail_begin = "ota_begin_error";
        check(f.upload.begin(id, 4000, hash, 100) == "ota_begin_error" && !f.locked,
              "begin error releases lease");
        f.fail_begin.clear();
        f.fail_finish = "digest_mismatch";
        check(f.upload.begin(id, 4000, hash, 101).empty(), "retry is a new transaction");
        f.upload.write(id, 0, std::string(3000, 'x'), 102);
        f.upload.write(id, 3000, std::string(1000, 'x'), 103);
        check(f.upload.finish(id, 104) == "digest_mismatch" && !f.locked && f.activated == 0,
              "hash failure does not activate");
    }
    std::cout << "PASS: USB upload transaction, interruption and lease checks\n";
}

#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct tepy_session { int available, on_console, login_done, locked, lock_source; };
struct tepy_event { int kind; int64_t at; };
void tepy_read_session(struct tepy_session *out);
void *tepy_power_start(void);
int tepy_power_poll(void *observer, struct tepy_event *event);
void tepy_power_stop(void *observer);
#ifdef __cplusplus
}
#endif

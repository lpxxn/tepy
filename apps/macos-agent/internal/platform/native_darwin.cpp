//go:build darwin && cgo

#include "native.hpp"
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CGSession.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <new>
#include <unistd.h>

namespace {
int boolean(CFDictionaryRef dictionary, CFStringRef key) {
    if (!dictionary) return -1;
    const auto value = CFDictionaryGetValue(dictionary,key);
    if (!value || CFGetTypeID(value)!=CFBooleanGetTypeID()) return -1;
    return CFBooleanGetValue(static_cast<CFBooleanRef>(value)) ? 1 : 0;
}
struct PowerObserver {
    io_connect_t root{}; IONotificationPortRef port{}; io_object_t notifier{};
    tepy_event events[32]{}; unsigned head{},count{};
    void push(int kind) {
        if (count==32) { head=(head+1)%32; --count; }
        events[(head+count)%32]={kind,static_cast<int64_t>((CFAbsoluteTimeGetCurrent()+978307200.0)*1000.0)};
        ++count;
    }
};
void power_callback(void *ref,io_service_t,natural_t message,void *argument) {
    auto &state=*static_cast<PowerObserver *>(ref);
    if (message==kIOMessageSystemWillSleep) state.push(1);
    if (message==kIOMessageSystemHasPoweredOn) state.push(2);
    // Acknowledge immediately, before any Go / network work. Never prevent sleep.
    if (message==kIOMessageCanSystemSleep || message==kIOMessageSystemWillSleep)
        IOAllowPowerChange(state.root,reinterpret_cast<intptr_t>(argument));
}
void screen_callback(CFNotificationCenterRef,void *ref,CFStringRef name,const void *,CFDictionaryRef) {
    auto &state=*static_cast<PowerObserver *>(ref);
    if (CFEqual(name,CFSTR("com.apple.screenIsLocked"))) state.push(3);
    if (CFEqual(name,CFSTR("com.apple.screenIsUnlocked"))) state.push(4);
}
}
extern "C" void tepy_read_session(tepy_session *out) {
    *out={0,-1,-1,-1,0};
    auto dictionary=CGSessionCopyCurrentDictionary();
    if (dictionary) {
        out->available=1;
        out->on_console=boolean(dictionary,kCGSessionOnConsoleKey);
        out->login_done=boolean(dictionary,kCGSessionLoginDoneKey);
        out->locked=boolean(dictionary,CFSTR("CGSSessionScreenIsLocked"));
        if (out->locked>=0) out->lock_source=1;
        CFRelease(dictionary);
    }
    // Optional system property, not a stable API contract. Absence is UNKNOWN,
    // never an inference that the screen is unlocked. Only inspect our own UID.
    if (out->locked>=0) return;
    const auto root=IORegistryGetRootEntry(kIOMainPortDefault);
    if (!root) return;
    const auto value=IORegistryEntryCreateCFProperty(root,CFSTR("IOConsoleUsers"),kCFAllocatorDefault,0);
    IOObjectRelease(root);
    if (value && CFGetTypeID(value)==CFArrayGetTypeID()) {
        const auto users=static_cast<CFArrayRef>(value);
        for (CFIndex i=0;i<CFArrayGetCount(users);++i) {
            const auto entry=CFArrayGetValueAtIndex(users,i);
            if (CFGetTypeID(entry)!=CFDictionaryGetTypeID()) continue;
            const auto user=static_cast<CFDictionaryRef>(entry);
            const auto uid=CFDictionaryGetValue(user,CFSTR("CGSSessionUserIDKey"));
            int number=-1;
            if (!uid || CFGetTypeID(uid)!=CFNumberGetTypeID() || !CFNumberGetValue(static_cast<CFNumberRef>(uid),kCFNumberIntType,&number) || number!=static_cast<int>(getuid())) continue;
            out->locked=boolean(user,CFSTR("CGSSessionScreenIsLocked"));
            if (out->locked>=0) out->lock_source=2;
        }
    }
    if (value) CFRelease(value);
}
extern "C" void *tepy_power_start() {
    auto *state=new(std::nothrow) PowerObserver;
    if (!state) return nullptr;
    state->root=IORegisterForSystemPower(state,&state->port,power_callback,&state->notifier);
    if (!state->root) { if (state->port) IONotificationPortDestroy(state->port); delete state; return nullptr; }
    CFRunLoopAddSource(CFRunLoopGetCurrent(),IONotificationPortGetRunLoopSource(state->port),kCFRunLoopDefaultMode);
    auto center=CFNotificationCenterGetDistributedCenter();
    CFNotificationCenterAddObserver(center,state,screen_callback,CFSTR("com.apple.screenIsLocked"),nullptr,CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center,state,screen_callback,CFSTR("com.apple.screenIsUnlocked"),nullptr,CFNotificationSuspensionBehaviorDeliverImmediately);
    return state;
}
extern "C" int tepy_power_poll(void *observer,tepy_event *event) {
    auto &state=*static_cast<PowerObserver *>(observer);
    if (!state.count) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.2,true);
    if (!state.count) return 0;
    *event=state.events[state.head]; state.head=(state.head+1)%32; --state.count; return 1;
}
extern "C" void tepy_power_stop(void *observer) {
    auto *state=static_cast<PowerObserver *>(observer);
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDistributedCenter(),state);
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(),IONotificationPortGetRunLoopSource(state->port),kCFRunLoopDefaultMode);
    IODeregisterForSystemPower(&state->notifier); IONotificationPortDestroy(state->port); IOServiceClose(state->root); delete state;
}

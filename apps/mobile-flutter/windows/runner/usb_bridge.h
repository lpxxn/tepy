#ifndef TEPY_USB_BRIDGE_H_
#define TEPY_USB_BRIDGE_H_
#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <atomic>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

// 原生层仅传递字节。鉴权、JSON 分帧和配置校验复用 Android 的 Dart 实现。
class UsbBridge {
 public:
  UsbBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~UsbBridge();
  bool HandleMessage(UINT message);
 private:
  using Value = flutter::EncodableValue;
  using Result = flutter::MethodResult<Value>;
  struct WriteRequest { std::vector<uint8_t> bytes; std::shared_ptr<Result> result; };
  void OnMethod(const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result);
  bool Open(const std::string& port);
  void Close();
  void Run(int64_t lease);
  bool Transfer(bool write, uint8_t* bytes, DWORD size, DWORD* count);
  void Post(std::function<void()> callback);
  void Drain();
  void EmitClosed(int64_t lease);
  HWND window_;
  HANDLE port_ = INVALID_HANDLE_VALUE;
  HANDLE stop_ = nullptr;
  std::thread worker_;
  int64_t lease_ = 0;
  std::mutex writes_mutex_, ui_mutex_;
  std::deque<WriteRequest> writes_;
  std::deque<std::function<void()>> ui_;
  std::unique_ptr<flutter::MethodChannel<Value>> methods_;
  std::unique_ptr<flutter::EventChannel<Value>> events_;
  std::unique_ptr<flutter::EventSink<Value>> sink_;
};
#endif

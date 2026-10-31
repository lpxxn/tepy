#include "usb_bridge.h"
#include <devguid.h>
#include <setupapi.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <array>
#include <cwctype>
#include <string>

namespace {
constexpr UINT kUiMessage = WM_APP + 0x54;
using V = flutter::EncodableValue;
using Map = flutter::EncodableMap;
struct Port { std::string id, name; int product; };
std::string Utf8(const wchar_t* text) {
  const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return {};
  std::string out(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), size, nullptr, nullptr);
  out.pop_back(); return out;
}
std::vector<Port> Ports() {
  std::vector<Port> ports;
  const HDEVINFO devices = SetupDiGetClassDevsW(&GUID_DEVCLASS_PORTS, nullptr, nullptr, DIGCF_PRESENT);
  if (devices == INVALID_HANDLE_VALUE) return ports;
  SP_DEVINFO_DATA info{}; info.cbSize = sizeof(info);
  for (DWORD i = 0; SetupDiEnumDeviceInfo(devices, i, &info); ++i) {
    std::array<wchar_t, 2048> hardware{};
    if (!SetupDiGetDeviceRegistryPropertyW(devices, &info, SPDRP_HARDWAREID, nullptr, reinterpret_cast<PBYTE>(hardware.data()), static_cast<DWORD>(sizeof(hardware) - sizeof(wchar_t)), nullptr)) continue;
    std::wstring id(hardware.data());
    std::transform(id.begin(), id.end(), id.begin(), [](wchar_t c) { return static_cast<wchar_t>(towupper(c)); });
    if (id.find(L"VID_303A") == std::wstring::npos) continue;
    int product = 0;
    const size_t pid = id.find(L"PID_");
    if (pid != std::wstring::npos) product = static_cast<int>(wcstoul(id.c_str() + pid + 4, nullptr, 16));
    HKEY key = SetupDiOpenDevRegKey(devices, &info, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_READ);
    if (key == INVALID_HANDLE_VALUE) continue;
    std::array<wchar_t, 128> port{}; DWORD bytes = static_cast<DWORD>(sizeof(port) - sizeof(wchar_t)), type = 0;
    const auto error = RegQueryValueExW(key, L"PortName", nullptr, &type, reinterpret_cast<LPBYTE>(port.data()), &bytes);
    RegCloseKey(key);
    if (error != ERROR_SUCCESS || type != REG_SZ) continue;
    std::wstring name(port.data());
    if (name.size() < 4 || name.substr(0, 3) != L"COM" || !std::all_of(name.begin() + 3, name.end(), [](wchar_t c) { return c >= L'0' && c <= L'9'; })) continue;
    std::array<wchar_t, 512> friendly{};
    SetupDiGetDeviceRegistryPropertyW(devices, &info, SPDRP_FRIENDLYNAME, nullptr, reinterpret_cast<PBYTE>(friendly.data()), static_cast<DWORD>(sizeof(friendly) - sizeof(wchar_t)), nullptr);
    ports.push_back({Utf8(port.data()), friendly[0] ? Utf8(friendly.data()) : "ESP32 USB Serial", product});
  }
  SetupDiDestroyDeviceInfoList(devices);
  return ports;
}
const V* Arg(const flutter::MethodCall<V>& call, const char* key) {
  if (!call.arguments()) return nullptr;
  const auto* map = std::get_if<Map>(call.arguments());
  if (!map) return nullptr;
  const auto found = map->find(V(key));
  return found == map->end() ? nullptr : &found->second;
}
}

UsbBridge::UsbBridge(flutter::BinaryMessenger* messenger, HWND window) : window_(window) {
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();
  methods_ = std::make_unique<flutter::MethodChannel<V>>(messenger, "tepy/usb", codec);
  methods_->SetMethodCallHandler([this](const auto& call, auto result) { OnMethod(call, std::move(result)); });
  events_ = std::make_unique<flutter::EventChannel<V>>(messenger, "tepy/usb/events", codec);
  events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<V>>(
    [this](const V*, std::unique_ptr<flutter::EventSink<V>>&& sink) -> std::unique_ptr<flutter::StreamHandlerError<V>> { sink_ = std::move(sink); return nullptr; },
    [this](const V*) -> std::unique_ptr<flutter::StreamHandlerError<V>> { Close(); sink_.reset(); return nullptr; }));
}
UsbBridge::~UsbBridge() {
  Close(); Drain();
  methods_->SetMethodCallHandler(nullptr);
  events_->SetStreamHandler(nullptr);
}
void UsbBridge::OnMethod(const flutter::MethodCall<V>& call, std::unique_ptr<Result> result) {
  if (call.method_name() == "list") {
    flutter::EncodableList items;
    for (const auto& port : Ports()) items.emplace_back(Map{{V("id"), V(port.id)}, {V("name"), V(port.name)}, {V("vendor_id"), V(0x303a)}, {V("product_id"), V(port.product)}});
    result->Success(V(items));
  } else if (call.method_name() == "open") {
    const auto* arg = Arg(call, "id");
    const auto* id = arg ? std::get_if<std::string>(arg) : nullptr;
    if (!id || !Open(*id)) { result->Error("usb_open", "Unable to open the selected ESP32 port."); return; }
    result->Success(V(Map{{V("lease"), V(lease_)}}));
  } else if (call.method_name() == "write") {
    const auto* arg = Arg(call, "bytes");
    const auto* bytes = arg ? std::get_if<std::vector<uint8_t>>(arg) : nullptr;
    if (port_ == INVALID_HANDLE_VALUE || WaitForSingleObject(stop_, 0) == WAIT_OBJECT_0 || !bytes || bytes->empty() || bytes->size() > 20007) { result->Error("usb_write", "Port closed or invalid frame."); return; }
    std::lock_guard<std::mutex> lock(writes_mutex_);
    if (writes_.size() >= 4) { result->Error("usb_busy", "Write queue is full."); return; }
    writes_.push_back({*bytes, std::shared_ptr<Result>(std::move(result))});
  } else if (call.method_name() == "close") {
    Close(); result->Success();
  } else { result->NotImplemented(); }
}
bool UsbBridge::Open(const std::string& name) {
  Close();
  const auto ports = Ports();
  if (std::none_of(ports.begin(), ports.end(), [&name](const Port& p) { return p.id == name; })) return false;
  const std::wstring path = L"\\\\.\\" + std::wstring(name.begin(), name.end());
  port_ = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
  if (port_ == INVALID_HANDLE_VALUE) return false;
  DCB config{}; config.DCBlength = sizeof(config);
  if (!GetCommState(port_, &config)) { Close(); return false; }
  config.BaudRate = 115200; config.ByteSize = 8; config.Parity = NOPARITY; config.StopBits = ONESTOPBIT;
  config.fBinary = TRUE; config.fParity = FALSE;
  config.fOutxCtsFlow = FALSE; config.fOutxDsrFlow = FALSE;
  config.fDtrControl = DTR_CONTROL_ENABLE; config.fRtsControl = RTS_CONTROL_DISABLE;
  config.fDsrSensitivity = FALSE; config.fOutX = FALSE; config.fInX = FALSE; config.fAbortOnError = FALSE;
  COMMTIMEOUTS timeouts{};
  timeouts.ReadIntervalTimeout = MAXDWORD; timeouts.ReadTotalTimeoutMultiplier = MAXDWORD;
  timeouts.ReadTotalTimeoutConstant = 100; timeouts.WriteTotalTimeoutConstant = 3000;
  if (!SetCommState(port_, &config) || !SetCommTimeouts(port_, &timeouts)) { Close(); return false; }
  PurgeComm(port_, PURGE_RXCLEAR | PURGE_TXCLEAR);
  stop_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!stop_) { Close(); return false; }
  const auto lease = ++lease_;
  worker_ = std::thread([this, lease] { Run(lease); });
  return true;
}
void UsbBridge::Close() {
  ++lease_; // 旧连接中已经排队的字节，不得进入新连接。
  if (stop_) SetEvent(stop_);
  if (worker_.joinable()) worker_.join();
  if (port_ != INVALID_HANDLE_VALUE) { CloseHandle(port_); port_ = INVALID_HANDLE_VALUE; }
  if (stop_) { CloseHandle(stop_); stop_ = nullptr; }
  std::deque<WriteRequest> pending;
  { std::lock_guard<std::mutex> lock(writes_mutex_); pending.swap(writes_); }
  for (auto& item : pending) {
    SecureZeroMemory(item.bytes.data(), item.bytes.size());
    item.result->Error("usb_closed", "Port closed before write completed.");
  }
}
// 重叠 I/O + 停止事件：拔线、关闭窗口时可取消等待，不阻塞 Flutter 界面。
bool UsbBridge::Transfer(bool write, uint8_t* bytes, DWORD size, DWORD* count) {
  OVERLAPPED operation{}; operation.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!operation.hEvent) return false;
  BOOL ok = write ? WriteFile(port_, bytes, size, count, &operation) : ReadFile(port_, bytes, size, count, &operation);
  if (!ok && GetLastError() == ERROR_IO_PENDING) {
    HANDLE handles[] = {stop_, operation.hEvent};
    const auto wait = WaitForMultipleObjects(2, handles, FALSE, write ? 3500 : 200);
    if (wait != WAIT_OBJECT_0 + 1) CancelIoEx(port_, &operation);
    ok = GetOverlappedResult(port_, &operation, count, TRUE);
    if (wait != WAIT_OBJECT_0 + 1) ok = FALSE;
  }
  CloseHandle(operation.hEvent);
  return ok != FALSE;
}
void UsbBridge::Run(int64_t lease) {
  bool failed = false;
  while (WaitForSingleObject(stop_, 0) != WAIT_OBJECT_0) {
    WriteRequest item;
    { std::lock_guard<std::mutex> lock(writes_mutex_); if (!writes_.empty()) { item = std::move(writes_.front()); writes_.pop_front(); } }
    if (item.result) {
      DWORD written = 0;
      const bool ok = Transfer(true, item.bytes.data(), static_cast<DWORD>(item.bytes.size()), &written) && written == item.bytes.size();
      SecureZeroMemory(item.bytes.data(), item.bytes.size());
      Post([this, lease, result = item.result, ok] { if (ok && lease_ == lease) result->Success(); else result->Error("usb_write", "Write not confirmed; do not retry automatically."); });
      if (!ok) { failed = true; break; }
    }
    std::vector<uint8_t> buffer(4096); DWORD count = 0;
    if (!Transfer(false, buffer.data(), static_cast<DWORD>(buffer.size()), &count)) { failed = true; break; }
    if (count > 0) {
      // UI 暂停处理时限制缓存，不无限积压来自串口的日志和旧回执。
      bool backlogged;
      { std::lock_guard<std::mutex> lock(ui_mutex_); backlogged = ui_.size() >= 128; }
      if (backlogged) { failed = true; break; }
      buffer.resize(count);
      Post([this, lease, buffer = std::move(buffer)]() mutable {
        if (lease == lease_ && sink_) sink_->Success(V(Map{{V("event"), V("data")}, {V("lease"), V(lease)}, {V("bytes"), V(buffer)}}));
        SecureZeroMemory(buffer.data(), buffer.size());
      });
    }
  }
  if (failed && WaitForSingleObject(stop_, 0) != WAIT_OBJECT_0) {
    SetEvent(stop_);
    Post([this, lease] { EmitClosed(lease); });
  }
}
void UsbBridge::EmitClosed(int64_t lease) {
  if (lease != lease_) return;
  if (sink_) sink_->Success(V(Map{{V("event"), V("closed")}, {V("lease"), V(lease)}}));
  Close();
}
void UsbBridge::Post(std::function<void()> callback) {
  { std::lock_guard<std::mutex> lock(ui_mutex_); ui_.push_back(std::move(callback)); }
  PostMessageW(window_, kUiMessage, 0, 0);
}
void UsbBridge::Drain() {
  std::deque<std::function<void()>> callbacks;
  { std::lock_guard<std::mutex> lock(ui_mutex_); callbacks.swap(ui_); }
  for (auto& callback : callbacks) callback();
}
bool UsbBridge::HandleMessage(UINT message) {
  if (message != kUiMessage) return false;
  Drain(); return true;
}

#pragma once
#include <stdio.h>
// The host test compiles the real SDK report-map parser; only logging is stubbed.
#define ESP_LOGE(tag, format, ...) fprintf(stderr, format "\n", ##__VA_ARGS__)
#define ESP_LOGW(tag, format, ...) fprintf(stderr, format "\n", ##__VA_ARGS__)
#define ESP_LOGI(tag, format, ...) ((void)0)
#define ESP_LOGD(tag, format, ...) ((void)0)
#define ESP_LOGV(tag, format, ...) ((void)0)

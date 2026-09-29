/**
 *  Copyright (C) 2011-2012  Juho Vähä-Herttua
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 */

#ifndef HTTP_REQUEST_H
#define HTTP_REQUEST_H

typedef struct http_request_s http_request_t;


http_request_t *http_request_init(void);

int http_request_add_data(http_request_t *request, const char *data, int datalen);
int http_request_is_complete(http_request_t *request);
int http_request_has_error(http_request_t *request);

const char *http_request_get_error_name(http_request_t *request);
const char *http_request_get_error_description(http_request_t *request);
const char *http_request_get_method(http_request_t *request);
const char *http_request_get_url(http_request_t *request);
const char *http_request_get_header(http_request_t *request, const char *name);
const char *http_request_get_data(http_request_t *request, int *datalen);

/* IPHONE_MIRROR_AIRPLAY_PROTOCOL_COMPATIBILITY（上游 c788d6fe）
 *
 * 返回请求行里**原样**的协议版本串，形如 "HTTP/1.1" 或 "RTSP/1.0"；
 * 请求还没解析完时返回 NULL。
 *
 * 为什么需要它：iOS 会把接收端的同一个端口当两种服务使用 —— 对 _raop._tcp
 * 端口既发 HTTP 的 "GET /info HTTP/1.1"，也发 RTSP 的 "OPTIONS ... RTSP/1.0"。
 * 回应的状态行必须与请求同协议，否则 iOS 判握手不合规，设备出现在列表里却
 * 连不上。原版在这里硬编码（RAOP 永远回 RTSP/1.0、AirPlay 永远回 HTTP/1.1），
 * 正是这一步把 HTTP 请求的回应写成了 RTSP。 */
const char *http_request_get_protocol(http_request_t *request);

void http_request_destroy(http_request_t *request);

#endif

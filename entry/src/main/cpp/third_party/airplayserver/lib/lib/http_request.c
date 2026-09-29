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

#include <stdlib.h>
#include <stdio.h>
#include <ctype.h>
#include <string.h>
#include <assert.h>

#include "http_request.h"
#include "http_parser.h"

struct http_request_s {
	http_parser parser;
	http_parser_settings parser_settings;

	const char *method;
	char *url;
	/* IPHONE_MIRROR_AIRPLAY_PROTOCOL_COMPATIBILITY（上游 c788d6fe）：
	 * 请求行里的协议版本原样留存，供回应时回同款。 */
	char protocol[32];

	char **headers;
	int headers_size;
	int headers_index;

	char *data;
	int datalen;

	int complete;
};

static int
on_url(http_parser *parser, const char *at, size_t length)
{
	http_request_t *request = parser->data;
	int urllen = request->url ? strlen(request->url) : 0;

	request->url = realloc(request->url, urllen+length+1);
	assert(request->url);

	request->url[urllen] = '\0';
	strncat(request->url, at, length);
	return 0;
}

static int
on_header_field(http_parser *parser, const char *at, size_t length)
{
	http_request_t *request = parser->data;

	/* Check if our index is a value */
	if (request->headers_index%2 == 1) {
		request->headers_index++;
	}

	/* Allocate space for new field-value pair */
	if (request->headers_index == request->headers_size) {
		request->headers_size += 2;
		request->headers = realloc(request->headers,
		                           request->headers_size*sizeof(char*));
		assert(request->headers);
		request->headers[request->headers_index] = NULL;
		request->headers[request->headers_index+1] = NULL;
	}

	/* Allocate space in the current header string */
	if (request->headers[request->headers_index] == NULL) {
		request->headers[request->headers_index] = calloc(1, length+1);
	} else {
		request->headers[request->headers_index] = realloc(
			request->headers[request->headers_index],
			strlen(request->headers[request->headers_index])+length+1
		);
	}
	assert(request->headers[request->headers_index]);

	strncat(request->headers[request->headers_index], at, length);
	return 0;
}

static int
on_header_value(http_parser *parser, const char *at, size_t length)
{
	http_request_t *request = parser->data;

	/* Check if our index is a field */
	if (request->headers_index%2 == 0) {
		request->headers_index++;
	}

	/* Allocate space in the current header string */
	if (request->headers[request->headers_index] == NULL) {
		request->headers[request->headers_index] = calloc(1, length+1);
	} else {
		request->headers[request->headers_index] = realloc(
			request->headers[request->headers_index],
			strlen(request->headers[request->headers_index])+length+1
		);
	}
	assert(request->headers[request->headers_index]);

	strncat(request->headers[request->headers_index], at, length);
	return 0;
}

static int
on_body(http_parser *parser, const char *at, size_t length)
{
	http_request_t *request = parser->data;

	request->data = realloc(request->data, request->datalen+length);
	assert(request->data);

	memcpy(request->data+request->datalen, at, length);
	request->datalen += length;
	return 0;
}

static int
on_message_complete(http_parser *parser)
{
	http_request_t *request = parser->data;

	request->method = http_method_str(request->parser.method);
	/* IPHONE_MIRROR_AIRPLAY_PROTOCOL_COMPATIBILITY（上游 c788d6fe）：
	 * 把请求行里的协议版本拼成 "HTTP/1.1" / "RTSP/1.0"，回应时原样回。 */
	snprintf(request->protocol, sizeof(request->protocol), "%s/%u.%u",
		request->parser.is_rtsp ? "RTSP" : "HTTP",
		(unsigned int)request->parser.http_major,
		(unsigned int)request->parser.http_minor);
	request->complete = 1;
	return 0;
}

/* IPHONE_MIRROR_AIRPLAY_HEADER_CASE（上游 c788d6fe）：
 * HTTP 头字段名按 RFC 7230 §3.2 **大小写不敏感**。
 *
 * 原版 http_request_get_header() 用 strcmp 直接比，而头部名是按客户端发来的
 * 原始字节存的，于是 iOS 发 "Content-Type" 就查不到代码里写的 "content-type"。
 * 后果不是"少读一个头"，而是多个关键路径直接短路：
 *   * raop.c 取不到 "CSeq" 就 **return，一个字节都不回**（iPhone 侧表现为
 *     "搜到了、点进去一直转圈/连不上"）；
 *   * airplay.c 取不到 "authorization" 就当成未授权，回 403；
 *   * pair-verify 拿不到客户端会话信息，配对直接失败。
 */
static int
iphone_mirror_header_name_equals(const char *left, const char *right)
{
	while (*left != '\0' && *right != '\0') {
		if (tolower((unsigned char)*left) != tolower((unsigned char)*right)) {
			return 0;
		}
		++left;
		++right;
	}
	return *left == *right;
}

http_request_t *
http_request_init(void)
{
	http_request_t *request;

	request = calloc(1, sizeof(http_request_t));
	if (!request) {
		return NULL;
	}
	http_parser_init(&request->parser, HTTP_REQUEST);
	request->parser.data = request;

	request->parser_settings.on_url = &on_url;
	request->parser_settings.on_header_field = &on_header_field;
	request->parser_settings.on_header_value = &on_header_value;
	request->parser_settings.on_body = &on_body;
	request->parser_settings.on_message_complete = &on_message_complete;

	return request;
}

void
http_request_destroy(http_request_t *request)
{
	int i;

	if (request) {
		free(request->url);
		for (i=0; i<request->headers_size; i++) {
			free(request->headers[i]);
		}
		free(request->headers);
		free(request->data);
		free(request);
	}
}

int
http_request_add_data(http_request_t *request, const char *data, int datalen)
{
	int ret;

	assert(request);

	ret = http_parser_execute(&request->parser,
	                          &request->parser_settings,
	                          data, datalen);
	return ret;
}

int
http_request_is_complete(http_request_t *request)
{
	assert(request);
	return request->complete;
}

int
http_request_has_error(http_request_t *request)
{
	assert(request);
	return (HTTP_PARSER_ERRNO(&request->parser) != HPE_OK);
}

const char *
http_request_get_error_name(http_request_t *request)
{
	assert(request);
	return http_errno_name(HTTP_PARSER_ERRNO(&request->parser));
}

const char *
http_request_get_error_description(http_request_t *request)
{
	assert(request);
	return http_errno_description(HTTP_PARSER_ERRNO(&request->parser));
}

const char *
http_request_get_method(http_request_t *request)
{
	assert(request);
	return request->method;
}

const char *
http_request_get_url(http_request_t *request)
{
	assert(request);
	return request->url;
}

/* IPHONE_MIRROR_AIRPLAY_PROTOCOL_COMPATIBILITY（上游 c788d6fe）：
 * 请求行的协议版本，回应时原样回；未解析完为 NULL。 */
const char *
http_request_get_protocol(http_request_t *request)
{
	assert(request);
	return request->protocol[0] != '\0' ? request->protocol : NULL;
}

const char *
http_request_get_header(http_request_t *request, const char *name)
{
	int i;

	assert(request);

	for (i=0; i<request->headers_size; i+=2) {
		/* 大小写不敏感匹配，见 iphone_mirror_header_name_equals 的说明。 */
		if (iphone_mirror_header_name_equals(request->headers[i], name)) {
			return request->headers[i+1];
		}
	}
	return NULL;
}

const char *
http_request_get_data(http_request_t *request, int *datalen)
{
	assert(request);

	if (datalen) {
		*datalen = request->datalen;
	}
	return request->data;
}

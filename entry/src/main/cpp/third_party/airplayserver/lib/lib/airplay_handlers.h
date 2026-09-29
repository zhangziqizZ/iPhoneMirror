/**
 *  Copyright (C) 2018  Juho Vähä-Herttua
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

#include "plist/include/plist.h"
#include <ctype.h>
#include <stdlib.h>
/* This file should be only included from raop.c as it defines static handler
 * functions and depends on raop internals */

typedef void (*airplay_handler_t)(airplay_conn_t *, http_request_t *,
                               http_response_t *, char **, int *);

static void
airplay_handler_pairsetup(airplay_conn_t* conn,
	http_request_t* request, http_response_t* response,
	char** response_data, int* response_datalen)
{
	unsigned char public_key[32];
	const char* data;
	int datalen;

	data = http_request_get_data(request, &datalen);
	if (datalen != 32) {
		logger_log(conn->airplay->logger, LOGGER_ERR, "Invalid pair-setup data");
		return;
	}

	pairing_get_public_key(conn->airplay->pairing, public_key);
	pairing_session_set_setup_status(conn->pairing);

	*response_data = malloc(sizeof(public_key));
	if (*response_data) {
		http_response_add_header(response, "Content-Type", "application/octet-stream");
		memcpy(*response_data, public_key, sizeof(public_key));
		*response_datalen = sizeof(public_key);
	}
}

static void
airplay_handler_pairverify(airplay_conn_t*conn,
                        http_request_t *request, http_response_t *response,
                        char **response_data, int *response_datalen)
{
    if (pairing_session_check_handshake_status(conn->pairing)) {
        return;
    }
	unsigned char public_key[32];
	unsigned char signature[64];
	const unsigned char *data;
	int datalen;

	data = (unsigned char *) http_request_get_data(request, &datalen);
	if (datalen < 4) {
		logger_log(conn->airplay->logger, LOGGER_ERR, "Invalid pair-verify data");
		return;
	}
	switch (data[0]) {
	case 1:
		if (datalen != 4 + 32 + 32) {
			logger_log(conn->airplay->logger, LOGGER_ERR, "Invalid pair-verify data");
			return;
		}
		/* We can fall through these errors, the result will just be garbage... */
		if (pairing_session_handshake(conn->pairing, data + 4, data + 4 + 32)) {
			logger_log(conn->airplay->logger, LOGGER_ERR, "Error initializing pair-verify handshake");
		}
		if (pairing_session_get_public_key(conn->pairing, public_key)) {
			logger_log(conn->airplay->logger, LOGGER_ERR, "Error getting ECDH public key");
		}
		if (pairing_session_get_signature(conn->pairing, signature)) {
			logger_log(conn->airplay->logger, LOGGER_ERR, "Error getting ED25519 signature");
		}
		*response_data = malloc(sizeof(public_key) + sizeof(signature));
		if (*response_data) {
			http_response_add_header(response, "Content-Type", "application/octet-stream");
			memcpy(*response_data, public_key, sizeof(public_key));
			memcpy(*response_data + sizeof(public_key), signature, sizeof(signature));
			*response_datalen = sizeof(public_key) + sizeof(signature);
		}
		break;
	case 0:
		if (datalen != 4 + 64) {
			logger_log(conn->airplay->logger, LOGGER_ERR, "Invalid pair-verify data");
			return;
		}

		if (pairing_session_finish(conn->pairing, data + 4)) {
			logger_log(conn->airplay->logger, LOGGER_ERR, "Incorrect pair-verify signature");
			http_response_set_disconnect(response, 1);
			return;
		}
        http_response_add_header(response, "Content-Type", "application/octet-stream");
		break;
	}
}

static void
airplay_handler_serverinfo(airplay_conn_t* conn,
	http_request_t* request, http_response_t* response,
	char** response_data, int* response_datalen)
{
	char deviceid[3 * MAX_HWADDR_LEN];
	memset(deviceid, 0, 3 * MAX_HWADDR_LEN);
	int ret = utils_hwaddr_airplay(deviceid, sizeof(deviceid), conn->airplay->hwaddr, conn->airplay->hwaddrlen);
	char* data = malloc(1024);
	sprintf(data, SERVER_INFO, deviceid, GLOBAL_FEATURES_1);
	*response_data = data;
	*response_datalen = strlen(data);
}

/*
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>mightSupportStorePastisKeyRequests</key>
	<true/>
	<key>playbackRestrictions</key>
	<integer>0</integer>
	<key>secureConnectionMs</key>
	<integer>0</integer>
	<key>volume</key>
	<real>1</real>
	<key>Start-Position-Seconds</key>
	<real>52.08</real>
	<key>Content-Location</key>
	<string>http://ltsbsy.qq.com/uwMROfz2r5zAoaQXGdGnC2df644E7D3uP8M8pmtgwsRK9nEL/UYFHlvRYICuMxpxBXMtvmS1Bvb9l8jHqaWffyqCGjZdTm_zlTa8tH49EikQ2MVtJIN33yVJCu-S5Xe5nLTOSxpafKJ4IZL2NjLyZpuCQOgAdU5Md9nRj0cBUew9wYMXr2HlLk4IN5nZOsMU4jP_AwQ5Tr9v0vCgZkkvLiUT2pfwIBaRVabftqw/p0026k7ecqy.321002.ts.m3u8?ver=4&amp;hlskey=empty&amp;sdtfrom=v3000</string>
	<key>uuid</key>
	<string>5477E3F6-E0A5-4CA6-9D80-AB68797FB0EA</string>
	<key>infoMs</key>
	<integer>471</integer>
	<key>streamType</key>
	<integer>1</integer>
	<key>connectMs</key>
	<integer>216</integer>
	<key>Start-Position</key>
	<real>0.01908838</real>
	<key>mediaType</key>
	<string>streaming</string>
	<key>authMs</key>
	<integer>0</integer>
	<key>bonjourMs</key>
	<integer>0</integer>
	<key>referenceRestrictions</key>
	<integer>0</integer>
	<key>SenderMACAddress</key>
	<string>64:9A:BE:47:25:17</string>
	<key>model</key>
	<string>iPhone7,2</string>
	<key>postAuthMs</key>
	<integer>0</integer>
	<key>clientBundleID</key>
	<string>com.tencent.live4iphone</string>
	<key>clientProcName</key>
	<string>live4iphone rel</string>
	<key>osBuildVersion</key>
	<string>16G161</string>
	<key>rate</key>
	<real>0</real>
</dict>
</plist>
*/
static int
airplay_plist_get_number(plist_t node, double* value)
{
	uint64_t integer_value = 0;

	if (value == NULL) {
		return 0;
	}
	if (PLIST_IS_REAL(node)) {
		plist_get_real_val(node, value);
		return 1;
	}
	if (PLIST_IS_UINT(node)) {
		plist_get_uint_val(node, &integer_value);
		*value = (double)integer_value;
		return 1;
	}
	return 0;
}

static void
airplay_handler_play(airplay_conn_t* conn,
	http_request_t* request, http_response_t* response,
	char** response_data, int* response_datalen)
{
	const char* data;
	int datalen;
	plist_t root_node = NULL;
	plist_t content_location_node;
	double start_pos = 0.0;
	double volume = 1.0;
	char* url = NULL;

	data = http_request_get_data(request, &datalen);
	if (data == NULL || datalen <= 0) {
		logger_log(conn->airplay->logger, LOGGER_WARNING, "Invalid /play request: empty payload");
		return;
	}

	plist_from_memory(data, (uint32_t)datalen, &root_node);
	if (!PLIST_IS_DICT(root_node)) {
		logger_log(conn->airplay->logger, LOGGER_WARNING, "Invalid /play request: payload is not a property-list dictionary");
		if (root_node != NULL) {
			plist_free(root_node);
		}
		return;
	}

	content_location_node = plist_dict_get_item(root_node, "Content-Location");
	if (!PLIST_IS_STRING(content_location_node)) {
		logger_log(conn->airplay->logger, LOGGER_WARNING, "Invalid /play request: missing Content-Location");
		plist_free(root_node);
		return;
	}

	plist_get_string_val(content_location_node, &url);
	if (url == NULL || url[0] == '\0') {
		logger_log(conn->airplay->logger, LOGGER_WARNING, "Invalid /play request: empty Content-Location");
		free(url);
		plist_free(root_node);
		return;
	}

	if (!airplay_plist_get_number(plist_dict_get_item(root_node, "Start-Position"), &start_pos)) {
		airplay_plist_get_number(plist_dict_get_item(root_node, "Start-Position-Seconds"), &start_pos);
	}
	airplay_plist_get_number(plist_dict_get_item(root_node, "volume"), &volume);

	if (conn->airplay->callbacks.video_play != NULL) {
		conn->airplay->callbacks.video_play(conn->airplay->callbacks.cls, url, volume, start_pos);
	}

	free(url);
	plist_free(root_node);
}

static void
airplay_handler_playbackinfo(airplay_conn_t* conn,
	http_request_t* request, http_response_t* response,
	char** response_data, int* response_datalen)
{
	double duration = 0;
	double position = 0;
	double rate = 0;
	if (conn->airplay->callbacks.video_get_play_info != NULL) {
		conn->airplay->callbacks.video_get_play_info(conn->airplay->callbacks.cls, &duration, &position, &rate);
	}

	char* data = malloc(1024);
	sprintf(data, PLAYBACK_INFO, duration, duration, position, rate, duration);
	*response_data = data;
	*response_datalen = strlen(data);
}

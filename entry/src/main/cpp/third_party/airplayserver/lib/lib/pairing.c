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

#include <stdlib.h>
#include <string.h>
#include <assert.h>

#include "pairing.h"
#include "curve25519/curve25519.h"
#include "ed25519/ed25519.h"
#include "ed25519/sha512.h"
#include "aes_ctr.h"

#define SALT_KEY "Pair-Verify-AES-Key"
#define SALT_IV "Pair-Verify-AES-IV"

struct pairing_s {
	unsigned char ed_private[64];
	unsigned char ed_public[32];
};

typedef enum {
	STATUS_INITIAL,
    STATUS_SETUP,
	STATUS_HANDSHAKE,
	STATUS_FINISHED
} status_t;

struct pairing_session_s {
	status_t status;

	unsigned char ed_private[64];
	unsigned char ed_ours[32];
	unsigned char ed_theirs[32];

	unsigned char ecdh_ours[32];
	unsigned char ecdh_theirs[32];
	unsigned char ecdh_secret[32];
};

static int
derive_key_internal(pairing_session_t *session, const unsigned char *salt, unsigned int saltlen, unsigned char *key, unsigned int keylen)
{
	sha512_context ctx;
	unsigned char hash[64];

	if (keylen > sizeof(hash)) {
		return -1;
	}
	sha512_init(&ctx);
	sha512_update(&ctx, salt, saltlen);
	sha512_update(&ctx, session->ecdh_secret, 32);
	sha512_final(&ctx, hash);

	memcpy(key, hash, keylen);
	return 0;
}

pairing_t *
pairing_init_generate()
{
	unsigned char seed[32];

	if (ed25519_create_seed(seed)) {
		return NULL;
	}
	return pairing_init_seed(seed);
}

pairing_t *
pairing_init_seed(const unsigned char seed[32])
{
	pairing_t *pairing;

	pairing = calloc(1, sizeof(pairing_t));
	if (!pairing) {
		return NULL;
	}

	ed25519_create_keypair(pairing->ed_public, pairing->ed_private, seed);
	return pairing;
}

void
pairing_get_public_key(pairing_t *pairing, unsigned char public_key[32])
{
	assert(pairing);

	memcpy(public_key, pairing->ed_public, 32);
}

void
pairing_get_ecdh_secret_key(pairing_session_t *session, unsigned char ecdh_secret[32])
{
	assert(session);
	memcpy(ecdh_secret, session->ecdh_secret, 32);
}


pairing_session_t *
pairing_session_init(pairing_t *pairing)
{
	pairing_session_t *session;

	if (!pairing) {
		return NULL;
	}

	session = calloc(1, sizeof(pairing_session_t));
	if (!session) {
		return NULL;
	}
	memcpy(session->ed_private, pairing->ed_private, 64);
	memcpy(session->ed_ours, pairing->ed_public, 32);
	session->status = STATUS_INITIAL;

	return session;
}

void
pairing_session_set_setup_status(pairing_session_t *session)
{
    assert(session);
    session->status = STATUS_SETUP;
}

int
pairing_session_check_handshake_status(pairing_session_t *session)
{
    assert(session);
    /* IPHONE_MIRROR_AIRPLAY_PAIR_VERIFY_TWO_STAGE（上游 c788d6fe）
     *
     * pair-verify 是**两段式**的，两段都打到同一个 handler：
     *   第 1 段（data[0]==1）：带客户端 ECDH/ED 公钥 → pairing_session_handshake()
     *                          把状态推到 STATUS_HANDSHAKE；
     *   第 2 段（data[0]==0）：带加密签名     → pairing_session_finish() 收尾。
     * 原版只放行 STATUS_SETUP，于是第 2 段在入口就被拒掉（直接 return，不回
     * 任何 body）—— iOS 拿到一个空的 pair-verify 响应即中止配对。
     * 表现同样是"设备搜得到、点进去连不上"。
     */
    if (session->status != STATUS_SETUP && session->status != STATUS_HANDSHAKE) {
        return -1;
    }
    return 0;
}

int
pairing_session_handshake(pairing_session_t *session, const unsigned char ecdh_key[32], const unsigned char ed_key[32])
{
	unsigned char ecdh_priv[32];

	assert(session);

	if (session->status == STATUS_FINISHED) {
		return -1;
	}
	if (ed25519_create_seed(ecdh_priv)) {
		return -2;
	}

	memcpy(session->ecdh_theirs, ecdh_key, 32);
	memcpy(session->ed_theirs, ed_key, 32);
	curve25519_donna(session->ecdh_ours, ecdh_priv, kCurve25519BasePoint);
	curve25519_donna(session->ecdh_secret, ecdh_priv, session->ecdh_theirs);

	session->status = STATUS_HANDSHAKE;
	return 0;
}

int
pairing_session_get_public_key(pairing_session_t *session, unsigned char ecdh_key[32])
{
	assert(session);

	if (session->status != STATUS_HANDSHAKE) {
		return -1;
	}

	memcpy(ecdh_key, session->ecdh_ours, 32);
	return 0;
}

int
pairing_session_get_signature(pairing_session_t *session, unsigned char signature[64])
{
	unsigned char sig_msg[64];
	unsigned char key[16];
	unsigned char iv[16];
	AES_CTR_CTX aes_ctx;

	assert(session);

	if (session->status != STATUS_HANDSHAKE) {
		return -1;
	}

	/* First sign the public ECDH keys of both parties */
	memcpy(&sig_msg[0], session->ecdh_ours, 32);
	memcpy(&sig_msg[32], session->ecdh_theirs, 32);

	ed25519_sign(signature, sig_msg, sizeof(sig_msg), session->ed_ours, session->ed_private);

	/* Then encrypt the result with keys derived from the shared secret */
	derive_key_internal(session, (const unsigned char *) SALT_KEY, strlen(SALT_KEY), key, sizeof(key));
	derive_key_internal(session, (const unsigned char *) SALT_IV, strlen(SALT_IV), iv, sizeof(key));
	AES_ctr_set_key(&aes_ctx, key, iv, AES_MODE_128);
	AES_ctr_encrypt(&aes_ctx, signature, signature, 64);
	return 0;
}

int
pairing_session_finish(pairing_session_t *session, const unsigned char signature[64])
{
	unsigned char sig_buffer[64];
	unsigned char sig_msg[64];
	unsigned char key[16];
	unsigned char iv[16];
	AES_CTR_CTX aes_ctx;

	assert(session);

	if (session->status != STATUS_HANDSHAKE) {
		return -1;
	}

	/* First decrypt the signature with keys derived from the shared secret */
	derive_key_internal(session, (const unsigned char *) SALT_KEY, strlen(SALT_KEY), key, sizeof(key));
	derive_key_internal(session, (const unsigned char *) SALT_IV, strlen(SALT_IV), iv, sizeof(key));
	AES_ctr_set_key(&aes_ctx, key, iv, AES_MODE_128);
	/* One fake round for the initial handshake encryption */
	AES_ctr_encrypt(&aes_ctx, sig_buffer, sig_buffer, 64);
	AES_ctr_encrypt(&aes_ctx, signature, sig_buffer, 64);

	/* Then verify the signature with public ECDH keys of both parties */
	memcpy(&sig_msg[0], session->ecdh_theirs, 32);
	memcpy(&sig_msg[32], session->ecdh_ours, 32);
	if (!ed25519_verify(sig_buffer, sig_msg, sizeof(sig_msg), session->ed_theirs)) {
		return -2;
	}

	session->status = STATUS_FINISHED;
	return 0;
}

void
pairing_session_destroy(pairing_session_t *session)
{
	free(session);
}

void
pairing_destroy(pairing_t *pairing)
{
	free(pairing);
}

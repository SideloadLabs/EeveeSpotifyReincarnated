#include "MediaDecode.h"
#include "OggExport.h"
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonHMAC.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

// The native key material has only been observed as an opaque 28-byte value.
// Different builds/call sites may order it as key||nonce or nonce||key, and the
// media layer may use the per-file SHA1 as its counter instead of librespot's
// fixed stream IV. The candidate list covers those bounded possibilities; a
// candidate is accepted only after a complete Ogg validation.
static const uint8_t kStreamIV[16] = {
    0x72, 0xe0, 0x67, 0xfb, 0xdd, 0xcb, 0xcf, 0x77,
    0xeb, 0xe8, 0xbc, 0x64, 0x3f, 0x63, 0x0d, 0x93
};

static void addBlocks(uint8_t counter[16], uint64_t blocks, int littleEndian) {
    if (!blocks) return;
    if (littleEndian) {
        for (int i = 0; i < 16 && blocks; i++) {
            blocks += counter[i];
            counter[i] = (uint8_t)blocks;
            blocks >>= 8;
        }
    } else {
        for (int i = 15; i >= 0 && blocks; i--) {
            blocks += counter[i];
            counter[i] = (uint8_t)blocks;
            blocks >>= 8;
        }
    }
}

typedef struct {
    CCCryptorRef aes;
    uint8_t counter[16];
    int littleEndian;
} SAPCounterCipher;

static int counterInit(SAPCounterCipher *state, const uint8_t *key, size_t keyLength, const uint8_t iv[16],
                       int littleEndian, uint64_t offset) {
    if (!state) return 0;
    memset(state, 0, sizeof(*state));
    state->littleEndian = littleEndian;
    memcpy(state->counter, iv, 16);
    addBlocks(state->counter, offset / 16, littleEndian);
    CCCryptorStatus status = CCCryptorCreateWithMode(kCCEncrypt, kCCModeECB, kCCAlgorithmAES,
                                                     ccNoPadding, NULL, key, (size_t)keyLength, NULL, 0, 0, 0, &state->aes);
    return status == kCCSuccess;
}

static void counterRelease(SAPCounterCipher *state) {
    if (state->aes) CCCryptorRelease(state->aes);
    memset(state, 0, sizeof(*state));
}

// XORs `length` bytes with the AES-CTR keystream starting at `offset`. This is
// deliberately an explicit counter implementation: CommonCrypto exposes only
// the big-endian CTR option, and the native key material may use a 32-bit
// little-endian counter after a 12-byte nonce.
static int counterXOR(SAPCounterCipher *state, uint8_t *buffer, size_t length, uint64_t offset) {
    if (!state || !state->aes || !buffer) return 0;
    uint8_t keystream[16], block[16];
    size_t skip = (size_t)(offset % 16);
    size_t at = 0;
    while (at < length) {
        size_t written = 0;
        memcpy(block, state->counter, 16);
        if (CCCryptorUpdate(state->aes, block, 16, keystream, sizeof(keystream), &written) != kCCSuccess ||
            written != 16) return 0;
        size_t take = 16 - skip;
        if (take > length - at) take = length - at;
        for (size_t i = 0; i < take; i++) buffer[at + i] ^= keystream[skip + i];
        at += take;
        skip = 0;
        addBlocks(state->counter, 1, state->littleEndian);
    }
    memset(keystream, 0, sizeof(keystream));
    memset(block, 0, sizeof(block));
    return 1;
}

int SAPMediaDecryptFileCancellable(FILE *input, FILE *output, const SAPMediaVariant *variant,SAPExportContinue keepGoing,void *context) {
    if (!input || !output || !variant) return 0;
    if (variant->skip > (uint64_t)LLONG_MAX || fseeko(input, (off_t)variant->skip, SEEK_SET)) return 0;
    SAPCounterCipher state;
    if (!counterInit(&state, variant->key, variant->keyLength, variant->iv, variant->little_endian, variant->counter)) return 0;
    uint8_t buffer[65536];
    uint64_t position = variant->counter;
    int ok = 1;
    size_t n;
    for (;;) {
        if(!SAPExportMayContinue(keepGoing,context)){ok=0;break;}
        n=fread(buffer,1,sizeof(buffer),input);if(!n)break;
        if (!counterXOR(&state, buffer, n, position) || fwrite(buffer, 1, n, output) != n) { ok = 0; break; }
        position += n;
    }
    if (ferror(input)) ok = 0;
    counterRelease(&state);
    memset(buffer, 0, sizeof(buffer));
    if (ok) ok = !fflush(output);
    return ok;
}

int SAPMediaPreview(FILE *input, const SAPMediaVariant *variant, uint64_t limit) {
    if (!input || !variant || !limit) return 0;
    if (variant->skip > (uint64_t)LLONG_MAX || fseeko(input, (off_t)variant->skip, SEEK_SET)) return 0;
    size_t capacity = (size_t)(limit > 512 * 1024 ? 512 * 1024 : limit);
    uint8_t *buffer = malloc(capacity);
    if (!buffer) return 0;
    size_t n = fread(buffer, 1, capacity, input);
    int found = 0;
    if (n >= 64 && !ferror(input)) {
        SAPCounterCipher state;
        if (counterInit(&state, variant->key, variant->keyLength, variant->iv, variant->little_endian, variant->counter)) {
            if (counterXOR(&state, buffer, n, variant->counter)) found = SAPOggBufferHasVorbisBOS(buffer, n, NULL);
            counterRelease(&state);
        }
    }
    memset(buffer, 0, capacity);
    free(buffer);
    return found;
}

static void hmacSHA1(const uint8_t *key, size_t keyLength, const uint8_t *bytes, size_t length, uint8_t out[20]) {
    CCHmac(kCCHmacAlgSHA1, key, keyLength, bytes, length, out);
}

static void sha1Bytes(const uint8_t *bytes, size_t length, uint8_t out[20]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1(bytes, (CC_LONG)length, out);
#pragma clang diagnostic pop
}

static void descriptorIV(const uint8_t fileID[20], uint32_t kind, uint32_t index, uint8_t out[16]) {
    memcpy(out, fileID, 16);
    out[0] ^= (uint8_t)kind;
    out[2] ^= (uint8_t)(index >> 8);
    out[3] ^= (uint8_t)index;
}

static void foldedIV(const uint8_t *bytes, size_t length, uint8_t out[16]) {
    uint8_t buffer[64];memset(buffer,0,sizeof(buffer));
    if(length>64)length=64;memcpy(buffer,bytes,length);
    for(size_t i=16;i<length;i++)buffer[i]^=buffer[i-16];
    memcpy(out,buffer,16);memset(buffer,0,sizeof(buffer));
}
static void nonceIV(const uint8_t *nonce, size_t length, uint8_t out[16]) {
    memset(out, 0, 16);
    if (nonce && length) memcpy(out, nonce, length > 16 ? 16 : length);
}

typedef struct {
    uint8_t key[32];
    uint8_t length;
    const char *keyLabel;
} KeyChoice;

typedef struct {
    uint8_t iv[16];
    const char *ivLabel;
} IVChoice;

static int sameVariant(const SAPMediaVariant *a, const SAPMediaVariant *b) {
    return a->little_endian == b->little_endian && a->skip == b->skip && a->counter == b->counter && a->keyLength == b->keyLength &&
           !memcmp(a->key, b->key, 32) && !memcmp(a->iv, b->iv, 16);
}

static size_t appendVariant(SAPMediaVariant *out, size_t count, size_t capacity,
                            const uint8_t *key, uint8_t keyLength, const uint8_t iv[16],
                            int littleEndian, uint64_t skip, uint64_t counter, const char *keyLabel, const char *ivLabel) {
    if (count >= capacity || keyLength > 32) return count;
    SAPMediaVariant candidate;
    memset(candidate.key, 0, sizeof(candidate.key));
    memcpy(candidate.key, key, keyLength);
    candidate.keyLength = keyLength;
    memcpy(candidate.iv, iv, 16);
    candidate.little_endian = littleEndian;
    candidate.skip = skip;
    candidate.counter = counter;
    candidate.keyLabel = keyLabel;
    candidate.ivLabel = ivLabel;
    for (size_t i = 0; i < count; i++) if (sameVariant(&out[i], &candidate)) return count;
    out[count] = candidate;
    return count + 1;
}

size_t SAPMediaBuildVariants(const uint8_t fileID[20], uint32_t kind, uint32_t index,
                             const uint8_t *callbackKey16,
                             const uint8_t *nativeBlob28,
                             const uint8_t *keys24, size_t key24Count,
                             const uint8_t *contexts, const uint8_t *contextLengths, size_t contextCount,
                             SAPMediaVariant *out, size_t capacity) {
    if (!fileID || !out || !capacity) return 0;
    KeyChoice keys[12];
    size_t keyCount = 0;
    if (callbackKey16) {
        memcpy(keys[keyCount].key, callbackKey16, 16);
        keys[keyCount].length = 16;
        keys[keyCount++].keyLabel = "callback";
    }
    if (nativeBlob28) {
        memcpy(keys[keyCount].key, nativeBlob28, 16);
        keys[keyCount].length = 16;
        keys[keyCount++].keyLabel = "blob0";
        memcpy(keys[keyCount].key, nativeBlob28 + 4, 16);
        keys[keyCount].length = 16;
        keys[keyCount++].keyLabel = "blob4";
        memcpy(keys[keyCount].key, nativeBlob28 + 12, 16);
        keys[keyCount].length = 16;
        keys[keyCount++].keyLabel = "blob12";
        memset(keys[keyCount].key, 0, 32);
        memcpy(keys[keyCount].key, nativeBlob28 + 16, 12);
        keys[keyCount].length = 16;
        keys[keyCount++].keyLabel = "blob16";
        memcpy(keys[keyCount].key, nativeBlob28, 24);
        keys[keyCount].length = 24;
        keys[keyCount++].keyLabel = "blob24";
    }
    for (size_t i = 0; i < key24Count && i < 6 && keyCount < 12; i++) {
        memcpy(keys[keyCount].key, keys24 + i * 24, 24);
        keys[keyCount].length = 24;
        keys[keyCount++].keyLabel = "native24";
    }

    uint8_t fileSHA[20];
    sha1Bytes(fileID, 20, fileSHA);
    uint8_t descIV[16];
    descriptorIV(fileID, kind, index, descIV);

    IVChoice ivs[12];
    size_t ivCount = 0;
    memcpy(ivs[ivCount].iv, kStreamIV, 16); ivs[ivCount++].ivLabel = "stream";
    memcpy(ivs[ivCount].iv, fileSHA, 16); ivs[ivCount++].ivLabel = "sha1";
    memcpy(ivs[ivCount].iv, fileSHA + 4, 16); ivs[ivCount++].ivLabel = "sha1_4";
    memcpy(ivs[ivCount].iv, fileID, 16); ivs[ivCount++].ivLabel = "fileid";
    memcpy(ivs[ivCount].iv, descIV, 16); ivs[ivCount++].ivLabel = "descriptor";
    memset(ivs[ivCount].iv, 0, 16); ivs[ivCount++].ivLabel = "zero";
    if (nativeBlob28) {
        memcpy(ivs[ivCount].iv, nativeBlob28, 16); ivs[ivCount++].ivLabel = "blob0";
        memcpy(ivs[ivCount].iv, nativeBlob28 + 4, 16); ivs[ivCount++].ivLabel = "blob4";
        memcpy(ivs[ivCount].iv, nativeBlob28 + 12, 16); ivs[ivCount++].ivLabel = "blob12";
        nonceIV(nativeBlob28, 12, ivs[ivCount].iv); ivs[ivCount++].ivLabel = "nonce0";
        nonceIV(nativeBlob28 + 4, 12, ivs[ivCount].iv); ivs[ivCount++].ivLabel = "nonce4";
        nonceIV(nativeBlob28 + 16, 12, ivs[ivCount].iv); ivs[ivCount++].ivLabel = "nonce16";
    }

    static const uint64_t skips[] = {0, 20, 167, 16512, 16512 + 167};
    size_t count = 0;

    // A cached file may start with a plaintext Spotify/aux prefix while the
    // encrypted media counter starts at zero. Try both "counter follows the
    // source offset" and "counter starts at zero after the prefix".
    static const int counterModes[2] = {0, 1}; // 0 = counter == skip, 1 = counter 0
    if (callbackKey16) {
        count = appendVariant(out, count, capacity, callbackKey16, 16, kStreamIV, 0, 0, 0, "callback", "stream");
    }
    for (size_t k = 0; k < keyCount; k++) {
        uint8_t hmac[20], material[64], catHash[20];
        hmacSHA1(keys[k].key, keys[k].length, fileID, 20, hmac);
        memcpy(material, keys[k].key, keys[k].length);
        memcpy(material + keys[k].length, fileID, 20);
        sha1Bytes(material, keys[k].length + 20, catHash);
        for (size_t s = 0; s < sizeof(skips) / sizeof(skips[0]); s++) {
            for (size_t c = 0; c < 2; c++) {
                if (skips[s] == 0 && counterModes[c] == 1) continue;
                uint64_t counter = counterModes[c] ? 0 : skips[s];
                uint8_t iv[16];
                memcpy(iv, hmac, 16);
                count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, iv, 0, skips[s], counter, keys[k].keyLabel, "hmac");
                count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, iv, 1, skips[s], counter, keys[k].keyLabel, "hmac");
                memcpy(iv, hmac + 4, 16);
                count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, iv, 0, skips[s], counter, keys[k].keyLabel, "hmac4");
                count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, iv, 1, skips[s], counter, keys[k].keyLabel, "hmac4");
                memcpy(iv, catHash, 16);
                count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, iv, 0, skips[s], counter, keys[k].keyLabel, "sha1cat");
                count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, iv, 1, skips[s], counter, keys[k].keyLabel, "sha1cat");
            }
        }
    }
    for (size_t k = 0; k < keyCount; k++) {
        for (size_t q = 0; q < contextCount && q < 4; q++) {
            size_t length = contextLengths ? contextLengths[q] : 0;
            const uint8_t *context = contexts + q * 64;
            if (!length || length > 64) continue;
            uint8_t ctxIV[16], ctxHash[20], material[96], catHash[20];
            memcpy(ctxIV, context, length >= 16 ? 16 : length);
            if (length < 16) memset(ctxIV + length, 0, 16 - length);
            foldedIV(context, length, ctxHash);
            sha1Bytes(context, length, catHash);
            for (size_t s = 0; s < sizeof(skips) / sizeof(skips[0]); s++) {
                for (size_t c = 0; c < 2; c++) {
                    if (skips[s] == 0 && counterModes[c] == 1) continue;
                    uint64_t counter = counterModes[c] ? 0 : skips[s];
                    count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, ctxIV, 0, skips[s], counter, keys[k].keyLabel, "ctx");
                    count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, ctxIV, 1, skips[s], counter, keys[k].keyLabel, "ctx");
                    count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, ctxHash, 0, skips[s], counter, keys[k].keyLabel, "ctxfold");
                    count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, ctxHash, 1, skips[s], counter, keys[k].keyLabel, "ctxfold");
                    count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, catHash, 0, skips[s], counter, keys[k].keyLabel, "ctxsha1");
                    count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, catHash, 1, skips[s], counter, keys[k].keyLabel, "ctxsha1");
                    memcpy(material, catHash + 4, 16);
                    count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, material, 0, skips[s], counter, keys[k].keyLabel, "ctxsha1_4");
                    count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, material, 1, skips[s], counter, keys[k].keyLabel, "ctxsha1_4");
                }
            }
        }
    }
    for (size_t k = 0; k < keyCount; k++) {
        for (size_t v = 0; v < ivCount; v++) {
            for (size_t s = 0; s < sizeof(skips) / sizeof(skips[0]); s++) {
                for (size_t c = 0; c < 2; c++) {
                    if (skips[s] == 0 && counterModes[c] == 1) continue;
                    uint64_t counter = counterModes[c] ? 0 : skips[s];
                    count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, ivs[v].iv, 0, skips[s], counter, keys[k].keyLabel, ivs[v].ivLabel);
                    count = appendVariant(out, count, capacity, keys[k].key, keys[k].length, ivs[v].iv, 1, skips[s], counter, keys[k].keyLabel, ivs[v].ivLabel);
                }
            }
        }
    }
    return count;
}

int SAPMediaDecryptFile(FILE *input,FILE *output,const SAPMediaVariant *variant) {return SAPMediaDecryptFileCancellable(input,output,variant,NULL,NULL);}

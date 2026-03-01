/// LZHUF compression for the Winlink B2F protocol.
///
/// C implementation faithful to wl2k-go/lzhuf (la5nta/wl2k-go, MIT License).
/// Original algorithm by Haruhiko Okumura / Haruyasu Yoshizaki (1989).
///
/// References:
///   - https://github.com/la5nta/wl2k-go/tree/master/lzhuf
///   - https://github.com/la5nta/pat (Winlink client)

#ifndef LZHUF_H
#define LZHUF_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Compress data using LZHUF.
/// Output format: [4-byte LE filesize] [compressed data]
/// Returns allocated buffer (caller must free), or NULL on error.
/// *out_len is set to the output length.
uint8_t *lzhuf_compress(const uint8_t *data, size_t data_len, size_t *out_len);

/// Decompress LZHUF data.
/// Input format: [4-byte LE filesize] [compressed data]
/// Returns allocated buffer (caller must free), or NULL on error.
/// *out_len is set to the decompressed length.
uint8_t *lzhuf_decompress(const uint8_t *data, size_t data_len, size_t *out_len);

/// Compute CRC-16 CCITT (Xmodem variant) used by Winlink B2F.
/// Includes 2 trailing zero bytes as per wl2k-go convention.
uint16_t lzhuf_crc16(const uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* LZHUF_H */

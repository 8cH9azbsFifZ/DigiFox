/// LZHUF compression for the Winlink B2F protocol.
///
/// Original algorithm: Haruhiko Okumura, LZHUF (ar002), 1988–1989.
/// Public domain: "Use, distribute, and modify this program freely."
/// Ref: https://oku.edu.mie-u.ac.jp/~okumura/compression/lzhuf.c
///
/// This C implementation is a faithful port of the Go version from wl2k-go:
///   Martin Hebnes Pedersen (LA5NTA), MIT License
///   https://github.com/la5nta/wl2k-go/tree/master/lzhuf
///
/// Used by Pat (la5nta/pat), the open-source Winlink client:
///   https://github.com/la5nta/pat
///
/// Constants (N=2048, F=60, Threshold=2) must match wl2k-go exactly
/// for Winlink CMS interoperability.

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

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
/// CRC-16 CCITT (Xmodem variant) table from wl2k-go/lzhuf/crc.go,
/// originally identified by Maiko Langelaar (VE4KLM) as the checksum
/// used by Airmail and Winlink 2000.
///
/// Constants (N=2048, F=60, Threshold=2) must match wl2k-go exactly
/// for Winlink CMS interoperability.

#include "lzhuf.h"
#include <stdlib.h>
#include <string.h>

// LZHUF constants (must match wl2k-go)
#define LZ_N         2048
#define LZ_F         60
#define LZ_THRESHOLD 2
#define LZ_NIL       LZ_N
#define LZ_NCHAR     (256 - LZ_THRESHOLD + LZ_F)  // 314
#define LZ_T         (LZ_NCHAR * 2 - 1)            // 627
#define LZ_R         (LZ_T - 1)                     // 626
#define LZ_MAXFREQ   0x8000

// State
typedef struct {
    unsigned int freq[LZ_T + 1];
    int prnt[LZ_T + LZ_NCHAR];
    int son[LZ_T];
    int dad[LZ_N + 1];
    int lson_arr[LZ_N + 1];
    int rson[LZ_N + 257];
    unsigned char text_buf[LZ_N + LZ_F - 1];
    int match_length;
    int match_position;

    // Bit I/O (must be 64-bit to match Go's uint)
    uint64_t putbuf;
    unsigned char putlen;
    uint64_t getbuf;
    unsigned char getlen;

    // Stream I/O
    const unsigned char *in_data;
    size_t in_len;
    size_t in_pos;
    unsigned char *out_data;
    size_t out_len;
    size_t out_cap;
} lzhuf_state;

// Position tables (from wl2k-go, verified against C reference)
static const unsigned char p_code[64] = {
    0x00, 0x20, 0x30, 0x40, 0x50, 0x58, 0x60, 0x68,
    0x70, 0x78, 0x80, 0x88, 0x90, 0x94, 0x98, 0x9C,
    0xA0, 0xA4, 0xA8, 0xAC, 0xB0, 0xB4, 0xB8, 0xBC,
    0xC0, 0xC2, 0xC4, 0xC6, 0xC8, 0xCA, 0xCC, 0xCE,
    0xD0, 0xD2, 0xD4, 0xD6, 0xD8, 0xDA, 0xDC, 0xDE,
    0xE0, 0xE2, 0xE4, 0xE6, 0xE8, 0xEA, 0xEC, 0xEE,
    0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7,
    0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
};

static const unsigned char p_len[64] = {
    0x03, 0x04, 0x04, 0x04, 0x05, 0x05, 0x05, 0x05,
    0x05, 0x05, 0x05, 0x05, 0x06, 0x06, 0x06, 0x06,
    0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08,
    0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08,
};

static const unsigned char d_code[256] = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
    0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09,
    0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B,
    0x0C, 0x0C, 0x0C, 0x0C, 0x0D, 0x0D, 0x0D, 0x0D, 0x0E, 0x0E, 0x0E, 0x0E, 0x0F, 0x0F, 0x0F, 0x0F,
    0x10, 0x10, 0x10, 0x10, 0x11, 0x11, 0x11, 0x11, 0x12, 0x12, 0x12, 0x12, 0x13, 0x13, 0x13, 0x13,
    0x14, 0x14, 0x14, 0x14, 0x15, 0x15, 0x15, 0x15, 0x16, 0x16, 0x16, 0x16, 0x17, 0x17, 0x17, 0x17,
    0x18, 0x18, 0x19, 0x19, 0x1A, 0x1A, 0x1B, 0x1B, 0x1C, 0x1C, 0x1D, 0x1D, 0x1E, 0x1E, 0x1F, 0x1F,
    0x20, 0x20, 0x21, 0x21, 0x22, 0x22, 0x23, 0x23, 0x24, 0x24, 0x25, 0x25, 0x26, 0x26, 0x27, 0x27,
    0x28, 0x28, 0x29, 0x29, 0x2A, 0x2A, 0x2B, 0x2B, 0x2C, 0x2C, 0x2D, 0x2D, 0x2E, 0x2E, 0x2F, 0x2F,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
};

static const unsigned char d_len[256] = {
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
    0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
    0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
    0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
    0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
    0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
    0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
    0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
    0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
    0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08,
};

// CRC-16 CCITT table (Xmodem variant, from wl2k-go)
static const uint16_t crc16_tab[256] = {
    0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50a5, 0x60c6, 0x70e7,
    0x8108, 0x9129, 0xa14a, 0xb16b, 0xc18c, 0xd1ad, 0xe1ce, 0xf1ef,
    0x1231, 0x0210, 0x3273, 0x2252, 0x52b5, 0x4294, 0x72f7, 0x62d6,
    0x9339, 0x8318, 0xb37b, 0xa35a, 0xd3bd, 0xc39c, 0xf3ff, 0xe3de,
    0x2462, 0x3443, 0x0420, 0x1401, 0x64e6, 0x74c7, 0x44a4, 0x5485,
    0xa56a, 0xb54b, 0x8528, 0x9509, 0xe5ee, 0xf5cf, 0xc5ac, 0xd58d,
    0x3653, 0x2672, 0x1611, 0x0630, 0x76d7, 0x66f6, 0x5695, 0x46b4,
    0xb75b, 0xa77a, 0x9719, 0x8738, 0xf7df, 0xe7fe, 0xd79d, 0xc7bc,
    0x48c4, 0x58e5, 0x6886, 0x78a7, 0x0840, 0x1861, 0x2802, 0x3823,
    0xc9cc, 0xd9ed, 0xe98e, 0xf9af, 0x8948, 0x9969, 0xa90a, 0xb92b,
    0x5af5, 0x4ad4, 0x7ab7, 0x6a96, 0x1a71, 0x0a50, 0x3a33, 0x2a12,
    0xdbfd, 0xcbdc, 0xfbbf, 0xeb9e, 0x9b79, 0x8b58, 0xbb3b, 0xab1a,
    0x6ca6, 0x7c87, 0x4ce4, 0x5cc5, 0x2c22, 0x3c03, 0x0c60, 0x1c41,
    0xedae, 0xfd8f, 0xcdec, 0xddcd, 0xad2a, 0xbd0b, 0x8d68, 0x9d49,
    0x7e97, 0x6eb6, 0x5ed5, 0x4ef4, 0x3e13, 0x2e32, 0x1e51, 0x0e70,
    0xff9f, 0xefbe, 0xdfdd, 0xcffc, 0xbf1b, 0xaf3a, 0x9f59, 0x8f78,
    0x9188, 0x81a9, 0xb1ca, 0xa1eb, 0xd10c, 0xc12d, 0xf14e, 0xe16f,
    0x1080, 0x00a1, 0x30c2, 0x20e3, 0x5004, 0x4025, 0x7046, 0x6067,
    0x83b9, 0x9398, 0xa3fb, 0xb3da, 0xc33d, 0xd31c, 0xe37f, 0xf35e,
    0x02b1, 0x1290, 0x22f3, 0x32d2, 0x4235, 0x5214, 0x6277, 0x7256,
    0xb5ea, 0xa5cb, 0x95a8, 0x8589, 0xf56e, 0xe54f, 0xd52c, 0xc50d,
    0x34e2, 0x24c3, 0x14a0, 0x0481, 0x7466, 0x6447, 0x5424, 0x4405,
    0xa7db, 0xb7fa, 0x8799, 0x97b8, 0xe75f, 0xf77e, 0xc71d, 0xd73c,
    0x26d3, 0x36f2, 0x0691, 0x16b0, 0x6657, 0x7676, 0x4615, 0x5634,
    0xd94c, 0xc96d, 0xf90e, 0xe92f, 0x99c8, 0x89e9, 0xb98a, 0xa9ab,
    0x5844, 0x4865, 0x7806, 0x6827, 0x18c0, 0x08e1, 0x3882, 0x28a3,
    0xcb7d, 0xdb5c, 0xeb3f, 0xfb1e, 0x8bf9, 0x9bd8, 0xabbb, 0xbb9a,
    0x4a75, 0x5a54, 0x6a37, 0x7a16, 0x0af1, 0x1ad0, 0x2ab3, 0x3a92,
    0xfd2e, 0xed0f, 0xdd6c, 0xcd4d, 0xbdaa, 0xad8b, 0x9de8, 0x8dc9,
    0x7c26, 0x6c07, 0x5c64, 0x4c45, 0x3ca2, 0x2c83, 0x1ce0, 0x0cc1,
    0xef1f, 0xff3e, 0xcf5d, 0xdf7c, 0xaf9b, 0xbfba, 0x8fd9, 0x9ff8,
    0x6e17, 0x7e36, 0x4e55, 0x5e74, 0x2e93, 0x3eb2, 0x0ed1, 0x1ef0,
};

// --- Output buffer management ---

static void out_byte(lzhuf_state *s, unsigned char b) {
    if (s->out_len >= s->out_cap) {
        s->out_cap = s->out_cap ? s->out_cap * 2 : 256;
        s->out_data = (unsigned char *)realloc(s->out_data, s->out_cap);
    }
    s->out_data[s->out_len++] = b;
}

static int in_byte(lzhuf_state *s) {
    if (s->in_pos >= s->in_len) return -1;
    return s->in_data[s->in_pos++];
}

// --- Huffman tree init (matches wl2k-go newLZHUFF) ---

static void init_tree(lzhuf_state *s) {
    for (int i = 0; i < LZ_NCHAR; i++) {
        s->freq[i] = 1;
        s->son[i] = i + LZ_T;
        s->prnt[i + LZ_T] = i;
    }
    int i = 0, j = LZ_NCHAR;
    while (j <= LZ_R) {
        s->freq[j] = s->freq[i] + s->freq[i + 1];
        s->son[j] = i;
        s->prnt[i] = j;
        s->prnt[i + 1] = j;
        i += 2;
        j++;
    }
    s->freq[LZ_T] = 0xFFFF;
    s->prnt[LZ_R] = 0;

    for (int i = LZ_N + 1; i <= LZ_N + 256; i++)
        s->rson[i] = LZ_NIL;
    for (int i = 0; i < LZ_N; i++)
        s->dad[i] = LZ_NIL;

    memset(s->text_buf, ' ', LZ_N + LZ_F - 1);
}

// --- Huffman tree operations (matches wl2k-go reconst/update) ---

static void reconst(lzhuf_state *s) {
    int j = 0;
    for (int i = 0; i < LZ_T; i++) {
        if (s->son[i] >= LZ_T) {
            s->freq[j] = (s->freq[i] + 1) / 2;
            s->son[j] = s->son[i];
            j++;
        }
    }

    for (int i = 0, jj = LZ_NCHAR; jj < LZ_T; i += 2, jj++) {
        int k = i + 1;
        unsigned int f = s->freq[i] + s->freq[k];
        s->freq[jj] = f;
        for (k = jj; f < s->freq[k - 1]; k--) {}
        int last = jj - k;
        memmove(&s->freq[k + 1], &s->freq[k], last * sizeof(s->freq[0]));
        s->freq[k] = f;
        memmove(&s->son[k + 1], &s->son[k], last * sizeof(s->son[0]));
        s->son[k] = i;
    }

    for (int i = 0; i < LZ_T; i++) {
        int k = s->son[i];
        if (k >= LZ_T) {
            s->prnt[k] = i;
        } else {
            s->prnt[k] = i;
            s->prnt[k + 1] = i;
        }
    }
}

static void update(lzhuf_state *s, int c) {
    if (s->freq[LZ_R] == LZ_MAXFREQ)
        reconst(s);

    c = s->prnt[c + LZ_T];
    for (;;) {
        s->freq[c]++;

        if (s->freq[c] <= s->freq[c + 1] || c + 2 > LZ_T) {
            c = s->prnt[c];
            if (c == 0) break;
            continue;
        }

        int l = c + 1;
        unsigned int k = s->freq[c];
        while (k > s->freq[l + 1]) l++;

        s->freq[c] = s->freq[l];
        s->freq[l] = k;

        int i = s->son[c];
        s->prnt[i] = l;
        if (i < LZ_T) s->prnt[i + 1] = l;

        int jj = s->son[l];
        s->son[l] = i;
        s->prnt[jj] = c;
        if (jj < LZ_T) s->prnt[jj + 1] = c;
        s->son[c] = jj;

        c = s->prnt[l];
        if (c == 0) break;
    }
}

// --- LZ77 tree operations (matches wl2k-go InsertNode/DeleteNode) ---

static void insert_node(lzhuf_state *s, int r) {
    int cmp = 1;
    unsigned char *key = &s->text_buf[r];
    int p = LZ_N + 1 + key[0];
    s->rson[r] = s->lson_arr[r] = LZ_NIL;
    s->match_length = 0;

    for (;;) {
        if (cmp >= 0) {
            if (s->rson[p] != LZ_NIL) p = s->rson[p];
            else { s->rson[p] = r; s->dad[r] = p; return; }
        } else {
            if (s->lson_arr[p] != LZ_NIL) p = s->lson_arr[p];
            else { s->lson_arr[p] = r; s->dad[r] = p; return; }
        }

        int i;
        for (i = 1; i < LZ_F; i++) {
            cmp = (int)key[i] - (int)s->text_buf[p + i];
            if (cmp != 0) break;
        }

        if (i > LZ_THRESHOLD) {
            if (i > s->match_length) {
                s->match_position = ((r - p) & (LZ_N - 1)) - 1;
                s->match_length = i;
                if (s->match_length >= LZ_F) break;
            }
            if (i == s->match_length) {
                unsigned int c = (unsigned int)(((r - p) & (LZ_N - 1)) - 1);
                if ((int)c < s->match_position)
                    s->match_position = (int)c;
            }
        }
    }

    s->dad[r] = s->dad[p];
    s->lson_arr[r] = s->lson_arr[p];
    s->rson[r] = s->rson[p];
    s->dad[s->lson_arr[p]] = r;
    s->dad[s->rson[p]] = r;
    if (s->rson[s->dad[p]] == p)
        s->rson[s->dad[p]] = r;
    else
        s->lson_arr[s->dad[p]] = r;
    s->dad[p] = LZ_NIL;
}

static void delete_node(lzhuf_state *s, int p) {
    if (s->dad[p] == LZ_NIL) return;

    int q;
    if (s->rson[p] == LZ_NIL) {
        q = s->lson_arr[p];
    } else if (s->lson_arr[p] == LZ_NIL) {
        q = s->rson[p];
    } else {
        q = s->lson_arr[p];
        if (s->rson[q] != LZ_NIL) {
            while (s->rson[q] != LZ_NIL) q = s->rson[q];
            s->rson[s->dad[q]] = s->lson_arr[q];
            s->dad[s->lson_arr[q]] = s->dad[q];
            s->lson_arr[q] = s->lson_arr[p];
            s->dad[s->lson_arr[p]] = q;
        }
        s->rson[q] = s->rson[p];
        s->dad[s->rson[p]] = q;
    }

    s->dad[q] = s->dad[p];
    if (s->rson[s->dad[p]] == p)
        s->rson[s->dad[p]] = q;
    else
        s->lson_arr[s->dad[p]] = q;
    s->dad[p] = LZ_NIL;
}

// --- Bit I/O (matches wl2k-go putCode/getBit/getByte) ---

static void put_code(lzhuf_state *s, int l, uint64_t c) {
    s->putbuf |= c >> s->putlen;
    s->putlen += (unsigned char)l;
    if (s->putlen >= 8) {
        out_byte(s, (unsigned char)(s->putbuf >> 8));
        s->putlen -= 8;
        if (s->putlen >= 8) {
            out_byte(s, (unsigned char)(s->putbuf & 0xFF));
            s->putlen -= 8;
            s->putbuf = c << (uint64_t)(l - (int)s->putlen);
        } else {
            s->putbuf <<= 8;
        }
    }
}

static int get_bit(lzhuf_state *s) {
    while (s->getlen <= 8) {
        int i = in_byte(s);
        s->getbuf |= (uint64_t)(i < 0 ? 0 : i) << (8 - s->getlen);
        s->getlen += 8;
    }
    int bit = (int)((s->getbuf >> 15) & 1);
    s->getbuf <<= 1;
    s->getlen--;
    return bit;
}

static int get_byte_val(lzhuf_state *s) {
    while (s->getlen <= 8) {
        int i = in_byte(s);
        s->getbuf |= (uint64_t)(i < 0 ? 0 : i) << (8 - s->getlen);
        s->getlen += 8;
    }
    int b = (int)(s->getbuf >> 8) & 0xFF;
    s->getbuf <<= 8;
    s->getlen -= 8;
    return b;
}

// --- Huffman encode/decode ---

static void encode_char(lzhuf_state *s, int c) {
    uint64_t code = 0;
    int len = 0;
    int k = s->prnt[c + LZ_T];
    do {
        code >>= 1;
        if (k & 1) code |= 0x8000;
        len++;
        k = s->prnt[k];
    } while (k != LZ_R);
    put_code(s, len, code);
    update(s, c);
}

static void encode_position(lzhuf_state *s, int c) {
    int i = c >> 6;
    put_code(s, (int)p_len[i], (uint64_t)p_code[i] << 8);
    put_code(s, 6, (uint64_t)(c & 0x3F) << 10);
}

static int decode_char(lzhuf_state *s) {
    int c = s->son[LZ_R];
    while (c < LZ_T) {
        c += get_bit(s);
        c = s->son[c];
    }
    c -= LZ_T;
    update(s, c);
    return c;
}

static int decode_position(lzhuf_state *s) {
    unsigned int i = (unsigned int)get_byte_val(s);
    unsigned int c = (unsigned int)d_code[i] << 6;
    int j = (int)d_len[i] - 2;
    while (j-- > 0)
        i = (i << 1) | (unsigned int)get_bit(s);
    return (int)(c | (i & 0x3F));
}

// --- Compress ---

static void do_encode(lzhuf_state *s) {
    int r = LZ_N - LZ_F, spos = 0, len = 0;

    // Fill lookahead buffer
    while (len < LZ_F) {
        int c = in_byte(s);
        if (c < 0) break;
        s->text_buf[r + len] = (unsigned char)c;
        len++;
    }
    if (len == 0) return;

    // Insert initial nodes
    for (int i = 1; i <= LZ_F; i++)
        insert_node(s, r - i);
    insert_node(s, r);

    do {
        if (s->match_length > len)
            s->match_length = len;

        if (s->match_length <= LZ_THRESHOLD) {
            s->match_length = 1;
            encode_char(s, (int)s->text_buf[r]);
        } else {
            encode_char(s, 256 - LZ_THRESHOLD + s->match_length);
            encode_position(s, s->match_position);
        }

        int last_ml = s->match_length;
        int i;
        for (i = 0; i < last_ml; i++) {
            int c = in_byte(s);
            if (c < 0) break;
            delete_node(s, spos);
            s->text_buf[spos] = (unsigned char)c;
            if (spos < LZ_F - 1)
                s->text_buf[spos + LZ_N] = (unsigned char)c;
            spos = (spos + 1) & (LZ_N - 1);
            r = (r + 1) & (LZ_N - 1);
            insert_node(s, r);
        }
        while (i++ < last_ml) {
            delete_node(s, spos);
            spos = (spos + 1) & (LZ_N - 1);
            r = (r + 1) & (LZ_N - 1);
            if (--len > 0)
                insert_node(s, r);
        }
    } while (len > 0);

    if (s->putlen > 0)
        out_byte(s, (unsigned char)(s->putbuf >> 8));
}

uint8_t *lzhuf_compress(const uint8_t *data, size_t data_len, size_t *out_len) {
    lzhuf_state *s = (lzhuf_state *)calloc(1, sizeof(lzhuf_state));
    if (!s) return NULL;

    s->in_data = data;
    s->in_len = data_len;
    s->in_pos = 0;
    s->out_data = NULL;
    s->out_len = 0;
    s->out_cap = 0;

    init_tree(s);

    // Write 4-byte LE filesize header
    uint32_t size = (uint32_t)data_len;
    out_byte(s, (unsigned char)(size & 0xFF));
    out_byte(s, (unsigned char)((size >> 8) & 0xFF));
    out_byte(s, (unsigned char)((size >> 16) & 0xFF));
    out_byte(s, (unsigned char)((size >> 24) & 0xFF));

    if (data_len > 0)
        do_encode(s);

    uint8_t *result = s->out_data;
    *out_len = s->out_len;
    free(s);
    return result;
}

// --- Decompress ---

static void do_decode(lzhuf_state *s, int32_t original_size) {
    int r = LZ_N - LZ_F;
    memset(s->text_buf, ' ', LZ_N + LZ_F - 1);
    int count = 0;

    while (count < original_size) {
        int c = decode_char(s);
        if (c < 256) {
            unsigned char b = (unsigned char)c;
            out_byte(s, b);
            s->text_buf[r] = b;
            r = (r + 1) & (LZ_N - 1);
            count++;
        } else {
            int i = (r - decode_position(s) - 1) & (LZ_N - 1);
            int j = c - 255 + LZ_THRESHOLD;
            for (int k = 0; k < j; k++) {
                unsigned char b = s->text_buf[(i + k) & (LZ_N - 1)];
                out_byte(s, b);
                s->text_buf[r] = b;
                r = (r + 1) & (LZ_N - 1);
                if (++count >= original_size) break;
            }
        }
    }
}

uint8_t *lzhuf_decompress(const uint8_t *data, size_t data_len, size_t *out_len) {
    if (data_len < 4) { *out_len = 0; return NULL; }

    int32_t original_size = (int32_t)data[0] | ((int32_t)data[1] << 8) |
                            ((int32_t)data[2] << 16) | ((int32_t)data[3] << 24);
    if (original_size <= 0 || original_size > 10000000) { *out_len = 0; return NULL; }

    lzhuf_state *s = (lzhuf_state *)calloc(1, sizeof(lzhuf_state));
    if (!s) return NULL;

    s->in_data = data;
    s->in_len = data_len;
    s->in_pos = 4; // skip size header
    s->out_data = NULL;
    s->out_len = 0;
    s->out_cap = 0;

    init_tree(s);
    do_decode(s, original_size);

    uint8_t *result = s->out_data;
    *out_len = s->out_len;
    free(s);
    return result;
}

// --- CRC-16 (from wl2k-go crc.go) ---

uint16_t lzhuf_crc16(const uint8_t *data, size_t len) {
    uint16_t sum = 0;
    for (size_t i = 0; i < len; i++)
        sum = ((sum << 8) & 0xFF00) ^ crc16_tab[(sum >> 8) & 0xFF] ^ data[i];
    // Two trailing zero bytes (wl2k-go convention)
    sum = ((sum << 8) & 0xFF00) ^ crc16_tab[(sum >> 8) & 0xFF];
    sum = ((sum << 8) & 0xFF00) ^ crc16_tab[(sum >> 8) & 0xFF];
    return sum;
}

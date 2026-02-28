/**
 * output_filter.c — Word buffer + warmup noise suppression
 *
 * Reference: deep_decoder.py::_OutputFilter
 */

#include "output_filter.h"
#include <string.h>

/* Characters that are noise-prone (≤2 Morse elements) */
static int is_noise_char(char ch)
{
    return (ch == 'E' || ch == 'T' || ch == 'I' ||
            ch == 'A' || ch == 'N' || ch == 'M' || ch == '?');
}

void output_filter_init(output_filter_t *f, int min_word_length)
{
    memset(f, 0, sizeof(*f));
    f->min_word_length = min_word_length;
}

static int emit_word(output_filter_t *f, char *out, int out_len)
{
    if (f->word_len == 0) return 0;

    /* Once warmed up, pass everything */
    if (f->warmed_up) {
        int n = f->word_len;
        if (n > out_len) n = out_len;
        memcpy(out, f->word_buf, n);
        return n;
    }

    /* During warmup: suppress noise-prone short words */
    if (f->word_len < f->min_word_length) {
        int all_noise = 1;
        for (int i = 0; i < f->word_len; i++) {
            if (!is_noise_char(f->word_buf[i])) {
                all_noise = 0;
                break;
            }
        }
        if (all_noise) return 0;
    }

    /* First valid word — disable filter permanently */
    f->warmed_up = 1;
    int n = f->word_len;
    if (n > out_len) n = out_len;
    memcpy(out, f->word_buf, n);
    return n;
}

int output_filter_feed(output_filter_t *f, const char *text, int text_len,
                       char *out, int out_len)
{
    int written = 0;

    for (int i = 0; i < text_len && written < out_len; i++) {
        char ch = text[i];

        if (ch == ' ') {
            int n = emit_word(f, out + written, out_len - written);
            if (n > 0) {
                written += n;
                if (written < out_len) {
                    out[written++] = ' ';
                }
            }
            f->word_len = 0;
        } else {
            if (f->word_len < OUTPUT_FILTER_MAX_WORD - 1) {
                f->word_buf[f->word_len++] = ch;
            }
        }
    }

    return written;
}

int output_filter_flush(output_filter_t *f, char *out, int out_len)
{
    int n = emit_word(f, out, out_len);
    f->word_len = 0;
    return n;
}

void output_filter_reset(output_filter_t *f)
{
    f->word_len = 0;
    f->warmed_up = 0;
}

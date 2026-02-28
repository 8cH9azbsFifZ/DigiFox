/**
 * output_filter.h — Word buffer + warmup suppression
 *
 * Suppresses startup noise (short words of E,T,I,A,N,M) until
 * first valid word passes, then permanently disables filtering.
 */

#ifndef OUTPUT_FILTER_H
#define OUTPUT_FILTER_H

#define OUTPUT_FILTER_MAX_WORD 64

typedef struct {
    char word_buf[OUTPUT_FILTER_MAX_WORD];
    int  word_len;
    int  warmed_up;
    int  min_word_length;
} output_filter_t;

/**
 * Initialize output filter.
 */
void output_filter_init(output_filter_t *f, int min_word_length);

/**
 * Feed decoded text character by character.
 *
 * @param f       Filter state
 * @param text    Input text
 * @param text_len Input text length
 * @param out     Output buffer
 * @param out_len Output buffer size
 * @return        Number of characters written to out
 */
int output_filter_feed(output_filter_t *f, const char *text, int text_len,
                       char *out, int out_len);

/**
 * Flush remaining buffered word.
 */
int output_filter_flush(output_filter_t *f, char *out, int out_len);

/**
 * Reset filter state.
 */
void output_filter_reset(output_filter_t *f);

#endif /* OUTPUT_FILTER_H */

/**
 * morse_table.c — Morse code lookup table + merged lookup
 *
 * ITU-R M.1677 compliant. Weights from VE3NEA Morse Expert.
 */

#include "morse_table.h"
#include <string.h>

/* Morse table entry */
typedef struct {
    const char *pattern;
    char        ch;
    int         weight;
} morse_entry_t;

/* Sorted by pattern for binary search */
static const morse_entry_t MORSE_TABLE[] = {
    /* Single elements */
    {".",       'E',  321},
    {"-",       'T',  236},
    /* Two elements */
    {"..",      'I',  115},
    {".-",      'A',  127},
    {"-.",      'N',  103},
    {"--",      'M',   48},
    /* Three elements */
    {"...",     'S',  101},
    {"..-",     'U',   48},
    {".-.",     'R',   84},
    {".--",     'W',   38},
    {"-..",     'D',   68},
    {"-.-",     'K',   17},
    {"--.",     'G',   31},
    {"---",     'O',  127},
    /* Four elements */
    {"....",    'H',  103},
    {"...-",    'V',   16},
    {"..-.",    'F',   37},
    {".-..",    'L',   66},
    {".--.",    'P',   31},
    {".---",    'J',    3},
    {"-...",    'B',   25},
    {"-..-",    'X',    3},
    {"-.-.",    'C',   44},
    {"-.--",    'Y',   32},
    {"--..",    'Z',    2},
    {"--.-",    'Q',    2},
    /* Five elements — digits (ITU-R M.1677) */
    {".----",   '1',   10},
    {"..---",   '2',   10},
    {"...--",   '3',   10},
    {"....-",   '4',   10},
    {".....",   '5',   10},
    {"-....",   '6',   10},
    {"--...",   '7',   10},
    {"---..",   '8',   10},
    {"----.",   '9',   10},
    {"-----",   '0',   10},
    /* Punctuation */
    {".-.-.-",  '.',    5},
    {"--..--",  ',',    5},
    {"..--..",  '?',    5},
    {".----.",  '\'',   3},
    {"-.-.--",  '!',    3},
    {"-..-.",   '/',    5},
    {"-.--.",   '(',    3},
    {"-.--.-",  ')',    3},
    {".-...",   '&',    3},
    {"---...",  ':',    3},
    {"-.-.-.",  ';',    3},
    {"-...-",   '=',    5},
    {".-.-.",   '+',    3},
    {"-....-",  '-',    3},
    {"..--.-",  '_',    3},
    {".-..-.",  '"',    3},
    {"...-..-", '$',    3},
    {".--.-.",  '@',    3},
};

#define TABLE_SIZE (sizeof(MORSE_TABLE) / sizeof(MORSE_TABLE[0]))

char morse_lookup(const char *pattern)
{
    if (!pattern || !pattern[0]) return '?';

    for (int i = 0; i < (int)TABLE_SIZE; i++) {
        if (strcmp(MORSE_TABLE[i].pattern, pattern) == 0) {
            return MORSE_TABLE[i].ch;
        }
    }
    return '?';
}

int morse_char_weight(char ch)
{
    for (int i = 0; i < (int)TABLE_SIZE; i++) {
        if (MORSE_TABLE[i].ch == ch) {
            return MORSE_TABLE[i].weight;
        }
    }
    return 1;
}

int morse_lookup_merged(const char *pattern, char *out, int out_len)
{
    if (!pattern || !pattern[0] || out_len < 1) return 0;

    /* Direct lookup */
    char direct = morse_lookup(pattern);
    if (direct != '?') {
        out[0] = direct;
        return 1;
    }

    int len = (int)strlen(pattern);
    if (len <= 1) {
        out[0] = '?';
        return 1;
    }

    /* Split-and-retry: try all split positions */
    int best_weight = -1;
    char best_left = 0, best_right = 0;

    char left_buf[16], right_buf[16];

    for (int pos = 1; pos < len && pos < 15; pos++) {
        /* Split pattern at pos */
        memcpy(left_buf, pattern, pos);
        left_buf[pos] = '\0';
        memcpy(right_buf, pattern + pos, len - pos);
        right_buf[len - pos] = '\0';

        char lch = morse_lookup(left_buf);
        char rch = morse_lookup(right_buf);

        if (lch != '?' && rch != '?') {
            int w = morse_char_weight(lch) + morse_char_weight(rch);
            if (w > best_weight) {
                best_weight = w;
                best_left = lch;
                best_right = rch;
            }
        }
    }

    if (best_weight >= 0 && out_len >= 2) {
        out[0] = best_left;
        out[1] = best_right;
        return 2;
    }

    out[0] = '?';
    return 1;
}

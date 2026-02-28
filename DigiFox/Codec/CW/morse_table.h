/**
 * morse_table.h — Morse code lookup + error-tolerant merged lookup
 */

#ifndef MORSE_TABLE_H
#define MORSE_TABLE_H

/**
 * Look up a Morse pattern (e.g. ".-" → "A").
 * Returns the character, or '?' if not found.
 */
char morse_lookup(const char *pattern);

/**
 * Error-tolerant lookup: tries direct match first, then split-and-retry
 * at all positions, choosing the highest-weight candidate.
 *
 * @param pattern  Morse pattern string (dots and dashes)
 * @param out      Output buffer (at least 3 bytes for 2-char + null)
 * @param out_len  Size of output buffer
 * @return         Number of characters written
 */
int morse_lookup_merged(const char *pattern, char *out, int out_len);

/**
 * Get character frequency weight (for merged lookup tie-breaking).
 */
int morse_char_weight(char ch);

#endif /* MORSE_TABLE_H */

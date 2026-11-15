/* Minimal Deflate64 (ZIP method 9) / Deflate (method 8) decoder.
 * Usage: inflate64 <zipfile> <data_offset> <compressed_size> <uncompressed_size> <out_path> <method>
 * Writes the decoded entry to out_path. The caller verifies the CRC.
 * Based on the canonical-Huffman approach of zlib's puff.c, extended for Deflate64:
 * 64 KiB window, length code 285 = base 3 + 16 extra bits, distance codes 30/31. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define MAXBITS 15
#define WSIZE (1u << 16)

typedef struct {
    FILE *in; uint64_t remaining; uint32_t bitbuf; int bitcnt;
    uint8_t inbuf[1 << 16]; size_t inpos, inlen;
    FILE *out; uint8_t win[WSIZE]; uint32_t wpos; uint64_t written; uint64_t expected;
    uint8_t obuf[1 << 16]; size_t olen;
    int deflate64;
} State;

static int getbyte(State *s) {
    if (s->inpos == s->inlen) {
        if (s->remaining == 0) return -1;
        size_t want = sizeof(s->inbuf);
        if (want > s->remaining) want = (size_t)s->remaining;
        s->inlen = fread(s->inbuf, 1, want, s->in);
        if (s->inlen == 0) return -1;
        s->remaining -= s->inlen; s->inpos = 0;
    }
    return s->inbuf[s->inpos++];
}

static int bits(State *s, int need, uint32_t *val) {
    uint32_t v = s->bitbuf;
    while (s->bitcnt < need) {
        int c = getbyte(s);
        if (c < 0) return -1;
        v |= (uint32_t)c << s->bitcnt;
        s->bitcnt += 8;
    }
    s->bitbuf = (uint32_t)(((uint64_t)v) >> need);
    s->bitcnt -= need;
    *val = need == 32 ? v : (v & ((1u << need) - 1));
    return 0;
}

static void flushout(State *s) {
    if (s->olen) { fwrite(s->obuf, 1, s->olen, s->out); s->olen = 0; }
}

static inline void putbyte(State *s, uint8_t b) {
    s->win[s->wpos++ & (WSIZE - 1)] = b;
    s->obuf[s->olen++] = b;
    if (s->olen == sizeof(s->obuf)) flushout(s);
    s->written++;
}

typedef struct { short count[MAXBITS + 1]; short symbol[320]; } Huff;

static int decode(State *s, const Huff *h) {
    int code = 0, first = 0, index = 0;
    for (int len = 1; len <= MAXBITS; len++) {
        uint32_t b;
        if (bits(s, 1, &b)) return -1;
        code |= (int)b;
        int count = h->count[len];
        if (code - count < first) return h->symbol[index + (code - first)];
        index += count; first += count; first <<= 1; code <<= 1;
    }
    return -10;
}

static int construct(Huff *h, const short *length, int n) {
    short offs[MAXBITS + 1];
    for (int len = 0; len <= MAXBITS; len++) h->count[len] = 0;
    for (int sym = 0; sym < n; sym++) h->count[length[sym]]++;
    if (h->count[0] == n) return 0;
    int left = 1;
    for (int len = 1; len <= MAXBITS; len++) { left <<= 1; left -= h->count[len]; if (left < 0) return left; }
    offs[1] = 0;
    for (int len = 1; len < MAXBITS; len++) offs[len + 1] = offs[len] + h->count[len];
    for (int sym = 0; sym < n; sym++) if (length[sym] != 0) h->symbol[offs[length[sym]]++] = (short)sym;
    return left;
}

static const short lbase[29] = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258};
static const short lext[29] = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0};
static const int dbase[32] = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577,32769,49153};
static const short dext[32] = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13,14,14};

static int codes(State *s, const Huff *lencode, const Huff *distcode) {
    for (;;) {
        int sym = decode(s, lencode);
        if (sym < 0) return sym;
        if (sym < 256) { putbyte(s, (uint8_t)sym); continue; }
        if (sym == 256) return 0;
        sym -= 257;
        if (sym >= 29) return -10;
        uint32_t e; int len;
        if (s->deflate64 && sym == 28) { if (bits(s, 16, &e)) return -1; len = 3 + (int)e; }
        else { if (bits(s, lext[sym], &e)) return -1; len = lbase[sym] + (int)e; }
        int dsym = decode(s, distcode);
        if (dsym < 0) return dsym;
        if (dsym >= (s->deflate64 ? 32 : 30)) return -11;
        if (bits(s, dext[dsym], &e)) return -1;
        uint32_t dist = (uint32_t)dbase[dsym] + e;
        if (dist > s->written || dist > WSIZE) return -12;
        while (len--) { uint8_t b = s->win[(s->wpos - dist) & (WSIZE - 1)]; putbyte(s, b); }
    }
}

static int stored(State *s) {
    s->bitbuf = 0; s->bitcnt = 0;
    int a = getbyte(s), b = getbyte(s), c = getbyte(s), d = getbyte(s);
    if (a < 0 || b < 0 || c < 0 || d < 0) return -1;
    unsigned len = (unsigned)a | ((unsigned)b << 8);
    unsigned nlen = (unsigned)c | ((unsigned)d << 8);
    if (len != (~nlen & 0xffff)) return -2;
    while (len--) { int x = getbyte(s); if (x < 0) return -1; putbyte(s, (uint8_t)x); }
    return 0;
}

static int fixed(State *s) {
    static Huff lencode, distcode; static int built = 0;
    if (!built) {
        short lengths[320]; int sym;
        for (sym = 0; sym < 144; sym++) lengths[sym] = 8;
        for (; sym < 256; sym++) lengths[sym] = 9;
        for (; sym < 280; sym++) lengths[sym] = 7;
        for (; sym < 288; sym++) lengths[sym] = 8;
        construct(&lencode, lengths, 288);
        for (sym = 0; sym < 32; sym++) lengths[sym] = 5;
        construct(&distcode, lengths, 32);
        built = 1;
    }
    return codes(s, &lencode, &distcode);
}

static int dynamic(State *s) {
    static const short order[19] = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15};
    short lengths[320]; Huff lencode, distcode; uint32_t v;
    if (bits(s, 5, &v)) return -1; int nlen = (int)v + 257;
    if (bits(s, 5, &v)) return -1; int ndist = (int)v + 1;
    if (bits(s, 4, &v)) return -1; int ncode = (int)v + 4;
    if (nlen > 288 || ndist > 32) return -3;
    int index;
    for (index = 0; index < ncode; index++) { if (bits(s, 3, &v)) return -1; lengths[order[index]] = (short)v; }
    for (; index < 19; index++) lengths[order[index]] = 0;
    if (construct(&lencode, lengths, 19) != 0) return -4;
    index = 0;
    while (index < nlen + ndist) {
        int sym = decode(s, &lencode);
        if (sym < 0) return sym;
        if (sym < 16) lengths[index++] = (short)sym;
        else {
            int len = 0;
            if (sym == 16) { if (index == 0) return -5; len = lengths[index - 1]; if (bits(s, 2, &v)) return -1; sym = 3 + (int)v; }
            else if (sym == 17) { if (bits(s, 3, &v)) return -1; sym = 3 + (int)v; }
            else { if (bits(s, 7, &v)) return -1; sym = 11 + (int)v; }
            if (index + sym > nlen + ndist) return -6;
            while (sym--) lengths[index++] = (short)len;
        }
    }
    if (lengths[256] == 0) return -9;
    int err = construct(&lencode, lengths, nlen);
    if (err < 0 || (err > 0 && nlen - lencode.count[0] != 1)) return -7;
    err = construct(&distcode, lengths + nlen, ndist);
    if (err < 0 || (err > 0 && ndist - distcode.count[0] != 1)) return -8;
    return codes(s, &lencode, &distcode);
}

int main(int argc, char **argv) {
    if (argc != 7) { fprintf(stderr, "usage\n"); return 2; }
    static State s; memset(&s, 0, sizeof(s));
    s.in = fopen(argv[1], "rb"); if (!s.in) { perror("in"); return 2; }
    if (fseeko(s.in, (off_t)strtoull(argv[2], 0, 10), SEEK_SET)) { perror("seek"); return 2; }
    s.remaining = strtoull(argv[3], 0, 10);
    s.expected = strtoull(argv[4], 0, 10);
    int method = atoi(argv[6]);
    s.out = fopen(argv[5], "wb"); if (!s.out) { perror("out"); return 2; }
    if (method == 0) {
        uint64_t n = s.remaining; while (n) { int c = getbyte(&s); if (c < 0) break; putbyte(&s, (uint8_t)c); n--; }
    } else {
        s.deflate64 = (method == 9);
        int last, err = 0; uint32_t v;
        do {
            if (bits(&s, 1, &v)) { err = -1; break; } last = (int)v;
            if (bits(&s, 2, &v)) { err = -1; break; }
            if (v == 0) err = stored(&s); else if (v == 1) err = fixed(&s); else if (v == 2) err = dynamic(&s); else err = -20;
            if (err) break;
        } while (!last);
        if (err) { flushout(&s); fclose(s.out); fprintf(stderr, "inflate error %d at %llu\n", err, (unsigned long long)s.written); return 1; }
    }
    flushout(&s); fclose(s.out);
    if (s.written != s.expected) { fprintf(stderr, "size mismatch %llu != %llu\n", (unsigned long long)s.written, (unsigned long long)s.expected); return 1; }
    return 0;
}

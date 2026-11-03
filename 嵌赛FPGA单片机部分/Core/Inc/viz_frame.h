#ifndef VIZ_FRAME_H
#define VIZ_FRAME_H

/* B board (visualizer) down-link frames.
 *
 * Wire format, 2 Mbit/s 8N1, fixed length, little endian 16-bit payload words:
 *
 *   offset 0   1    2      3     4 ...                len-2
 *          AA  7C   type   seq   payload ...          CRC16
 *
 * The CRC is CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection) and
 * covers type through the last payload byte, i.e. len-4 bytes starting at
 * offset 2.  It is sent low byte first.  Payload sizes are fixed per type, so
 * no length field exists and the receiver must know the table below.
 *
 * This module is plain C: it holds no HAL state so it can be exercised by the
 * native test suite (tests/test_viz_frame.c) exactly as it runs on the target.
 */

#include <stdint.h>

#define VIZ_HEADER_0            0xAAU
#define VIZ_HEADER_1            0x7CU
#define VIZ_MAX_PAYLOAD         512U
#define VIZ_HEADER_SIZE         4U   /* AA 7C type seq */
#define VIZ_CRC_SIZE            2U
#define VIZ_MAX_FRAME_SIZE      (VIZ_HEADER_SIZE + VIZ_MAX_PAYLOAD + VIZ_CRC_SIZE)
#define VIZ_STAT_PAYLOAD        16U
#define VIZ_MAILBOX_SLOTS       4U

typedef enum {
    VIZ_FRAME_WAVE = 0x01,
    VIZ_FRAME_SPEC = 0x02,
    VIZ_FRAME_XY   = 0x03,
    VIZ_FRAME_STAT = 0x04
} VizFrameType;

typedef struct {
    uint8_t  type;
    uint8_t  seq;
    uint16_t length;                        /* payload bytes only */
    uint8_t  payload[VIZ_MAX_PAYLOAD];
} VizFrame;

/* Decoded STAT payload (type 0x04). */
typedef struct {
    uint8_t  peak;          /* peak level 0..255 */
    uint8_t  rms;           /* rms level 0..255 */
    uint8_t  voices;        /* active voice estimate 0..12 */
    uint8_t  flags;         /* VIZ_STAT_FLAG_* */
    uint16_t key_mask;      /* 12-bit key mask, always 0 from the B board */
    uint8_t  ratio_a;       /* Lissajous ratio, 1..16 */
    uint8_t  ratio_b;
    uint32_t sample_count;  /* 96 kHz sample counter */
    uint16_t fft_frame;
} VizStat;

#define VIZ_STAT_FLAG_CLIP     0x01U
#define VIZ_STAT_FLAG_I2S      0x02U
#define VIZ_STAT_FLAG_FFT_OVF  0x04U

/* Complete frame length for a type, 0 when the type is not part of the link. */
uint16_t VizFrame_Length(uint8_t type);
/* Payload length for a type, 0 when unknown. */
uint16_t VizFrame_PayloadLength(uint8_t type);

/* Byte-stream parser.  Buffers one candidate frame (plus header slack) so a
 * candidate is never abandoned just because AA 7C shows up inside its payload.
 * On any failure exactly one byte is dropped and the search restarts, which
 * recovers from inserted, deleted and truncated bytes. */
#define VIZ_PARSER_BUFFER (VIZ_MAX_FRAME_SIZE + 2U)

typedef struct {
    uint8_t  buffer[VIZ_PARSER_BUFFER];
    uint16_t used;
    uint32_t accepted;
    uint32_t crc_errors;
    uint32_t discarded;      /* bytes dropped while hunting for a header */
    uint32_t unknown_type;
    uint32_t too_long;       /* candidate larger than the parser can hold */
    uint32_t header[VIZ_MAILBOX_SLOTS];  /* valid headers seen per type */
    uint32_t crc_bad[VIZ_MAILBOX_SLOTS]; /* CRC failures per type */
} VizParser;

void VizParser_Init(VizParser *parser);

/* Push up to `size` bytes.  Returns 1 and fills `frame` when a complete,
 * CRC-valid frame was produced.  Bytes after that frame that were already
 * copied stay buffered; call again (with size 0) to drain them.
 * Returns 0 when more bytes are needed.
 *
 * `consumed` (may be NULL) receives how many of `size` bytes were taken.  The
 * parser stops as soon as a frame is complete, and it also has to stop copying
 * when its candidate buffer is full, so the caller MUST re-feed the rest:
 * `data + consumed, size - consumed` -- otherwise whole frames disappear while
 * the link still looks healthy. */
int VizParser_Feed(VizParser *parser, const uint8_t *data, uint16_t size,
                   VizFrame *frame, uint16_t *consumed);

/* Throw away a half-received candidate (byte stream stalled mid frame). */
void VizParser_ResetCandidate(VizParser *parser);

/* Decode a type 0x04 frame.  Returns 0 when the frame is not a valid STAT. */
int VizFrame_DecodeStat(const VizFrame *frame, VizStat *stat);

/* Latest frame mailbox: one double-buffered slot per frame type.  Commit never
 * blocks a reader mid-frame, and Take returns every committed frame at most
 * once (a newer frame replaces an unread one, which is what a display wants). */
typedef struct {
    uint8_t  data[2][VIZ_MAX_PAYLOAD];
    uint16_t length[2];
    uint8_t  seq[2];
    uint8_t  write_index;
    uint8_t  read_index;
    volatile uint8_t dirty;
    uint32_t frames;
} VizMailbox;

typedef struct {
    VizMailbox slot[VIZ_MAILBOX_SLOTS];
} VizMailboxes;

void VizMailboxes_Reset(VizMailboxes *mailboxes);
/* Slot index for a frame type, -1 when unknown. */
int VizMailboxes_Index(uint8_t type);
void VizMailbox_Commit(VizMailbox *mailbox, const VizFrame *frame);
int VizMailbox_Take(VizMailbox *mailbox, VizFrame *frame);

#endif

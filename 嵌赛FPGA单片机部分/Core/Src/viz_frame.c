#include "viz_frame.h"
#include "protocol_crc.h"
#include <string.h>

#define VIZ_TYPE_COUNT 4U

uint16_t VizFrame_PayloadLength(uint8_t type)
{
    switch (type) {
    case VIZ_FRAME_WAVE: return 512U;   /* 256 columns x {min,max}       */
    case VIZ_FRAME_SPEC: return 128U;   /* 64 bars + 64 peak holds       */
    case VIZ_FRAME_XY:   return 512U;   /* 256 points x {x,y}            */
    case VIZ_FRAME_STAT: return VIZ_STAT_PAYLOAD;
    default:             return 0U;
    }
}

uint16_t VizFrame_Length(uint8_t type)
{
    uint16_t payload = VizFrame_PayloadLength(type);
    if (payload == 0U) return 0U;
    return (uint16_t)(payload + VIZ_HEADER_SIZE + VIZ_CRC_SIZE);
}

void VizParser_Init(VizParser *parser)
{
    if (parser == 0) return;
    parser->used = 0U;
    parser->accepted = 0U;
    parser->crc_errors = 0U;
    parser->discarded = 0U;
    parser->unknown_type = 0U;
    parser->too_long = 0U;
    memset(parser->header, 0, sizeof(parser->header));
    memset(parser->crc_bad, 0, sizeof(parser->crc_bad));
}

static void Drop(VizParser *parser, uint16_t count)
{
    if (count >= parser->used) {
        parser->used = 0U;
        return;
    }
    memmove(parser->buffer, parser->buffer + count,
            (size_t)(parser->used - count));
    parser->used = (uint16_t)(parser->used - count);
}

/* Try to cut one frame out of the buffered bytes.  Returns 1 and fills `frame`
 * when a frame was produced, 0 when the parser needs more input. */
static int Parse(VizParser *parser, VizFrame *frame)
{
    for (;;) {
        uint16_t i;
        uint16_t length;
        uint16_t received;
        uint16_t computed;

        if (parser->used == 0U) return 0;

        /* Header hunting: keep only a trailing AA, everything else is noise. */
        if (parser->buffer[0] != VIZ_HEADER_0) {
            for (i = 1U; i < parser->used; ++i) {
                if (parser->buffer[i] == VIZ_HEADER_0) break;
            }
            parser->discarded += i;
            Drop(parser, i);
            continue;
        }
        if (parser->used < 2U) return 0;
        if (parser->buffer[1] != VIZ_HEADER_1) {
            parser->discarded++;
            Drop(parser, 1U);
            continue;
        }
        if (parser->used < VIZ_HEADER_SIZE) return 0;

        length = VizFrame_Length(parser->buffer[2]);
        if (length == 0U) {
            /* A real header with a type this firmware does not know: skip the
             * AA only, so the 7C can still start nothing and the next AA is
             * found by the hunt above. */
            parser->unknown_type++;
            parser->discarded++;
            Drop(parser, 1U);
            continue;
        }
        /* A candidate never gets abandoned while AA 7C appears inside it. */
        if (parser->used < length) {
            if (parser->used >= VIZ_PARSER_BUFFER) {
                parser->too_long++;
                parser->discarded++;
                Drop(parser, 1U);
                continue;
            }
            return 0;
        }
        {
            int slot = VizMailboxes_Index(parser->buffer[2]);
            if (slot >= 0) parser->header[slot]++;
        }

        computed = Protocol_Crc16CcittFalse(parser->buffer + 2U,
                                            (size_t)(length - VIZ_HEADER_SIZE));
        received = (uint16_t)parser->buffer[length - 2U] |
                   (uint16_t)((uint16_t)parser->buffer[length - 1U] << 8);
        if (computed != received) {
            /* Discard the whole candidate and search one byte further. */
            int slot = VizMailboxes_Index(parser->buffer[2]);
            parser->crc_errors++;
            if (slot >= 0) parser->crc_bad[slot]++;
            parser->discarded++;
            Drop(parser, 1U);
            continue;
        }

        frame->type = parser->buffer[2];
        frame->seq = parser->buffer[3];
        frame->length = (uint16_t)(length - VIZ_HEADER_SIZE - VIZ_CRC_SIZE);
        memcpy(frame->payload, parser->buffer + VIZ_HEADER_SIZE,
               (size_t)frame->length);
        parser->accepted++;
        Drop(parser, length);
        return 1;
    }
}

int VizParser_Feed(VizParser *parser, const uint8_t *data, uint16_t size,
                   VizFrame *frame, uint16_t *consumed)
{
    uint16_t offset = 0U;

    if (parser == 0 || frame == 0) {
        if (consumed != 0) *consumed = 0U;
        return 0;
    }
    if (data == 0) size = 0U;

    for (;;) {
        uint16_t room;
        uint16_t chunk;

        if (Parse(parser, frame)) {
            if (consumed != 0) *consumed = offset;
            return 1;
        }
        if (offset >= size) {
            if (consumed != 0) *consumed = offset;
            return 0;
        }

        room = (uint16_t)(VIZ_PARSER_BUFFER - parser->used);
        chunk = (uint16_t)(size - offset);
        if (chunk > room) chunk = room;
        if (chunk == 0U) {
            /* Cannot happen while VIZ_PARSER_BUFFER covers the largest frame;
             * kept so a future header cannot wedge the loop. */
            parser->discarded++;
            Drop(parser, 1U);
            continue;
        }
        memcpy(parser->buffer + parser->used, data + offset, (size_t)chunk);
        parser->used = (uint16_t)(parser->used + chunk);
        offset = (uint16_t)(offset + chunk);
    }
}

void VizParser_ResetCandidate(VizParser *parser)
{
    if (parser == 0) return;
    parser->discarded += parser->used;
    parser->used = 0U;
}

int VizFrame_DecodeStat(const VizFrame *frame, VizStat *stat)
{
    const uint8_t *p;

    if (frame == 0 || stat == 0) return 0;
    if (frame->type != VIZ_FRAME_STAT || frame->length < VIZ_STAT_PAYLOAD) {
        return 0;
    }
    p = frame->payload;
    stat->peak = p[0];
    stat->rms = p[1];
    stat->voices = p[2];
    stat->flags = p[3];
    stat->key_mask = (uint16_t)((uint16_t)p[4] | ((uint16_t)p[5] << 8));
    stat->ratio_a = p[6];
    stat->ratio_b = p[7];
    stat->sample_count = (uint32_t)p[8] | ((uint32_t)p[9] << 8) |
                         ((uint32_t)p[10] << 16) | ((uint32_t)p[11] << 24);
    stat->fft_frame = (uint16_t)((uint16_t)p[12] | ((uint16_t)p[13] << 8));
    return 1;
}

void VizMailboxes_Reset(VizMailboxes *mailboxes)
{
    if (mailboxes == 0) return;
    memset(mailboxes, 0, sizeof(*mailboxes));
}

int VizMailboxes_Index(uint8_t type)
{
    switch (type) {
    case VIZ_FRAME_WAVE: return 0;
    case VIZ_FRAME_SPEC: return 1;
    case VIZ_FRAME_XY:   return 2;
    case VIZ_FRAME_STAT: return 3;
    default:             return -1;
    }
}

void VizMailbox_Commit(VizMailbox *mailbox, const VizFrame *frame)
{
    uint8_t index;

    if (mailbox == 0 || frame == 0) return;
    if (frame->length > VIZ_MAX_PAYLOAD) return;
    index = mailbox->write_index;
    memcpy(mailbox->data[index], frame->payload, (size_t)frame->length);
    mailbox->length[index] = frame->length;
    mailbox->seq[index] = frame->seq;
    mailbox->read_index = index;
    mailbox->write_index = (uint8_t)(index ^ 1U);
    mailbox->dirty = 1U;
    mailbox->frames++;
}

int VizMailbox_Take(VizMailbox *mailbox, VizFrame *frame)
{
    uint8_t index;

    if (mailbox == 0 || frame == 0) return 0;
    if (!mailbox->dirty) return 0;
    /* Clear the flag first: a commit that lands during the copy sets it again
     * and the next Take returns that newer frame. */
    mailbox->dirty = 0U;
    index = mailbox->read_index;
    frame->seq = mailbox->seq[index];
    frame->length = mailbox->length[index];
    memcpy(frame->payload, mailbox->data[index], (size_t)frame->length);
    return 1;
}

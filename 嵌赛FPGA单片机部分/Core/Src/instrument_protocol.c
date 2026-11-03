#include "instrument_protocol.h"
#include "protocol_crc.h"
#include <string.h>
uint16_t Protocol_Read16(const uint8_t *p) { return (uint16_t)(p[0] | ((uint16_t)p[1]<<8)); }
void Protocol_Write16(uint8_t *p, uint16_t v) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); }
void Protocol_Pressure(uint8_t f[22], const uint16_t v[8], uint16_t seq)
{
    unsigned i;
    f[0]=0xAA; f[1]=0x55; Protocol_Write16(f+2,seq);
    for(i=0;i<8;i++) Protocol_Write16(f+4+2*i, v[i]&0xFFFU);
    Protocol_Write16(f+20,Protocol_Crc16CcittFalse(f+2,18));
}
void Protocol_TouchPiano(uint8_t f[TOUCH_PIANO_FRAME_SIZE],
                         const uint16_t force[TOUCH_PIANO_KEY_COUNT],
                         uint16_t seq, uint8_t base_note,
                         uint16_t pressed_mask)
{
    unsigned i;
    f[0]=0xAA; f[1]=0x56; f[2]=1; f[3]=base_note;
    Protocol_Write16(f+4,seq);
    pressed_mask&=0x0FFFU;
    Protocol_Write16(f+6,pressed_mask);
    for(i=0;i<TOUCH_PIANO_KEY_COUNT;i++)
        Protocol_Write16(f+8+2*i,(pressed_mask&(1U<<i)) ? force[i]&0x0FFFU : 0U);
    Protocol_Write16(f+32,Protocol_Crc16CcittFalse(f+2,30));
}
void Protocol_Piano48(uint8_t f[PIANO48_FRAME_SIZE],
                      const uint16_t groups[PIANO48_GROUP_COUNT],
                      uint16_t seq)
{
    unsigned i, bit;
    uint8_t mask[6] = {0U, 0U, 0U, 0U, 0U, 0U};
    f[0] = 0xAAU;
    f[1] = 0x56U;
    f[2] = 2U;
    f[3] = 48U;             /* C3, fixed for the C3..B6 keyboard. */
    Protocol_Write16(f + 4, seq);
    for (i = 0U; i < PIANO48_GROUP_COUNT; ++i)
        for (bit = 0U; bit < 12U; ++bit)
            if (groups != 0 && (groups[i] & (uint16_t)(1U << bit)) != 0U)
                mask[(12U * i + bit) / 8U] |=
                    (uint8_t)(1U << ((12U * i + bit) % 8U));
    for (i = 0U; i < 6U; ++i) f[6U + i] = mask[i];
    for (i = 12U; i < 32U; ++i)
    {
        f[i] = 0U;           /* v2 has no force/velocity fields. */
    }
    Protocol_Write16(f + 32, Protocol_Crc16CcittFalse(f + 2, 30));
}
void Protocol_Control(uint8_t f[16], const ControlMessage *m)
{
    f[0]=0x5A; f[1]=0xA5; f[2]=1; f[3]=m->command;
    Protocol_Write16(f+4,m->sequence); f[6]=m->target; f[7]=0;
    memcpy(f+8,m->p,6); Protocol_Write16(f+14,Protocol_Crc16CcittFalse(f+2,12));
}
int Protocol_Feed(ControlParser *s, uint8_t b, ControlMessage *m)
{
    s->bytes[s->used++]=b;
    /* Slide after failed full candidates; preserve embedded headers on bad CRC. */
    while(s->used) {
        if(s->bytes[0]==0x5A && (s->used<2 || s->bytes[1]==0xA5)) {
            if(s->used<16) return 0;
            if(Protocol_Read16(s->bytes+14)==Protocol_Crc16CcittFalse(s->bytes+2,12)) {
                if(s->bytes[2]==1 && s->bytes[7]==0 && s->bytes[6]<=8) {
                    m->command=s->bytes[3]; m->sequence=Protocol_Read16(s->bytes+4);
                    m->target=s->bytes[6]; memcpy(m->p,s->bytes+8,6); s->used=0; return 1;
                }
                s->bad_fields++;
            } else s->bad_crc++;
        }
        --s->used; memmove(s->bytes,s->bytes+1,s->used);
    }
    return 0;
}
int Protocol_ValidRequest(const ControlMessage *m)
{
    unsigned used=0,i; int valid=0;
    if(m->command==CMD_NOTE || m->command==CMD_CHORD) {
        if(m->target<1 || m->target>8) return 0;
    } else if(m->target!=0) return 0;
    switch(m->command) {
    case CMD_PING: case CMD_RELEASE: case CMD_STATUS: valid=1; break;
    case CMD_TIMBRE: case CMD_MODE: case CMD_MUTE: used=1; valid=m->p[0]<=1; break;
    case CMD_GAIN: used=2; valid=Protocol_Read16(m->p)<=1000; break;
    case CMD_TRANSPOSE: used=1; valid=(int8_t)m->p[0]>=-24 && (int8_t)m->p[0]<=24; break;
    case CMD_NOTE: used=1; valid=m->p[0]<=127; break;
    case CMD_ADSR: used=3; valid=m->p[0]<=3 && Protocol_Read16(m->p+1)<=(m->p[0]==2?1000:5000); break;
    case CMD_CHORD:
        used=5; valid=m->p[0]>=1 && m->p[0]<=4;
        for(i=1;i<=4;i++) if(i<=m->p[0] ? m->p[i]>127 : m->p[i]!=255) valid=0;
        break;
    default: return 0;
    }
    for(i=used;i<6;i++) if(m->p[i]) return 0;
    return valid;
}

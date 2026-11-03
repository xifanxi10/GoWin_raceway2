#ifndef INSTRUMENT_PROTOCOL_H
#define INSTRUMENT_PROTOCOL_H
#include <stdint.h>
#define CONTROL_FRAME_SIZE 16U
#define PRESSURE_FRAME_SIZE 22U
#define TOUCH_PIANO_KEY_COUNT 12U
#define TOUCH_PIANO_FRAME_SIZE 34U
#define PIANO48_GROUP_COUNT 4U
#define PIANO48_KEY_COUNT 48U
#define PIANO48_FRAME_SIZE 34U
enum { CMD_PING=0, CMD_TIMBRE=1, CMD_GAIN=2, CMD_TRANSPOSE=3,
       CMD_NOTE=4, CMD_MODE=5, CMD_CHORD=6, CMD_RELEASE=7, CMD_MUTE=8,
       CMD_ADSR=0x10, CMD_STATUS=0x20, CMD_ACK=0x80, CMD_STATE=0x81 };
typedef struct { uint8_t command, target, p[6]; uint16_t sequence; } ControlMessage;
typedef struct { uint8_t bytes[16], used; uint32_t bad_crc, bad_fields; } ControlParser;
uint16_t Protocol_Read16(const uint8_t *p);
void Protocol_Write16(uint8_t *p, uint16_t value);
void Protocol_Pressure(uint8_t frame[22], const uint16_t values[8], uint16_t sequence);
void Protocol_TouchPiano(uint8_t frame[TOUCH_PIANO_FRAME_SIZE],
                         const uint16_t force[TOUCH_PIANO_KEY_COUNT],
                         uint16_t sequence, uint8_t base_note,
                         uint16_t pressed_mask);
/* AA 56 v2: four 12-bit groups packed as one little-endian 48-bit mask. */
void Protocol_Piano48(uint8_t frame[PIANO48_FRAME_SIZE],
                      const uint16_t groups[PIANO48_GROUP_COUNT],
                      uint16_t sequence);
void Protocol_Control(uint8_t frame[16], const ControlMessage *message);
int Protocol_Feed(ControlParser *parser, uint8_t byte, ControlMessage *message);
int Protocol_ValidRequest(const ControlMessage *message);
#endif

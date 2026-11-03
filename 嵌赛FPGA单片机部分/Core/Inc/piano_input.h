#ifndef PIANO_INPUT_H
#define PIANO_INPUT_H

#include <stdint.h>
#include "instrument_protocol.h"

#define PIANO_INPUT_PRESS_DEBOUNCE_MS 8U
#define PIANO_INPUT_RELEASE_DEBOUNCE_MS 30U

void PianoInput_Init(void);
void PianoInput_Service(uint32_t now_ms);
uint64_t PianoInput_GetPressedMask(void);
void PianoInput_GetGroups(uint16_t groups[PIANO48_GROUP_COUNT]);
uint8_t PianoInput_GetBaseNote(void);
uint16_t PianoInput_GetLastSequence(void);
/* Legacy screen hooks retained as harmless compatibility shims.  Physical
 * input is always fixed at C3..B6 in the v2 wire protocol. */
uint8_t PianoInput_GetOctave(void);
uint8_t PianoInput_SetOctave(uint8_t octave);
void PianoInput_SubmitPressure(const uint16_t values[12], uint16_t sequence);

#endif

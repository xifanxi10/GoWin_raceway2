#ifndef TOUCH_PIANO_H
#define TOUCH_PIANO_H

#include <stdint.h>
#include "instrument_protocol.h"

#define TOUCH_PIANO_MIN_OCTAVE 2U
#define TOUCH_PIANO_MAX_OCTAVE 7U
#define TOUCH_PIANO_DEFAULT_OCTAVE 4U
#define TOUCH_PIANO_PRESS_DEBOUNCE_MS 8U
#define TOUCH_PIANO_RELEASE_DEBOUNCE_MS 30U
#define TOUCH_PIANO_FIXED_VELOCITY 2048U

typedef struct {
    uint16_t force[TOUCH_PIANO_KEY_COUNT];
    uint16_t stable_mask;
    uint16_t candidate_mask;
    uint32_t candidate_since[TOUCH_PIANO_KEY_COUNT];
    uint8_t octave;
} TouchPianoState;

void TouchPiano_Init(TouchPianoState *state);
void TouchPiano_Update(TouchPianoState *state, uint16_t raw_mask,
                       uint32_t now_ms);
uint8_t TouchPiano_SetOctave(TouchPianoState *state, uint8_t octave);
uint8_t TouchPiano_BaseNote(const TouchPianoState *state);

#endif

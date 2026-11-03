#include "touch_piano.h"
#include <string.h>

void TouchPiano_Init(TouchPianoState *state)
{
    if(state==0) return;
    memset(state,0,sizeof(*state));
    state->octave=TOUCH_PIANO_DEFAULT_OCTAVE;
}

uint8_t TouchPiano_SetOctave(TouchPianoState *state, uint8_t octave)
{
    if(state==0 || octave<TOUCH_PIANO_MIN_OCTAVE ||
       octave>TOUCH_PIANO_MAX_OCTAVE) return 0;
    state->octave=octave;
    return 1;
}

uint8_t TouchPiano_BaseNote(const TouchPianoState *state)
{
    /* MIDI convention: C-1 is 0, so C4 is 60. */
    return state==0 ? 60U : (uint8_t)(12U*(state->octave+1U));
}

void TouchPiano_Update(TouchPianoState *state, uint16_t raw_mask,
                       uint32_t now_ms)
{
    unsigned i;
    if(state==0) return;
    raw_mask&=0x0FFFU;
    for(i=0;i<TOUCH_PIANO_KEY_COUNT;i++) {
        uint16_t bit=(uint16_t)(1U<<i);
        uint8_t raw=(raw_mask&bit)!=0U;
        uint8_t candidate=(state->candidate_mask&bit)!=0U;
        uint8_t stable=(state->stable_mask&bit)!=0U;
        uint32_t debounce;

        if(raw!=candidate) {
            if(raw) state->candidate_mask|=bit;
            else state->candidate_mask=(uint16_t)(state->candidate_mask&~bit);
            state->candidate_since[i]=now_ms;
            candidate=raw;
        }

        debounce=candidate ? TOUCH_PIANO_PRESS_DEBOUNCE_MS :
                             TOUCH_PIANO_RELEASE_DEBOUNCE_MS;
        if(candidate!=stable &&
           (uint32_t)(now_ms-state->candidate_since[i])>=debounce) {
            if(candidate) {
                state->stable_mask|=bit;
                /* Freeze note-on velocity until release. Point-size mapping
                   requires board calibration, so the safe default is fixed. */
                state->force[i]=TOUCH_PIANO_FIXED_VELOCITY;
            } else {
                state->stable_mask=(uint16_t)(state->stable_mask&~bit);
                state->force[i]=0U;
            }
            stable=candidate;
        }
        if(!stable) state->force[i]=0U;
    }
}

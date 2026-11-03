#include "piano_input.h"
#include "pca9555_keys.h"
#include "pressure_link.h"

static uint16_t stable_groups[PIANO48_GROUP_COUNT];
static uint16_t candidate_groups[PIANO48_GROUP_COUNT];
static uint32_t candidate_since[PIANO48_KEY_COUNT];
static volatile uint64_t published_mask;
static volatile uint16_t last_sequence;
static uint32_t last_publish;
static uint8_t was_online;

static void Publish(uint32_t now_ms, uint8_t force)
{
    uint16_t groups[PIANO48_GROUP_COUNT];
    uint8_t i;
    for (i = 0U; i < PIANO48_GROUP_COUNT; ++i) groups[i] = stable_groups[i];
    if (force || (uint32_t)(now_ms - last_publish) >= 15U) {
        last_sequence++;
        if (PressureLink_SubmitPiano48(groups, last_sequence) == HAL_OK)
            last_publish = now_ms;
    }
}

static void ReleaseAll(uint32_t now_ms)
{
    uint8_t i;
    for (i = 0U; i < PIANO48_GROUP_COUNT; ++i) {
        stable_groups[i] = 0U; candidate_groups[i] = 0U;
    }
    published_mask = 0U;
    Publish(now_ms, 1U);
}

void PianoInput_Init(void)
{
    uint8_t i;
    for (i = 0U; i < PIANO48_GROUP_COUNT; ++i) {
        stable_groups[i] = 0U; candidate_groups[i] = 0U;
    }
    for (i = 0U; i < PIANO48_KEY_COUNT; ++i) candidate_since[i] = 0U;
    published_mask = 0U; last_sequence = 0U; last_publish = 0U;
    was_online = PCA9555Keys_Init() != 0U;
    PressureLink_SetMode(PRESSURE_LINK_MODE_TOUCH_PIANO);
    Publish(0U, 1U); /* establish a known all-released state after reset */
}

void PianoInput_Service(uint32_t now_ms)
{
    uint16_t raw[PIANO48_GROUP_COUNT];
    uint8_t online, group, key;
    uint8_t changed = 0U;
    PCA9555Keys_Service(now_ms);
    online = PCA9555Keys_GetOnlineMask();
    if (!online) {
        if (was_online) ReleaseAll(now_ms);
        was_online = 0U;
        return;
    }
    was_online = 1U;
    PCA9555Keys_GetGroups(raw);
    for (group = 0U; group < PIANO48_GROUP_COUNT; ++group) {
        for (key = 0U; key < 12U; ++key) {
            uint8_t index = (uint8_t)(group * 12U + key);
            uint16_t bit = (uint16_t)(1U << key);
            uint8_t value = (uint8_t)((raw[group] & bit) != 0U);
            uint8_t candidate = (uint8_t)((candidate_groups[group] & bit) != 0U);
            uint8_t stable = (uint8_t)((stable_groups[group] & bit) != 0U);
            uint32_t delay;
            if (value != candidate) {
                if (value) candidate_groups[group] |= bit;
                else candidate_groups[group] = (uint16_t)(candidate_groups[group] & (uint16_t)~bit);
                candidate_since[index] = now_ms; candidate = value;
            }
            delay = candidate ? PIANO_INPUT_PRESS_DEBOUNCE_MS :
                                PIANO_INPUT_RELEASE_DEBOUNCE_MS;
            if (candidate != stable &&
                (uint32_t)(now_ms - candidate_since[index]) >= delay) {
                if (candidate) stable_groups[group] |= bit;
                else stable_groups[group] = (uint16_t)(stable_groups[group] & (uint16_t)~bit);
                changed = 1U;
            }
        }
    }
    published_mask = ((uint64_t)stable_groups[0]) |
                     ((uint64_t)stable_groups[1] << 12) |
                     ((uint64_t)stable_groups[2] << 24) |
                     ((uint64_t)stable_groups[3] << 36);
    if (changed) Publish(now_ms, 1U);
    else Publish(now_ms, 0U);
}

uint64_t PianoInput_GetPressedMask(void) { return published_mask; }

void PianoInput_GetGroups(uint16_t groups[PIANO48_GROUP_COUNT])
{
    uint8_t i;
    if (groups == 0) return;
    for (i = 0U; i < PIANO48_GROUP_COUNT; ++i) groups[i] = stable_groups[i];
}

uint8_t PianoInput_GetBaseNote(void) { return 48U; }
uint16_t PianoInput_GetLastSequence(void) { return last_sequence; }
uint8_t PianoInput_GetOctave(void) { return 3U; }
uint8_t PianoInput_SetOctave(uint8_t octave) { (void)octave; return 0U; }
void PianoInput_SubmitPressure(const uint16_t values[12], uint16_t sequence)
{
    (void)values; (void)sequence;
    /* ADC/velocity is intentionally disabled for the 48-key hardware. */
}

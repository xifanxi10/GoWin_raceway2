#ifndef INSTRUMENT_SETTINGS_H
#define INSTRUMENT_SETTINGS_H
#include "control_client.h"
typedef struct { uint8_t timbre,mode,mute,note[8]; int8_t transpose; uint16_t gain; } InstrumentConfig;
typedef struct {
    InstrumentConfig desired,confirmed;
    uint8_t online,synced,syncing,sync_step,failed,confirmed_valid;
    unsigned last_error;
    ControlClient control;
} InstrumentState;
extern InstrumentState instrument;
void Instrument_Init(void);
void Instrument_Service(void);
/* main-context APIs: 0 means rejected/queue full, desired value is unchanged. */
int Instrument_Set(uint8_t command,uint8_t target,int value);
int Instrument_Reconnect(void);
int Instrument_HasUnapplied(void);
#endif

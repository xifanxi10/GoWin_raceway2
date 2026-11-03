#ifndef CONTROL_CLIENT_H
#define CONTROL_CLIENT_H
#include "instrument_protocol.h"
#define CONTROL_QUEUE_SIZE 8U
#define CONTROL_TIMEOUT_MS 20U
#define CONTROL_BUSY_BACKOFF_MS 5U
enum { CONTROL_OK=0, CONTROL_TIMEOUT=0x100, CONTROL_IO_ERROR=0x101 };
typedef int (*ControlSend)(const uint8_t *frame, void *context);
typedef void (*ControlDone)(const ControlMessage *request, const ControlMessage *reply,
                            unsigned result, void *context);
typedef struct {
    ControlMessage queue[CONTROL_QUEUE_SIZE], request;
    uint8_t count,state,attempts,frame[16];
    uint16_t next_sequence;
    uint32_t since, timeouts,retries,ignored,queue_full,completed;
    ControlSend send; ControlDone done; void *context;
} ControlClient;
void Control_Init(ControlClient *c,ControlSend send,ControlDone done,void *context);
int Control_Enqueue(ControlClient *c,const ControlMessage *m);
void Control_Service(ControlClient *c,uint32_t now);
void Control_TxComplete(ControlClient *c,uint32_t now);
void Control_Receive(ControlClient *c,const ControlMessage *m,uint32_t now);
void Control_FailIO(ControlClient *c);
int Control_Idle(const ControlClient *c);
#endif

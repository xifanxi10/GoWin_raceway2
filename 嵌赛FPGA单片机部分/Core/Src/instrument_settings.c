#include "instrument_settings.h"
#include "control_transport.h"
#include "stm32f4xx_hal.h"
#include <string.h>
InstrumentState instrument;
static uint32_t last_poll;
static void Apply(InstrumentConfig *s,const ControlMessage *m)
{
    switch(m->command) {
    case CMD_TIMBRE:s->timbre=m->p[0];break;
    case CMD_GAIN:s->gain=Protocol_Read16(m->p);break;
    case CMD_NOTE:s->note[m->target-1]=m->p[0];break;
    case CMD_MUTE:s->mute=m->p[0];break;
    case CMD_TRANSPOSE:s->transpose=(int8_t)m->p[0];break;
    case CMD_MODE:s->mode=m->p[0];break;
    default:break;
    }
}
static void Done(const ControlMessage *req,const ControlMessage *reply,unsigned result,void *ctx)
{
    InstrumentState *s=&instrument; (void)ctx;
    if(result!=CONTROL_OK) {
        s->failed=1; s->last_error=result;
        /* Explicit rejection is still proof of a responding peer. */
        s->online=result<CONTROL_TIMEOUT;
        if(result>=CONTROL_TIMEOUT || s->syncing) {
            s->synced=0; s->syncing=0; s->confirmed_valid=0; s->control.count=0;
        }
        if(result==CONTROL_IO_ERROR) ControlTransport_Recover();
        return;
    }
    s->online=1;
    if(req->command==CMD_STATUS && reply) {
        InstrumentConfig actual=s->confirmed;
        actual.timbre=reply->p[0]; actual.mode=reply->p[1]; actual.transpose=(int8_t)reply->p[2];
        actual.mute=reply->p[3]; actual.gain=Protocol_Read16(reply->p+4);
        if(actual.timbre!=s->confirmed.timbre || actual.mode!=s->confirmed.mode ||
           actual.transpose!=s->confirmed.transpose || actual.mute!=s->confirmed.mute ||
           actual.gain!=s->confirmed.gain) {
            /* Observable reset/state change: mute and synchronise, never auto-unmute. */
            s->synced=0; s->syncing=1; s->sync_step=0; s->desired.mute=1; s->confirmed_valid=0;
        }
        s->confirmed=actual;
    } else Apply(&s->confirmed,req);
    if(s->syncing && req->command!=CMD_PING && req->command!=CMD_STATUS) {
        if(++s->sync_step>=22) { s->syncing=0; s->synced=1; s->confirmed_valid=1; s->failed=0; s->last_error=0; }
    }
    if(req->command==CMD_PING && !s->synced && !s->syncing && s->last_error>=CONTROL_TIMEOUT) {
        s->syncing=1; s->sync_step=0; s->desired.mute=1; s->confirmed_valid=0;
    }
}
void Instrument_Init(void)
{
    static const uint8_t notes[8]={60,62,64,65,67,69,71,72};
    memset(&instrument,0,sizeof(instrument));
    instrument.desired.gain=300; instrument.desired.mute=1;
    memcpy(instrument.desired.note,notes,8);
    /* Defaults in confirmed are placeholders until the complete sync succeeds. */
    instrument.confirmed=instrument.desired;
    Control_Init(&instrument.control,ControlTransport_Send,Done,0);
    (void)ControlTransport_Init(&instrument.control);
    instrument.syncing=1;
}
static ControlMessage SyncMessage(void)
{
    ControlMessage m={0}; InstrumentState *s=&instrument; unsigned n=s->sync_step;
    if(n==0) {m.command=CMD_MUTE;m.p[0]=1;}
    else if(n==1) m.command=CMD_TRANSPOSE;
    else if(n==2) {m.command=CMD_TIMBRE;m.p[0]=s->desired.timbre;}
    else if(n<=10) {m.command=CMD_NOTE;m.target=(uint8_t)(n-2);m.p[0]=s->desired.note[n-3];}
    else if(n<=18) {
        m.command=CMD_CHORD;m.target=(uint8_t)(n-10);m.p[0]=1;
        m.p[1]=s->desired.note[n-11];m.p[2]=m.p[3]=m.p[4]=255;
    } else if(n==19) {m.command=CMD_TRANSPOSE;m.p[0]=(uint8_t)s->desired.transpose;}
    else if(n==20) {m.command=CMD_MODE;m.p[0]=s->desired.mode;}
    else {m.command=CMD_GAIN;Protocol_Write16(m.p,s->desired.gain);}
    return m;
}
void Instrument_Service(void)
{
    uint32_t now=HAL_GetTick(); ControlMessage m={0};
    ControlTransport_Service();
    if(Control_Idle(&instrument.control)) {
        if(instrument.syncing) {m=SyncMessage();(void)Control_Enqueue(&instrument.control,&m);}
        else if((uint32_t)(now-last_poll)>=1000) {
            last_poll=now;m.command=instrument.synced?CMD_STATUS:CMD_PING;
            (void)Control_Enqueue(&instrument.control,&m);
        }
    }
    Control_Service(&instrument.control,now);
}
int Instrument_Reconnect(void)
{
    if(!Control_Idle(&instrument.control)) return 0;
    instrument.syncing=1;instrument.synced=0;instrument.sync_step=0;
    instrument.desired.mute=1;instrument.confirmed_valid=0;instrument.failed=0;
    return 1;
}
int Instrument_Set(uint8_t command,uint8_t target,int value)
{
    ControlMessage m={0}; InstrumentConfig candidate; unsigned i;
    if(!instrument.synced || instrument.syncing) return 0;
    m.command=command;m.target=target;
    if(command==CMD_GAIN) {
        if(value<0 || value>1000) return 0;
        Protocol_Write16(m.p,(uint16_t)value);
    } else if(command!=CMD_RELEASE) {
        if(command==CMD_TRANSPOSE) {if(value < -24 || value>24) return 0;}
        else if(value<0 || value>127) return 0;
        m.p[0]=(uint8_t)value;
    }
    /* Chord/ADSR editing intentionally not exposed by this first screen. */
    if(command!=CMD_GAIN && command!=CMD_TIMBRE && command!=CMD_MUTE && command!=CMD_NOTE &&
       command!=CMD_RELEASE && command!=CMD_TRANSPOSE) return 0;
    if(!Protocol_ValidRequest(&m)) return 0;
    candidate=instrument.desired;Apply(&candidate,&m);
    for(i=0;i<8;i++) {
        int note=candidate.note[i]+candidate.transpose;
        if(note<0 || note>127) return 0;
    }
    if(!Control_Enqueue(&instrument.control,&m)) return 0;
    instrument.desired=candidate;instrument.failed=0;instrument.last_error=0;
    return 1;
}

int Instrument_HasUnapplied(void)
{
    const InstrumentConfig *a=&instrument.desired,*b=&instrument.confirmed;
    return !instrument.confirmed_valid || a->timbre!=b->timbre || a->gain!=b->gain ||
           a->mute!=b->mute || a->transpose!=b->transpose || a->mode!=b->mode ||
           memcmp(a->note,b->note,8)!=0;
}

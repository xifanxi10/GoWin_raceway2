#include "control_client.h"
#include <string.h>
enum { IDLE, TX, WAIT_REPLY, BACKOFF };
static void Finish(ControlClient *c,const ControlMessage *reply,unsigned result)
{
    ControlMessage req=c->request;
    c->state=IDLE; if(result==CONTROL_OK) c->completed++;
    if(c->done) c->done(&req,reply,result,c->context);
}
static void Send(ControlClient *c,uint32_t now)
{
    c->attempts++; c->state=TX; c->since=now;
    if(!c->send(c->frame,c->context)) Finish(c,0,CONTROL_IO_ERROR);
}
void Control_Init(ControlClient *c,ControlSend send,ControlDone done,void *context)
{ memset(c,0,sizeof(*c)); c->send=send; c->done=done; c->context=context; c->next_sequence=1; }
int Control_Enqueue(ControlClient *c,const ControlMessage *m)
{
    unsigned i;
    if(!Protocol_ValidRequest(m)) return 0;
    /* Coalesce only unsent settings, never a RELEASE or an in-flight request. */
    if(m->command!=CMD_RELEASE && m->command!=CMD_PING && m->command!=CMD_STATUS) {
        for(i=c->count;i>0;i--) {
            ControlMessage *q=&c->queue[i-1];
            if(q->command==CMD_RELEASE) break; /* preserve action ordering */
            if(q->command==m->command && q->target==m->target &&
               (m->command!=CMD_ADSR || q->p[0]==m->p[0])) { *q=*m; return 1; }
        }
    }
    if(c->count==CONTROL_QUEUE_SIZE) { c->queue_full++; return 0; }
    c->queue[c->count++]=*m; return 1;
}
void Control_Service(ControlClient *c,uint32_t now)
{
    if(c->state==IDLE && c->count) {
        c->request=c->queue[0]; --c->count;
        memmove(c->queue,c->queue+1,c->count*sizeof(c->queue[0]));
        c->request.sequence=c->next_sequence++; c->attempts=0;
        Protocol_Control(c->frame,&c->request); Send(c,now);
    } else if(c->state==WAIT_REPLY && (uint32_t)(now-c->since)>=CONTROL_TIMEOUT_MS) {
        c->timeouts++;
        if(c->attempts>=3) Finish(c,0,CONTROL_TIMEOUT);
        else { c->retries++; Send(c,now); }
    } else if(c->state==BACKOFF && (uint32_t)(now-c->since)>=CONTROL_BUSY_BACKOFF_MS) {
        c->retries++; Send(c,now);
    } else if(c->state==TX && (uint32_t)(now-c->since)>=100) {
        Finish(c,0,CONTROL_IO_ERROR); /* TX watchdog, distinct from ACK timeout */
    }
}
void Control_TxComplete(ControlClient *c,uint32_t now)
{ if(c->state==TX) { c->state=WAIT_REPLY; c->since=now; } }
void Control_Receive(ControlClient *c,const ControlMessage *m,uint32_t now)
{
    unsigned i;
    if((c->state!=WAIT_REPLY && c->state!=BACKOFF) || m->sequence!=c->request.sequence ||
       m->target!=c->request.target) { c->ignored++; return; }
    if(m->command==CMD_STATE && c->request.command==CMD_STATUS) {
        if(m->p[0]>1 || m->p[1]>1 || (int8_t)m->p[2]<-24 || (int8_t)m->p[2]>24 ||
           m->p[3]>1 || Protocol_Read16(m->p+4)>1000) { c->ignored++; return; }
        Finish(c,m,CONTROL_OK); return;
    }
    if(m->command!=CMD_ACK || m->p[0]!=c->request.command || m->p[1]>6) { c->ignored++; return; }
    for(i=2;i<6;i++) if(m->p[i]) { c->ignored++; return; }
    if(c->request.command==CMD_STATUS && m->p[1]==0) { c->ignored++; return; }
    if(m->p[1]==6 && c->attempts<3) { c->state=BACKOFF; c->since=now; return; }
    Finish(c,m,m->p[1]);
}
void Control_FailIO(ControlClient *c) { if(c->state!=IDLE) Finish(c,0,CONTROL_IO_ERROR); }
int Control_Idle(const ControlClient *c) { return c->state==IDLE && c->count==0; }

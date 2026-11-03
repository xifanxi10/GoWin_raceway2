#ifndef CONTROL_TRANSPORT_H
#define CONTROL_TRANSPORT_H
#include "control_client.h"
int ControlTransport_Init(ControlClient *client);
int ControlTransport_Send(const uint8_t *frame,void *context);
void ControlTransport_Service(void);
void ControlTransport_Recover(void);
extern volatile uint32_t control_uart_errors,control_rx_dropped,control_start_errors;
extern ControlParser control_parser;
#endif

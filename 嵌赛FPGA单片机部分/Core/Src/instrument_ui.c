#include "instrument_ui.h"
#include "instrument_settings.h"
#include "pressure_acq.h"
#include "pressure_link.h"
#include "touch_piano.h"
#include "piano_input.h"
#include "pca9555_keys.h"
#include "viz_view.h"
#include "ltdc.h"
#include "touch_800x480.h"
#include <stdio.h>
#include <string.h>

#define COLOR_BG        0xff182330U
#define COLOR_PANEL     0xff33495eU
#define COLOR_ACCENT    0xff43b5adU
#define COLOR_ACTIVE    0xffe2b75aU
#define COLOR_WHITE_KEY 0xffe8edf1U
#define COLOR_BLACK_KEY 0xff17202aU
#define COLOR_KEY_EDGE  0xff687887U
#define COLOR_TEXT_DARK 0xff15202aU

#define PIANO_X         20U
#define PIANO_Y         132U
#define PIANO_WHITE_W   108U
#define PIANO_WHITE_H   298U
#define PIANO_BLACK_W   64U
#define PIANO_BLACK_H   178U
#define ADC_DRAW_PERIOD_MS 40U
#define ADC_VALUE_PERIOD_MS 80U
#define PIANO_DRAW_PERIOD_MS 100U
#define UI_DIAG_PERIOD_MS 1000U

typedef enum {
    UI_PAGE_ADC=0,
    UI_PAGE_PIANO=1,
    UI_PAGE_VIZ=2
} InstrumentPage;

enum {
    PIANO_CTRL_NONE=0,
    PIANO_CTRL_ADC,
    PIANO_CTRL_OCTAVE_DOWN,
    PIANO_CTRL_OCTAVE_UP,
    PIANO_CTRL_MUTE,
    PIANO_CTRL_RELEASE,
    PIANO_CTRL_RESYNC,
    PIANO_CTRL_VIZ
};

static const uint8_t white_semitone[7]={0,2,4,5,7,9,11};
static const uint8_t black_semitone[5]={1,3,6,8,10};
static const uint8_t black_boundary[5]={1,2,4,5,6};
static const char *const note_name[12]={
    "C","C#","D","D#","E","F","F#","G","G#","A","A#","B"
};

static InstrumentPage page;
static uint8_t was_down,touch_ready,ui_rejected,piano_control_down;
static uint16_t drag_gain;
static uint8_t dragging;
static uint32_t last_draw,last_touch,last_gain,last_diag_draw;
static uint32_t last_adc_value_draw;
static uint8_t adc_drawn_height[PRESSURE_CHANNEL_COUNT];
static uint16_t adc_drawn_value[PRESSURE_CHANNEL_COUNT],drawn_gain;
static uint8_t piano_white_meter[7],piano_black_meter[5];
static uint8_t piano_drawn_octave;
static uint8_t drawn_i2c_online;
static uint16_t drawn_i2c_group[PIANO48_GROUP_COUNT];
static char status_line_a[96],status_line_b[96],detail_line_a[96],detail_line_b[96];

static void TextColor(unsigned x,unsigned y,const char *s,uint32_t foreground,
                      uint32_t background)
{
    LCD_SetColor(foreground);
    LCD_SetBackColor(background);
    LCD_DisplayString((uint16_t)x,(uint16_t)y,(char *)s);
}

static void Text(unsigned x,unsigned y,const char *s)
{
    TextColor(x,y,s,LCD_WHITE,COLOR_BG);
}

static void CachedTextWidth(unsigned x,unsigned y,char cache[96],const char *s,
                            unsigned width)
{
    char padded[96];
    if(width>94U) width=94U;
    snprintf(padded,sizeof(padded),"%-*.*s",(int)width,(int)width,s);
    if(strcmp(cache,padded)!=0) {
        Text(x,y,padded);
        strcpy(cache,padded);
    }
}

static void CachedText(unsigned x,unsigned y,char cache[96],const char *s)
{
    CachedTextWidth(x,y,cache,s,94U);
}

static void Rect(unsigned x,unsigned y,unsigned w,unsigned h,uint32_t color)
{
    LCD_SetColor(color);
    LCD_FillRect((uint16_t)x,(uint16_t)y,(uint16_t)w,(uint16_t)h);
}

static void Button(unsigned x,unsigned y,unsigned w,const char *s)
{
    Rect(x,y,w,38,COLOR_PANEL);
    TextColor(x+8U,y+9U,s,LCD_WHITE,COLOR_PANEL);
}

static void Set(uint8_t command,uint8_t target,int value)
{
    ui_rejected=(uint8_t)!Instrument_Set(command,target,value);
}

static void DrawAdcStatic(void)
{
    unsigned i;
    Rect(0,0,800,480,COLOR_BG);
    Text(20,12,"F429 / FPGA    48-key I2C diagnostics");
    Button(20,50,90,"Organ");
    Button(118,50,90,"Pluck");
    Button(216,50,114,"Mute toggle");
    Button(338,50,104,"Release");
    Button(450,50,104,"Resync");
    Button(562,50,104,"Piano >");
    Button(674,50,106,"Viz >");
    Text(20,105,"Gain");
    Rect(100,108,400,16,COLOR_PANEL);
    Text(20,138,"PCA9555 groups: 4 devices x 12 keys; 1 = pressed");
    for(i=0;i<PIANO48_GROUP_COUNT;i++) {
        unsigned x=20U+190U*i;
        Rect(x,164,170,118,COLOR_PANEL);
    }
    Text(20,457,"AA56 v2 1M     PB8=SCL PB9=SDA     addresses 21/22/24/20");
    memset(adc_drawn_height,0,sizeof(adc_drawn_height));
    memset(adc_drawn_value,0xFF,sizeof(adc_drawn_value));
    memset(drawn_i2c_group,0xFF,sizeof(drawn_i2c_group));
    drawn_i2c_online=0xFFU;
    drawn_gain=0U;
    status_line_a[0]=status_line_b[0]='\0';
    detail_line_a[0]=detail_line_b[0]='\0';
    last_diag_draw=0U;
    last_adc_value_draw=0U;
}

static void DrawPianoKeyboardStatic(void)
{
    unsigned i;
    char text[8];
    for(i=0;i<7U;i++) {
        unsigned x=PIANO_X+i*PIANO_WHITE_W;
        unsigned key=white_semitone[i];
        Rect(x,PIANO_Y,PIANO_WHITE_W-2U,PIANO_WHITE_H,COLOR_WHITE_KEY);
        Rect(x+PIANO_WHITE_W-2U,PIANO_Y,2,PIANO_WHITE_H,COLOR_KEY_EDGE);
        snprintf(text,sizeof(text),"%s%u",note_name[key],PianoInput_GetOctave());
        TextColor(x+8U,PIANO_Y+PIANO_WHITE_H-36U,text,COLOR_TEXT_DARK,COLOR_WHITE_KEY);
    }
    for(i=0;i<5U;i++) {
        unsigned key=black_semitone[i];
        unsigned center=PIANO_X+black_boundary[i]*PIANO_WHITE_W;
        unsigned x=center-PIANO_BLACK_W/2U;
        Rect(x,PIANO_Y,PIANO_BLACK_W,PIANO_BLACK_H,COLOR_BLACK_KEY);
        snprintf(text,sizeof(text),"%s%u",note_name[key],PianoInput_GetOctave());
        TextColor(x+8U,PIANO_Y+PIANO_BLACK_H-32U,text,LCD_WHITE,COLOR_BLACK_KEY);
    }
    memset(piano_white_meter,0xFF,sizeof(piano_white_meter));
    memset(piano_black_meter,0xFF,sizeof(piano_black_meter));
    piano_drawn_octave=PianoInput_GetOctave();
}

static void DrawPianoStatic(void)
{
    Rect(0,0,800,480,COLOR_BG);
    Text(20,10,"F429 / FPGA    C3..B6 48-key physical piano");
    Button(20,38,86,"< ADC");
    Button(114,38,90,"Fixed C3");
    Button(212,38,90,"48 keys");
    Button(310,38,120,"Mute toggle");
    Button(438,38,100,"Release");
    Button(546,38,100,"Resync");
    Button(654,38,126,"Viz >");
    DrawPianoKeyboardStatic();
    Text(20,454,"PCA9555 4x12 mask, shared PB8/PB9    debounce 8/30 ms");
    status_line_a[0]=status_line_b[0]='\0';
    detail_line_a[0]=detail_line_b[0]='\0';
    last_diag_draw=0U;
}

static void EnterPage(InstrumentPage new_page,uint32_t now)
{
    if(new_page==UI_PAGE_PIANO) {
        piano_control_down=1U;
        DrawPianoStatic();
    } else if(new_page==UI_PAGE_VIZ) {
        VizView_Enter(now);
    } else {
        was_down=1U;
        dragging=0U;
        DrawAdcStatic();
    }
    page=new_page;
    last_draw=now-(new_page==UI_PAGE_ADC?ADC_DRAW_PERIOD_MS:PIANO_DRAW_PERIOD_MS);
}

static void TouchAdc(uint32_t now,uint8_t down,unsigned x,unsigned y)
{
    if(down && x<800U && y<480U) {
        if(y>=96U && y<=138U && x>=100U && x<=500U && instrument.synced) {
            drag_gain=(uint16_t)((x-100U)*1000U/400U);
            dragging=1U;
            if((uint32_t)(now-last_gain)>=20U) {
                Set(CMD_GAIN,0,drag_gain);
                last_gain=now;
            }
        } else if(!was_down) {
            if(y>=50U && y<88U) {
                if(x>=20U && x<110U) Set(CMD_TIMBRE,0,0);
                else if(x>=118U && x<208U) Set(CMD_TIMBRE,0,1);
                else if(x>=216U && x<330U) Set(CMD_MUTE,0,!instrument.desired.mute);
                else if(x>=338U && x<442U) Set(CMD_RELEASE,0,0);
                else if(x>=450U && x<554U) ui_rejected=(uint8_t)!Instrument_Reconnect();
                else if(x>=562U && x<666U) {
                    EnterPage(UI_PAGE_PIANO,now);
                    return;
                } else if(x>=674U && x<780U) {
                    EnterPage(UI_PAGE_VIZ,now);
                    return;
                }
            }
        }
    }
    if(!down && was_down && dragging) {
        Set(CMD_GAIN,0,drag_gain);
        dragging=0U;
    }
    was_down=down;
}

static uint8_t PianoControl(unsigned x,unsigned y)
{
    if(y<38U || y>=76U) return PIANO_CTRL_NONE;
    if(x>=20U && x<106U) return PIANO_CTRL_ADC;
    if(x>=114U && x<204U) return PIANO_CTRL_OCTAVE_DOWN;
    if(x>=212U && x<302U) return PIANO_CTRL_OCTAVE_UP;
    if(x>=310U && x<430U) return PIANO_CTRL_MUTE;
    if(x>=438U && x<538U) return PIANO_CTRL_RELEASE;
    if(x>=546U && x<646U) return PIANO_CTRL_RESYNC;
    if(x>=654U && x<780U) return PIANO_CTRL_VIZ;
    return PIANO_CTRL_NONE;
}

static void TouchPianoPage(uint32_t now)
{
    uint8_t control=PIANO_CTRL_NONE;

    if(touchInfo.flag && touchInfo.num && touchInfo.x[0]<800U && touchInfo.y[0]<480U) {
        control=PianoControl(touchInfo.x[0],touchInfo.y[0]);
    }

    if(control!=PIANO_CTRL_NONE && !piano_control_down) {
        switch(control) {
        case PIANO_CTRL_ADC:
            EnterPage(UI_PAGE_ADC,now);
            return;
        case PIANO_CTRL_OCTAVE_DOWN:
        case PIANO_CTRL_OCTAVE_UP:
            /* The 48-key physical input is fixed to C3..B6. */
            break;
        case PIANO_CTRL_MUTE:
            Set(CMD_MUTE,0,!instrument.desired.mute);
            break;
        case PIANO_CTRL_RELEASE:
            Set(CMD_RELEASE,0,0);
            break;
        case PIANO_CTRL_RESYNC:
            ui_rejected=(uint8_t)!Instrument_Reconnect();
            break;
        case PIANO_CTRL_VIZ:
            EnterPage(UI_PAGE_VIZ,now);
            return;
        default:
            break;
        }
    }
    piano_control_down=(control!=PIANO_CTRL_NONE);
}

static void Touch(uint32_t now)
{
    uint8_t down;
    unsigned x=0U,y=0U;
    if(!touch_ready || (uint32_t)(now-last_touch)<10U) return;
    last_touch=now;
    Touch_Scan();
    down=(uint8_t)(touchInfo.flag && touchInfo.num);
    if(down) {
        x=touchInfo.x[0];
        y=touchInfo.y[0];
    }
    if(page==UI_PAGE_VIZ) {
        if(VizView_Touch(down,x,y)) EnterPage(UI_PAGE_ADC,now);
        return;
    }
    if(page==UI_PAGE_PIANO) TouchPianoPage(now);
    else TouchAdc(now,down,x,y);
}

static void DrawAdcDynamic(uint32_t now)
{
    unsigned i;
    static const uint8_t address[PIANO48_GROUP_COUNT]={0x21U,0x22U,0x24U,0x20U};
    uint16_t groups[PIANO48_GROUP_COUNT];
    uint8_t online=PCA9555Keys_GetOnlineMask();
    uint8_t update_values=(uint8_t)(adc_drawn_value[0]==0xFFFFU ||
        (uint32_t)(now-last_adc_value_draw)>=ADC_VALUE_PERIOD_MS);
    uint8_t update_diagnostics=(uint8_t)(status_line_b[0]=='\0' ||
        (uint32_t)(now-last_diag_draw)>=UI_DIAG_PERIOD_MS);
    char text[96];
    const char *status;
    PCA9555Keys_GetGroups(groups);
    for(i=0;i<PIANO48_GROUP_COUNT;i++) {
        unsigned x=20U+190U*i;
        if(update_values && (drawn_i2c_group[i]!=groups[i] || drawn_i2c_online!=online)) {
            Rect(x,164,170,118,COLOR_PANEL);
            snprintf(text,sizeof(text),"PCA%u  0x%02X  %s",i+1U,address[i],
                     (online&(1U<<i))?"ON":"OFF");
            TextColor(x+8U,176,text,LCD_WHITE,COLOR_PANEL);
            snprintf(text,sizeof(text),"mask %03X",groups[i]&0x0FFFU);
            TextColor(x+8U,210,text,COLOR_ACTIVE,COLOR_PANEL);
            snprintf(text,sizeof(text),"K%02u - K%02u",i*12U+1U,i*12U+12U);
            TextColor(x+8U,244,text,LCD_WHITE,COLOR_PANEL);
            drawn_i2c_group[i]=groups[i];
        }
    }
    if(update_values) { last_adc_value_draw=now; drawn_i2c_online=online; }
    if(drawn_gain!=instrument.desired.gain) {
        unsigned old_width=drawn_gain*400U/1000U;
        unsigned new_width=instrument.desired.gain*400U/1000U;
        if(new_width>old_width) Rect(100U+old_width,108,new_width-old_width,16,COLOR_ACCENT);
        else if(new_width<old_width) Rect(100U+new_width,108,old_width-new_width,16,COLOR_PANEL);
        drawn_gain=instrument.desired.gain;
    }
    snprintf(text,sizeof(text),"Want %3u%% / FPGA %s%3u%%  ",instrument.desired.gain/10U,
             instrument.confirmed_valid?"":"?",instrument.confirmed.gain/10U);
    CachedTextWidth(520,107,detail_line_a,text,34U);
    status=instrument.syncing?"SYNC / MUTED":!instrument.online?"OFFLINE":instrument.failed?"FAILED":
           !instrument.synced?"NEEDS SYNC":!Control_Idle(&instrument.control)?"PENDING":
           Instrument_HasUnapplied()?"UNAPPLIED":"APPLIED";
    snprintf(text,sizeof(text),"%-15s Timbre %u/%s%u Mute %u/%s%u Error %3u       ",status,
        instrument.desired.timbre,instrument.confirmed_valid?"":"?",instrument.confirmed.timbre,
        instrument.desired.mute,instrument.confirmed_valid?"":"?",instrument.confirmed.mute,
        instrument.last_error);
    CachedText(20,392,status_line_a,text);
    if(update_diagnostics) {
        snprintf(text,sizeof(text),"I2C %02X/4  reads %lu err %lu  drop %lu %s      ",PCA9555Keys_GetOnlineMask(),
            (unsigned long)PCA9555Keys_GetReadCount(),(unsigned long)PCA9555Keys_GetErrorCount(),
            (unsigned long)PressureLink_GetDroppedFrameCount(),
            ui_rejected?"REQUEST REJECTED":"");
        CachedText(20,424,status_line_b,text);
        last_diag_draw=now;
    }
}

static void DrawPianoDynamic(uint32_t now)
{
    unsigned i;
    uint64_t pressed_mask=PianoInput_GetPressedMask();
    uint16_t groups[PIANO48_GROUP_COUNT];
    char text[96];
    const char *status;
    PianoInput_GetGroups(groups);
    snprintf(text,sizeof(text),"Range C3 - B6    base MIDI %u    mask %012llX",
             PianoInput_GetBaseNote(),(unsigned long long)pressed_mask);
    CachedText(20,84,status_line_a,text);
    if(status_line_b[0]=='\0' || (uint32_t)(now-last_diag_draw)>=UI_DIAG_PERIOD_MS) {
        status=instrument.syncing?"SYNC / MUTED":!instrument.online?"OFFLINE":instrument.failed?"FAILED":
               !instrument.synced?"NEEDS SYNC":!Control_Idle(&instrument.control)?"PENDING":"READY";
        snprintf(text,sizeof(text),"AA56 v2 seq %5u  I2C %02X/4  err %lu drop %lu  %s %s",
                 PianoInput_GetLastSequence(),PCA9555Keys_GetOnlineMask(),
                 (unsigned long)PCA9555Keys_GetErrorCount(),
                 (unsigned long)PressureLink_GetDroppedFrameCount(),status,
                 ui_rejected?"REQUEST REJECTED":"");
        CachedText(20,104,status_line_b,text);
        last_diag_draw=now;
    }
    if(piano_drawn_octave!=3U) {
        for(i=0;i<7U;i++) {
            unsigned x=PIANO_X+i*PIANO_WHITE_W;
            unsigned key=white_semitone[i];
            snprintf(text,sizeof(text),"%s3",note_name[key]);
            TextColor(x+8U,PIANO_Y+PIANO_WHITE_H-36U,text,COLOR_TEXT_DARK,COLOR_WHITE_KEY);
        }
        for(i=0;i<5U;i++) {
            unsigned key=black_semitone[i];
            unsigned center=PIANO_X+black_boundary[i]*PIANO_WHITE_W;
            snprintf(text,sizeof(text),"%s3",note_name[key]);
            TextColor(center-PIANO_BLACK_W/2U+8U,PIANO_Y+PIANO_BLACK_H-32U,
                      text,LCD_WHITE,COLOR_BLACK_KEY);
        }
        piano_drawn_octave=3U;
    }
    for(i=0;i<7U;i++) {
        unsigned x=PIANO_X+i*PIANO_WHITE_W;
        unsigned key=white_semitone[i];
        uint8_t width=(pressed_mask&(1ULL<<key)) ? (uint8_t)(PIANO_WHITE_W-12U) : 0U;
        if(piano_white_meter[i]!=width) {
            Rect(x+5U,PIANO_Y+PIANO_WHITE_H-12U,PIANO_WHITE_W-12U,7,COLOR_WHITE_KEY);
            if(width) Rect(x+5U,PIANO_Y+PIANO_WHITE_H-12U,width,7,COLOR_ACCENT);
            piano_white_meter[i]=width;
        }
    }
    for(i=0;i<5U;i++) {
        unsigned key=black_semitone[i];
        unsigned center=PIANO_X+black_boundary[i]*PIANO_WHITE_W;
        unsigned x=center-PIANO_BLACK_W/2U;
        uint8_t width=(pressed_mask&(1ULL<<key)) ? (uint8_t)(PIANO_BLACK_W-10U) : 0U;
        if(piano_black_meter[i]!=width) {
            Rect(x+5U,PIANO_Y+PIANO_BLACK_H-11U,PIANO_BLACK_W-10U,6,COLOR_BLACK_KEY);
            if(width) Rect(x+5U,PIANO_Y+PIANO_BLACK_H-11U,width,6,COLOR_ACCENT);
            piano_black_meter[i]=width;
        }
    }
}

void InstrumentUI_Init(void)
{
    LTDC_Init();
    LCD_DisplayDirection(Direction_H);
    LCD_SetFont(&Font16);
    LCD_SetBackColor(COLOR_BG);
    LCD_ClearRect(0,0,800,480);
    touch_ready=(Touch_Init()==SUCCESS);
    page=UI_PAGE_ADC;
    DrawAdcStatic();
}

void InstrumentUI_Service(void)
{
    uint32_t now=HAL_GetTick();
    Touch(now);
    if(page==UI_PAGE_VIZ) {
        /* The viz page throttles itself (33 ms) and owns its own redraws. */
        VizView_Service(now);
        return;
    }
    if((uint32_t)(now-last_draw)<
       (page==UI_PAGE_ADC?ADC_DRAW_PERIOD_MS:PIANO_DRAW_PERIOD_MS)) return;
    last_draw=now;
    if(page==UI_PAGE_PIANO) DrawPianoDynamic(now);
    else DrawAdcDynamic(now);
}

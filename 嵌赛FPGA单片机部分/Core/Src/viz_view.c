#include "viz_view.h"
#include "viz_link.h"
#include "main.h"
#include "ltdc.h"
#include <stdio.h>
#include <string.h>

/* Same palette as instrument_ui.c so the third page looks like the other two. */
#define COLOR_BG        0xff182330U
#define COLOR_PANEL     0xff33495eU
#define COLOR_ACCENT    0xff43b5adU
#define COLOR_PEAK      0xffe2b75aU
#define COLOR_TEXT      0xffe8edf1U
#define COLOR_EDGE      0xff2a3a4aU
#define COLOR_GRID      0xff243440U
#define COLOR_AXIS      0xff3d5468U
#define COLOR_DIM       0xff8fa0aeU
#define COLOR_ENVELOPE  0xff2c5f62U   /* dim teal: min/max band behind the trace */

/* Plot area: keeps clear of the existing header (y<=76) and footer (y>=440). */
#define AREA_X          20U
#define AREA_W          760U
#define AREA_Y          80U
#define AREA_H          352U
#define AREA_BOTTOM     (AREA_Y + AREA_H)               /* 432, exclusive */

/* Lissajous gets a square box so a circle stays a circle.  It is inset to leave
 * room for the tick labels, which is what makes the picture readable:
 * X = x[n], Y = x[n - T/4], both from the same mono channel (see xy_scope.sv). */
#define XY_BOX_SIZE     312U
#define XY_BOX_X        244U
#define XY_BOX_Y        100U
#define XY_TICKS        4U      /* four divisions: +1, +0.5, 0, -0.5, -1 */
#define XY_FONT_W       6U      /* Font12 is 12 x 6 */

#define HEADER_Y        8U
#define BUTTON_Y        34U
#define BUTTON_H        38U
#define FOOTER_Y        440U

#define DRAW_PERIOD_MS  33U    /* 30 fps is plenty for a 47 fps source */
#define TEXT_PERIOD_MS  200U
#define RATE_PERIOD_MS  500U

#define WAVE_COLUMNS    256U
#define WAVE_PIXELS     AREA_W /* one interpolated run per screen column */
#define SPEC_BANDS      64U
#define XY_POINTS       256U

/* The driver keeps the canvas parameters private, so the fast path reads the
 * frame buffer address from the HAL handle and assumes the settings the rest of
 * the firmware uses: RGB565, Direction_H (set by InstrumentUI_Init).  A 1-px
 * wide fill costs a full DMA2D start/stop, which is why a 760-column waveform
 * written that way only reached single-digit frames per second. */
#if (ColorMode_0 == LTDC_PIXEL_FORMAT_RGB565)
#define VIZ_DIRECT_FB   1U
#else
#define VIZ_DIRECT_FB   0U
#endif

static uint16_t *viz_fb;

static VizViewId active;
static uint32_t last_draw;
static uint32_t last_text;
static uint32_t last_rate;
static uint8_t control_down;
static uint8_t waiting_shown;

/* Previous geometry, so a frame only repaints the pixels that changed. */
static int16_t wave_top[WAVE_PIXELS];
static int16_t wave_bottom[WAVE_PIXELS];
static uint8_t spec_height[SPEC_BANDS];
static uint8_t spec_peak[SPEC_BANDS];
static uint8_t spec_valid;
static int16_t xy_x[XY_POINTS];
static int16_t xy_y[XY_POINTS];
static uint16_t xy_count;

/* Vertical zoom.  The B board sends 8-bit offset binary scaled to the full
 * 16-bit range, so a quiet note only uses a handful of codes; zooming the
 * picture is the only thing the MCU can do without touching the FPGA. */
static const uint8_t gain_table[3] = {1U, 2U, 4U};
static const char *const gain_label[3] = {"Gain x1", "Gain x2", "Gain x4"};
static uint8_t gain_index;
static uint8_t clip_flag;        /* set while scaling the frame being drawn */
static uint8_t last_clipped;     /* carried over to the status line */

static char header_status[32];
static char footer_line_a[96];
static char footer_line_b[96];
static char stat_cache[6][96];

/* Rates and timings, all measured on the target: "in" is what the link delivers,
 * "out" what this page manages to draw. */
static uint32_t rate_draws;
static uint32_t rate_bytes;
static uint32_t rate_fps;
static uint32_t rate_kbps;
static uint32_t rate_in;
static uint32_t draw_ms;
static uint32_t loop_ms;
static uint32_t last_entry;
static uint32_t d_err;
static uint32_t d_ovf;
static uint32_t d_crc;
static uint32_t prev_err;
static uint32_t prev_ovf;
static uint32_t prev_crc;
/* Per-type rates, the fastest way to see which frame kind is being lost. */
static uint32_t hdr_prev[4];
static uint32_t ok_prev[4];
static uint32_t hdr_rate[4];
static uint32_t ok_rate[4];

static uint16_t Rgb565(uint32_t argb)
{
    return (uint16_t)(((argb & 0x00F80000U) >> 8) | ((argb & 0x0000FC00U) >> 5) |
                      ((argb & 0x000000F8U) >> 3));
}

/* One vertical run; falls back to the generic driver when the canvas is not the
 * RGB565 single layer this board uses. */
static void PutRun(unsigned x, unsigned y0, unsigned y1, uint32_t argb)
{
    if (x >= 800U || y0 > y1 || y0 >= 480U) return;
    if (y1 > 479U) y1 = 479U;
#if VIZ_DIRECT_FB
    if (viz_fb == 0) return;
    {
        uint16_t colour = Rgb565(argb);
        uint16_t *pixel = viz_fb + (y0 * 800U) + x;
        unsigned count = y1 - y0;
        do {
            *pixel = colour;
            pixel += 800U;
        } while (count--);
    }
#else
    LCD_SetColor(argb);
    LCD_FillRect((uint16_t)x, (uint16_t)y0, 1U, (uint16_t)(y1 - y0 + 1U));
#endif
}

/* Single pixel with the colour already converted for the fast path. */
static void Plot(int x, int y, uint32_t argb, uint16_t colour565)
{
    if (x < 0 || y < 0 || x >= 800 || y >= 480) return;
#if VIZ_DIRECT_FB
    if (viz_fb == 0) return;
    viz_fb[((unsigned)y * 800U) + (unsigned)x] = colour565;
#else
    (void)colour565;
    LCD_DrawPoint((uint16_t)x, (uint16_t)y, argb);
#endif
}

static void PutLine(int x0, int y0, int x1, int y1, uint32_t argb)
{
    int dx = (x1 > x0) ? (x1 - x0) : (x0 - x1);
    int dy = (y1 > y0) ? (y1 - y0) : (y0 - y1);
    int sx = (x0 < x1) ? 1 : -1;
    int sy = (y0 < y1) ? 1 : -1;
    int err = dx - dy;
    uint16_t colour = Rgb565(argb);

    for (;;) {
        Plot(x0, y0, argb, colour);
        if (x0 == x1 && y0 == y1) break;
        {
            int e2 = 2 * err;
            if (e2 > -dy) {
                err -= dy;
                x0 += sx;
            }
            if (e2 < dx) {
                err += dx;
                y0 += sy;
            }
        }
    }
}

static void Fill(unsigned x, unsigned y, unsigned w, unsigned h, uint32_t color)
{
    if (w == 0U || h == 0U || x >= 800U || y >= 480U) return;
    LCD_SetColor(color);
    LCD_FillRect((uint16_t)x, (uint16_t)y, (uint16_t)w, (uint16_t)h);
}

static void TextColor(unsigned x, unsigned y, const char *s, uint32_t foreground,
                      uint32_t background)
{
    LCD_SetColor(foreground);
    LCD_SetBackColor(background);
    LCD_DisplayString((uint16_t)x, (uint16_t)y, (char *)s);
}

static void CachedText(unsigned x, unsigned y, char cache[96], const char *s)
{
    char padded[96];
    snprintf(padded, sizeof(padded), "%-94.94s", s);
    if (strcmp(cache, padded) != 0) {
        TextColor(x, y, padded, COLOR_TEXT, COLOR_BG);
        strcpy(cache, padded);
    }
}

static void Button(unsigned x, unsigned y, unsigned w, const char *s, uint8_t on)
{
    uint32_t background = on ? COLOR_ACCENT : COLOR_PANEL;
    Fill(x, y, w, BUTTON_H, background);
    TextColor(x + 8U, y + 11U, s, on ? COLOR_BG : COLOR_TEXT, background);
}

/* One received level (0..255, 0x80 = silence) with the selected zoom applied. */
static int ScaleLevel(uint8_t level)
{
    int delta = ((int)level - 128) * (int)gain_table[gain_index];
    if (delta > 127) {
        delta = 127;
        clip_flag = 1U;
    } else if (delta < -128) {
        delta = -128;
        clip_flag = 1U;
    }
    return 128 + delta;
}

static int LevelToY(int level)
{
    return (int)AREA_Y + (((255 - level) * (int)AREA_H) >> 8);
}

static void ResetGeometry(void)
{
    unsigned i;
    for (i = 0U; i < WAVE_PIXELS; ++i) {
        wave_top[i] = -1;
        wave_bottom[i] = -1;
    }
    for (i = 0U; i < SPEC_BANDS; ++i) {
        spec_height[i] = 0U;
        spec_peak[i] = 0U;
    }
    spec_valid = 0U;
    xy_count = 0U;
    memset(stat_cache, 0, sizeof(stat_cache));
    footer_line_a[0] = '\0';
    footer_line_b[0] = '\0';
}

static void ClearArea(void)
{
    Fill(AREA_X, AREA_Y, AREA_W, AREA_H, COLOR_BG);
    ResetGeometry();
}

static void DrawChrome(void)
{
    Fill(0U, 0U, 800U, 480U, COLOR_BG);
    TextColor(20U, HEADER_Y, "B board visualizer   AA 7C / 2 Mbit   800x480", COLOR_TEXT,
              COLOR_BG);
    Button(20U, BUTTON_Y, 76U, "< ADC", 0U);
    Button(100U, BUTTON_Y, 90U, "Wave", active == VIZ_VIEW_WAVE);
    Button(194U, BUTTON_Y, 90U, "Spec", active == VIZ_VIEW_SPEC);
    Button(288U, BUTTON_Y, 90U, "XY", active == VIZ_VIEW_XY);
    Button(382U, BUTTON_Y, 90U, "Stat", active == VIZ_VIEW_STAT);
    Button(476U, BUTTON_Y, 94U, gain_label[gain_index], 0U);
    header_status[0] = '\0';

    LCD_SetColor(COLOR_EDGE);
    LCD_DrawRect((uint16_t)(AREA_X - 2U), (uint16_t)(AREA_Y - 2U),
                 (uint16_t)(AREA_W + 2U), (uint16_t)(AREA_H + 2U));
    ClearArea();
    waiting_shown = 0U;
}

static void DrawWaiting(void)
{
    static const char *const message = "waiting for B board frames (AA 7C)";
    unsigned width = (unsigned)strlen(message) * 8U;
    unsigned x = AREA_X + ((AREA_W - width) / 2U);
    unsigned y = AREA_Y + (AREA_H / 2U) - 8U;

    Fill(AREA_X, AREA_Y, AREA_W, AREA_H, COLOR_BG);
    ResetGeometry();
    TextColor(x, y, message, COLOR_DIM, COLOR_BG);
    waiting_shown = 1U;
}

/* 760 / 256 = 95/32 and 760 / 64 = 190/16, so both grids tile the area exactly. */
static unsigned ColumnX(unsigned index)
{
    return AREA_X + ((index * 95U) >> 5);
}

static unsigned BandX(unsigned index)
{
    return AREA_X + ((index * 190U) >> 4);
}

/* One screen column of the waveform.  A received column spans 3 screen pixels,
 * so the top/bottom edges are interpolated in DrawWave and each screen column
 * is a 1-px run: that removes the staircase without extra link bandwidth. */
static void DrawWaveColumn(unsigned x, int low, int high)
{
    unsigned index = x - AREA_X;
    int top;
    int bottom;
    int centre;

    if (index >= WAVE_PIXELS) return;
    if (high < low) {
        int swap = high;
        high = low;
        low = swap;
    }
    top = LevelToY(high);
    bottom = LevelToY(low);
    if (wave_top[index] == top && wave_bottom[index] == bottom) return;

    if (wave_top[index] >= 0) {
        PutRun(x, (unsigned)wave_top[index], (unsigned)wave_bottom[index], COLOR_BG);
    }
#if VIZ_DIRECT_FB
    if (viz_fb != 0 && (bottom - top) > 2) {
        centre = (top + bottom) / 2;
        PutRun(x, (unsigned)top, (unsigned)(centre - 1), COLOR_ENVELOPE);
        PutRun(x, (unsigned)centre, (unsigned)(centre + 1), COLOR_ACCENT);
        PutRun(x, (unsigned)(centre + 2), (unsigned)bottom, COLOR_ENVELOPE);
    } else
#endif
    {
        PutRun(x, (unsigned)top, (unsigned)bottom, COLOR_ACCENT);
    }
    wave_top[index] = (int16_t)top;
    wave_bottom[index] = (int16_t)bottom;
}

static void DrawWave(const VizFrame *frame)
{
    unsigned i;

    if (frame->length < (WAVE_COLUMNS * 2U)) return;
    clip_flag = 0U;
    for (i = 0U; i < WAVE_COLUMNS; ++i) {
        unsigned x0 = ColumnX(i);
        unsigned x1 = ColumnX(i + 1U);
        unsigned next = (i + 1U < WAVE_COLUMNS) ? (i + 1U) : i;
        unsigned span = x1 - x0;
        int low0 = ScaleLevel(frame->payload[2U * i]);
        int high0 = ScaleLevel(frame->payload[2U * i + 1U]);
        int low1 = ScaleLevel(frame->payload[2U * next]);
        int high1 = ScaleLevel(frame->payload[2U * next + 1U]);
        unsigned x;

        for (x = x0; x < x1; ++x) {
            unsigned step = x - x0;
            int low = low0 + (((low1 - low0) * (int)step) / (int)span);
            int high = high0 + (((high1 - high0) * (int)step) / (int)span);
            DrawWaveColumn(x, low, high);
        }
    }
    last_clipped = clip_flag;
}

static void DrawSpec(const VizFrame *frame)
{
    unsigned i;
    if (frame->length < (SPEC_BANDS * 2U)) return;
    for (i = 0U; i < SPEC_BANDS; ++i) {
        unsigned x0 = BandX(i);
        unsigned w = BandX(i + 1U) - x0;
        unsigned bar = (w > 1U) ? (w - 1U) : 1U;
        uint8_t value = frame->payload[i];
        uint8_t peak = frame->payload[SPEC_BANDS + i];
        uint8_t height = (uint8_t)(((unsigned)value * AREA_H) >> 8);
        uint8_t peak_height = (uint8_t)(((unsigned)peak * AREA_H) >> 8);

        if (spec_valid != 0U && spec_height[i] == height && spec_peak[i] == peak) {
            continue;
        }
        Fill(x0, AREA_Y, bar, AREA_H, COLOR_BG);           /* erase the column */
        if (height > 0U) {
            Fill(x0, AREA_BOTTOM - height, bar, height, COLOR_ACCENT);
        }
        if (peak_height > 0U) {
            Fill(x0, (unsigned)(AREA_BOTTOM - peak_height - 2U), bar, 2U, COLOR_PEAK);
        }
        spec_height[i] = height;
        spec_peak[i] = peak;
    }
    spec_valid = 1U;
}

static void DrawPolyline(const int16_t *xs, const int16_t *ys, uint16_t count,
                         uint32_t color)
{
    uint16_t i;
    for (i = 1U; i < count; ++i) {
        PutLine(xs[i - 1U], ys[i - 1U], xs[i], ys[i], color);
    }
}

/* Small text in the 12x6 font; the rest of the page keeps Font16. */
static void SmallText(unsigned x, unsigned y, const char *s, uint32_t colour)
{
    LCD_SetFont(&Font12);
    LCD_SetColor(colour);
    LCD_SetBackColor(COLOR_BG);
    LCD_DisplayString((uint16_t)x, (uint16_t)y, (char *)s);
    LCD_SetFont(&Font16);
}

static void SmallTextRight(unsigned right, unsigned y, const char *s, uint32_t colour)
{
    unsigned width = (unsigned)strlen(s) * XY_FONT_W;
    SmallText((right > width) ? (right - width) : 0U, y, s, colour);
}

static void SmallTextCentre(unsigned centre, unsigned y, const char *s, uint32_t colour)
{
    unsigned width = (unsigned)strlen(s) * XY_FONT_W;
    SmallText((centre > (width / 2U)) ? (centre - (width / 2U)) : 0U, y, s, colour);
}

/* Border, quarter grid and the centre axes.  Redrawn after every erase because
 * the old trace is repainted in the background colour and would punch holes in
 * the grid otherwise. */
static void DrawXyGrid(void)
{
    unsigned i;
    unsigned right = XY_BOX_X + XY_BOX_SIZE;
    unsigned bottom = XY_BOX_Y + XY_BOX_SIZE;

    for (i = 0U; i <= XY_TICKS; ++i) {
        unsigned offset = (XY_BOX_SIZE * i) / XY_TICKS;
        uint32_t colour;
        if (i == 0U || i == XY_TICKS) colour = COLOR_EDGE;
        else if (i == XY_TICKS / 2U) colour = COLOR_AXIS;
        else colour = COLOR_GRID;
        PutLine((int)XY_BOX_X, (int)(XY_BOX_Y + offset), (int)right,
                (int)(XY_BOX_Y + offset), colour);
        PutLine((int)(XY_BOX_X + offset), (int)XY_BOX_Y, (int)(XY_BOX_X + offset),
                (int)bottom, colour);
    }
}

/* Legend and tick labels.  Only drawn when the box is empty, because they live
 * outside the trace area and never need erasing. */
static void DrawXyLabels(void)
{
    VizStat stat;
    char text[48];
    char y_axis[20];
    unsigned a = 1U;
    unsigned b = 4U;
    unsigned i;
    unsigned gain = gain_table[gain_index];

    if (VizLink_GetStat(&stat)) {
        if (stat.ratio_a >= 1U && stat.ratio_a <= 16U) a = stat.ratio_a;
        if (stat.ratio_b >= 1U && stat.ratio_b <= 16U) b = stat.ratio_b;
    }
    if (a == 1U) {
        snprintf(y_axis, sizeof(y_axis), "x[n - T/%u]", b);
    } else {
        snprintf(y_axis, sizeof(y_axis), "x[n - T*%u/%u]", a, b);
    }
    /* X and Y are the two axes of the same mono channel; that is the one thing
     * this picture cannot show by itself. */
    snprintf(text, sizeof(text), "X = x[n]");
    SmallText(AREA_X + 2U, AREA_Y, text, COLOR_ACCENT);
    snprintf(text, sizeof(text), "Y = %s", y_axis);
    SmallText(AREA_X + 2U + 14U * XY_FONT_W, AREA_Y, text, COLOR_PEAK);
    snprintf(text, sizeof(text), "same mono channel, ticks in full-scale units");
    SmallText(AREA_X + 2U + 34U * XY_FONT_W, AREA_Y, text, COLOR_DIM);

    for (i = 0U; i <= XY_TICKS; ++i) {
        unsigned offset = (XY_BOX_SIZE * i) / XY_TICKS;
        unsigned above = (2U * i < XY_TICKS) ? (XY_TICKS - 2U * i) : (2U * i - XY_TICKS);
        unsigned denominator = 2U * gain * XY_TICKS;
        unsigned hundredths = (200U * above + gain * XY_TICKS) / denominator;

        if (2U * i == XY_TICKS) {
            snprintf(text, sizeof(text), "0");
        } else {
            snprintf(text, sizeof(text), "%c%u.%02u",
                     (2U * i < XY_TICKS) ? '+' : '-', hundredths / 100U,
                     hundredths % 100U);
        }
        /* Y axis on the left, X axis underneath: the usual convention. */
        SmallTextRight(XY_BOX_X - 6U, XY_BOX_Y + offset - 6U, text, COLOR_DIM);
        SmallTextCentre(XY_BOX_X + offset, XY_BOX_Y + XY_BOX_SIZE + 4U, text, COLOR_DIM);
    }
}

static void DrawXy(const VizFrame *frame)
{
    uint16_t i;
    const unsigned span = XY_BOX_SIZE - 1U;

    if (frame->length < (XY_POINTS * 2U)) return;
    clip_flag = 0U;
    /* Old trace first, then the chrome it covered, then the new trace. */
    if (xy_count > 1U) DrawPolyline(xy_x, xy_y, xy_count, COLOR_BG);
    DrawXyGrid();
    if (xy_count == 0U) DrawXyLabels();

    for (i = 0U; i < XY_POINTS; ++i) {
        unsigned xv = (unsigned)ScaleLevel(frame->payload[2U * i]);
        unsigned yv = (unsigned)ScaleLevel(frame->payload[2U * i + 1U]);
        xy_x[i] = (int16_t)(XY_BOX_X + (xv * span) / 255U);
        xy_y[i] = (int16_t)(XY_BOX_Y + ((255U - yv) * span) / 255U);
    }
    xy_count = XY_POINTS;
    DrawPolyline(xy_x, xy_y, xy_count, COLOR_ACCENT);
    last_clipped = clip_flag;
}

static void DrawStat(void)
{
    const VizLinkStats *stats = VizLink_GetStats();
    VizStat stat;
    static char lines[6][96];
    unsigned i;
    unsigned y = AREA_Y + 8U;

    memset(lines, 0, sizeof(lines));
    if (!VizLink_GetStat(&stat)) {
        snprintf(lines[0], sizeof(lines[0]),
                 "no STAT frame yet (type 0x04, 22 bytes, ~11 fps)");
    } else {
        snprintf(lines[0], sizeof(lines[0]),
                 "peak %3u/255    rms %3u/255    voices %2u/12", stat.peak,
                 stat.rms, stat.voices);
        snprintf(lines[1], sizeof(lines[1]),
                 "flags %02X  %s  %s  %s    Lissajous %u:%u", stat.flags,
                 (stat.flags & VIZ_STAT_FLAG_CLIP) ? "CLIP" : "clean",
                 (stat.flags & VIZ_STAT_FLAG_I2S) ? "I2S online" : "I2S offline",
                 (stat.flags & VIZ_STAT_FLAG_FFT_OVF) ? "FFT overflow" : "FFT ok",
                 stat.ratio_a, stat.ratio_b);
        snprintf(lines[2], sizeof(lines[2]), "samples %lu    fft frames %u",
                 (unsigned long)stat.sample_count, stat.fft_frame);
    }
    /* The four counters that separate "source is slow" from "we lose frames". */
    snprintf(lines[3], sizeof(lines[3]), "hdr/s   W %2lu  S %2lu  X %2lu  T %2lu",
             (unsigned long)hdr_rate[0], (unsigned long)hdr_rate[1],
             (unsigned long)hdr_rate[2], (unsigned long)hdr_rate[3]);
    snprintf(lines[4], sizeof(lines[4]), "ok/s    W %2lu  S %2lu  X %2lu  T %2lu",
             (unsigned long)ok_rate[0], (unsigned long)ok_rate[1],
             (unsigned long)ok_rate[2], (unsigned long)ok_rate[3]);
    snprintf(lines[5], sizeof(lines[5]),
             "crcW %lu S%lu X%lu T%lu  junk %lu  unk %lu  ovf %lu  rst %lu",
             (unsigned long)stats->crc_bad[0], (unsigned long)stats->crc_bad[1],
             (unsigned long)stats->crc_bad[2], (unsigned long)stats->crc_bad[3],
             (unsigned long)stats->discarded, (unsigned long)stats->unknown_type,
             (unsigned long)stats->ring_overflow, (unsigned long)stats->restarts);
    for (i = 0U; i < 6U; ++i) {
        CachedText(AREA_X + 8U, y, stat_cache[i], lines[i]);
        y += 24U;
    }
}

static void DrawHeaderStatus(void)
{
    VizStat stat;
    char line[40];
    uint8_t i2s = 0U;

    if (VizLink_GetStat(&stat)) i2s = (uint8_t)((stat.flags & VIZ_STAT_FLAG_I2S) != 0U);
    snprintf(line, sizeof(line), "%s  %s", VizLink_LinkAlive() ? "2M OK" : "NO LINK",
             i2s ? "I2S ON" : "I2S OFF");
    if (strcmp(header_status, line) != 0) {
        Fill(578U, BUTTON_Y, 202U, BUTTON_H, COLOR_BG);
        TextColor(590U, BUTTON_Y + 11U, line,
                  VizLink_LinkAlive() ? COLOR_ACCENT : COLOR_PEAK, COLOR_BG);
        strcpy(header_status, line);
    }
}

static VizFrameType ActiveType(void)
{
    switch (active) {
    case VIZ_VIEW_WAVE: return VIZ_FRAME_WAVE;
    case VIZ_VIEW_SPEC: return VIZ_FRAME_SPEC;
    case VIZ_VIEW_XY:   return VIZ_FRAME_XY;
    default:            return VIZ_FRAME_STAT;
    }
}

static void SyncInCounter(void)
{
    const VizLinkStats *stats = VizLink_GetStats();
    unsigned i;
    for (i = 0U; i < 4U; ++i) {
        hdr_prev[i] = stats->headers[i];
        ok_prev[i] = stats->frames[i];
        hdr_rate[i] = 0U;
        ok_rate[i] = 0U;
    }
    rate_in = 0U;
}

static void UpdateRates(uint32_t now)
{
    const VizLinkStats *stats = VizLink_GetStats();
    uint32_t elapsed;
    unsigned i;

    if ((uint32_t)(now - last_rate) < RATE_PERIOD_MS) return;
    elapsed = now - last_rate;
    rate_fps = (uint32_t)(((uint64_t)rate_draws * 1000U) / elapsed);
    rate_kbps = (uint32_t)(((uint64_t)(stats->rx_bytes - rate_bytes) * 1000U) /
                           (elapsed * 1024U));
    for (i = 0U; i < 4U; ++i) {
        hdr_rate[i] = (uint32_t)(((uint64_t)(stats->headers[i] - hdr_prev[i]) * 1000U) /
                                 elapsed);
        ok_rate[i] = (uint32_t)(((uint64_t)(stats->frames[i] - ok_prev[i]) * 1000U) /
                                elapsed);
        hdr_prev[i] = stats->headers[i];
        ok_prev[i] = stats->frames[i];
    }
    {
        int index = VizMailboxes_Index((uint8_t)ActiveType());
        rate_in = (index >= 0) ? ok_rate[index] : 0U;
    }
    d_err = (uint32_t)(((uint64_t)(stats->uart_errors - prev_err) * 1000U) / elapsed);
    d_ovf = (uint32_t)(((uint64_t)(stats->ring_overflow - prev_ovf) * 1000U) / elapsed);
    d_crc = (uint32_t)(((uint64_t)(stats->crc_errors - prev_crc) * 1000U) / elapsed);
    prev_err = stats->uart_errors;
    prev_ovf = stats->ring_overflow;
    prev_crc = stats->crc_errors;
    rate_bytes = stats->rx_bytes;
    rate_draws = 0U;
    last_rate = now;
}

/* One-line verdict so a wrong frame rate does not need a logic analyser to
 * classify: source, wiring, ring overflow or drawing. */
static const char *Verdict(void)
{
    if (!VizLink_LinkAlive()) return "NO LINK";
    if (rate_kbps < 20U) return "SRC SLOW";
    if (d_err > 0U) return "UART ERR";
    if (d_ovf > 0U) return "RING OVF";
    if (d_crc > 5U) return "CRC ERR";
    if (rate_fps < 20U) return "DRAW SLOW";
    return 0;
}

static void DrawFooter(void)
{
    const VizLinkStats *stats = VizLink_GetStats();
    static const char *const names[4] = {"WAVE", "SPEC", "XY", "STAT"};
    const char *verdict = Verdict();
    char line[96];

    snprintf(line, sizeof(line), "%s %s  in %2lu  out %2lu  draw %3lums  loop %3lums%s",
             names[active], gain_label[gain_index], (unsigned long)rate_in,
             (unsigned long)rate_fps, (unsigned long)draw_ms, (unsigned long)loop_ms,
             last_clipped ? "  CLIP!" : "");
    if (verdict) {
        size_t used = strlen(line);
        snprintf(line + used, sizeof(line) - used, "  [%s]", verdict);
    }
    CachedText(20U, FOOTER_Y, footer_line_a, line);
    snprintf(line, sizeof(line),
             "rx %2lu KB/s  frames %lu  crc %lu  junk %lu  ovf %lu  err %lu  rst %lu",
             (unsigned long)rate_kbps,
             (unsigned long)(stats->frames[0] + stats->frames[1] + stats->frames[2] +
                             stats->frames[3]),
             (unsigned long)stats->crc_errors, (unsigned long)stats->discarded,
             (unsigned long)stats->ring_overflow, (unsigned long)stats->uart_errors,
             (unsigned long)stats->restarts);
    CachedText(20U, (unsigned)(FOOTER_Y + 20U), footer_line_b, line);
}

void VizView_Enter(uint32_t now)
{
    if (viz_fb == 0) {
        /* The HAL only writes CFBAR, it does not mirror the address into the
         * handle, so read the layer register.  Anything that is not SDRAM is
         * ignored and the slow driver path stays in charge. */
        uint32_t address = LTDC_Layer1->CFBAR;
        viz_fb = (address >= 0xC0000000U) ? (uint16_t *)address : 0;
    }
    active = VIZ_VIEW_WAVE;
    control_down = 0U;
    last_draw = now - DRAW_PERIOD_MS;
    last_text = 0U;
    last_rate = now;
    last_entry = now;
    rate_draws = 0U;
    rate_bytes = VizLink_GetStats()->rx_bytes;
    rate_fps = 0U;
    rate_kbps = 0U;
    rate_in = 0U;
    draw_ms = 0U;
    loop_ms = 0U;
    d_err = d_ovf = d_crc = 0U;
    {
        const VizLinkStats *stats = VizLink_GetStats();
        prev_err = stats->uart_errors;
        prev_ovf = stats->ring_overflow;
        prev_crc = stats->crc_errors;
    }
    SyncInCounter();
    DrawChrome();
    DrawFooter();
}

void VizView_Service(uint32_t now)
{
    static VizFrame frame;
    VizFrameType type;
    uint32_t started;
    int have;

    if (last_entry != 0U) loop_ms = now - last_entry;
    last_entry = now;

    UpdateRates(now);
    if ((uint32_t)(now - last_text) >= TEXT_PERIOD_MS) {
        last_text = now;
        DrawHeaderStatus();
        DrawFooter();
    }
    if ((uint32_t)(now - last_draw) < DRAW_PERIOD_MS) return;
    last_draw = now;

    if (!VizLink_LinkAlive()) {
        if (!waiting_shown) DrawWaiting();
        return;
    }
    if (waiting_shown) {
        waiting_shown = 0U;
        ClearArea();
    }

    type = ActiveType();
    have = VizLink_TakeFrame(type, &frame);

    started = HAL_GetTick();
    if (have) {
        switch (active) {
        case VIZ_VIEW_WAVE: DrawWave(&frame); break;
        case VIZ_VIEW_SPEC: DrawSpec(&frame); break;
        case VIZ_VIEW_XY:   DrawXy(&frame);   break;
        default:            DrawStat();       break;
        }
        rate_draws++;
    } else if (active == VIZ_VIEW_STAT) {
        DrawStat();
        rate_draws++;
    }
    draw_ms = HAL_GetTick() - started;
}

static void CycleGain(void)
{
    gain_index = (uint8_t)((gain_index + 1U) % 3U);
    last_clipped = 0U;
    /* DrawChrome clears the plot area and resets the per-pixel geometry, which
     * is exactly what a scale change needs. */
    DrawChrome();
    DrawFooter();
    last_draw = HAL_GetTick();
}

int VizView_Touch(uint8_t down, unsigned x, unsigned y)
{
    uint8_t inside = (uint8_t)(down && y >= BUTTON_Y && y < (BUTTON_Y + BUTTON_H));
    VizViewId wanted = active;
    uint8_t leave = 0U;
    uint8_t gain = 0U;

    if (inside && !control_down) {
        if (x >= 20U && x < 96U) {
            leave = 1U;
        } else if (x >= 100U && x < 190U) {
            wanted = VIZ_VIEW_WAVE;
        } else if (x >= 194U && x < 284U) {
            wanted = VIZ_VIEW_SPEC;
        } else if (x >= 288U && x < 378U) {
            wanted = VIZ_VIEW_XY;
        } else if (x >= 382U && x < 472U) {
            wanted = VIZ_VIEW_STAT;
        } else if (x >= 476U && x < 570U) {
            gain = 1U;
        }
    }
    control_down = inside;

    if (leave) return 1;
    if (gain) {
        CycleGain();
        return 0;
    }
    if (wanted != active) {
        active = wanted;
        SyncInCounter();
        DrawChrome();
        DrawFooter();
        last_draw = HAL_GetTick();
    }
    return 0;
}

VizViewId VizView_GetActive(void)
{
    return active;
}

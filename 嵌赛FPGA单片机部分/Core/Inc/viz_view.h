#ifndef VIZ_VIEW_H
#define VIZ_VIEW_H

/* Visualizer page: draws the WAVE / SPEC / XY / STAT frames that arrive on the
 * B board link.  Every view keeps the geometry of the previous frame and only
 * repaints the pixels that changed, so a 30 fps picture never clears the whole
 * 800x480 canvas (see docs/B板可视化_MCU接入说明.md, section 5).
 */

#include <stdint.h>

typedef enum {
    VIZ_VIEW_WAVE = 0,
    VIZ_VIEW_SPEC = 1,
    VIZ_VIEW_XY   = 2,
    VIZ_VIEW_STAT = 3
} VizViewId;

/* Called when the page is entered: static chrome, empty plot area, no geometry. */
void VizView_Enter(uint32_t now);

/* Redraws when a frame is due.  Cheap to call every main loop iteration. */
void VizView_Service(uint32_t now);

/* Touch routing for this page.  Returns 1 when the user asked to leave. */
int VizView_Touch(uint8_t down, unsigned x, unsigned y);

VizViewId VizView_GetActive(void);

#endif

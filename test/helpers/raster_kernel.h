#ifndef ABYSS_RASTER_KERNEL_H
#define ABYSS_RASTER_KERNEL_H

/*
 * Resolution-independent Abyss rasterizer.
 *
 * Each test case supplies:
 *   RASTER_WIDTH   framebuffer width
 *   RASTER_HEIGHT  framebuffer height
 *   RASTER_THREADS total number of GPU threads
 *
 * Framebuffer layout: one 32-bit word per pixel at byte address 0, in
 * row-major order, format 0x00RRGGBB.  Background is black (0).
 *
 * Triangle vertices:
 *   A = (RASTER_AX, RASTER_AY)
 *   B = (RASTER_BX, RASTER_BY)
 *   C = (RASTER_CX, RASTER_CY)
 *
 * The defaults are an obtuse scalene triangle rotated about its centroid by
 * approximately 210 degrees counter-clockwise on screen (the previous ~120
 * degree rotation plus another 90 degrees):
 *   A = (RASTER_WIDTH * 789 / 1000, RASTER_HEIGHT * 364 / 1000)
 *   B = (RASTER_WIDTH * 139 / 1000, RASTER_HEIGHT * 739 / 1000)
 *   C = (RASTER_WIDTH * 447 / 1000, RASTER_HEIGHT * 273 / 1000)
 *
 * Override any RASTER_* vertex macro in the test's .c file before including
 * this header, for example:
 *
 *   #define RASTER_AX 2
 *   #define RASTER_AY 2
 *   #define RASTER_BX 12
 *   #define RASTER_BY 3
 *   #define RASTER_CX 5
 *   #define RASTER_CY 13
 *   #include "../../helpers/raster_kernel.h"
 */

#include "abyss.h"

#ifndef RASTER_WIDTH
#error "RASTER_WIDTH must be defined"
#endif
#ifndef RASTER_HEIGHT
#error "RASTER_HEIGHT must be defined"
#endif
#ifndef RASTER_THREADS
#error "RASTER_THREADS must be defined"
#endif

#ifndef RASTER_AX
#define RASTER_AX (RASTER_WIDTH * 789 / 1000)
#endif
#ifndef RASTER_AY
#define RASTER_AY (RASTER_HEIGHT * 364 / 1000)
#endif
#ifndef RASTER_BX
#define RASTER_BX (RASTER_WIDTH * 139 / 1000)
#endif
#ifndef RASTER_BY
#define RASTER_BY (RASTER_HEIGHT * 739 / 1000)
#endif
#ifndef RASTER_CX
#define RASTER_CX (RASTER_WIDTH * 447 / 1000)
#endif
#ifndef RASTER_CY
#define RASTER_CY (RASTER_HEIGHT * 273 / 1000)
#endif

#define RASTER_CROSS                                                       \
  ((RASTER_BX - RASTER_AX) * (RASTER_CY - RASTER_AY) -                    \
   (RASTER_BY - RASTER_AY) * (RASTER_CX - RASTER_AX))
#define RASTER_ORIENT ((RASTER_CROSS) < 0 ? -1 : 1)
#define RASTER_AREA ((RASTER_CROSS) < 0 ? -(RASTER_CROSS) : (RASTER_CROSS))

_Static_assert(RASTER_AREA > 0, "raster triangle must not be degenerate");
#define RASTER_PIXELS (RASTER_WIDTH * RASTER_HEIGHT)

_Static_assert(RASTER_WIDTH >= 4, "raster width is too small");
_Static_assert(RASTER_HEIGHT >= 4, "raster height is too small");
_Static_assert(RASTER_PIXELS > 0, "raster size must be positive");
_Static_assert(RASTER_THREADS > 0 && RASTER_THREADS <= 255,
               "raster thread count must fit the 8-bit dispatch register");
_Static_assert(RASTER_THREADS % 8 == 0,
               "raster thread count must be a multiple of the 8-thread block");
_Static_assert(RASTER_PIXELS % RASTER_THREADS == 0,
               "raster threads must divide the pixel count (uniform loop)");

void kernel(void) {
  const int ax = RASTER_AX;
  const int ay = RASTER_AY;
  const int bx = RASTER_BX;
  const int by = RASTER_BY;
  const int cx = RASTER_CX;
  const int cy = RASTER_CY;
  const int area = RASTER_AREA;
  const int orient = RASTER_ORIENT;

  volatile int *fb = (volatile int *)abyss_mem(0);
  int tid = __abyss_linear_idx();

  /*
   * Keep this loop branchless.  The GPU serializes divergent threads, and a
   * store issued on a divergent path can observe stale register data.  Every
   * thread therefore writes every pixel: outside pixels get zero, inside
   * pixels get the gradient color.  Masks are -1 (all ones) or 0.
   */
  for (int p = tid; p < RASTER_PIXELS; p += RASTER_THREADS) {
    int x = p % RASTER_WIDTH;
    int y = p / RASTER_WIDTH;

    /* Edge functions: e0 = edge(A,B,P), e1 = edge(B,C,P), e2 = edge(C,A,P). */
    int e0 = orient * ((bx - ax) * (y - ay) - (by - ay) * (x - ax));
    int e1 = orient * ((cx - bx) * (y - by) - (cy - by) * (x - bx));
    int e2 = orient * ((ax - cx) * (y - cy) - (ay - cy) * (x - cx));

    /* m = min(e0, e1, e2), selected without branches. */
    int m = e0;
    int mask = (e1 - m) >> 31;
    m = (e1 & mask) | (m & ~mask);
    mask = (e2 - m) >> 31;
    m = (e2 & mask) | (m & ~mask);

    /* All three edge functions are non-negative. */
    int inside = ~((e0 | e1 | e2) >> 31);

    int t = (3 * m * 255) / area;
    t = t & ~(t >> 31); /* clamp negative weights to zero */

    /* Blue at the edges, green in the center: 0x0000GGBB. */
    fb[p] = ((t << 8) | (255 - t)) & inside;
  }
}

#endif

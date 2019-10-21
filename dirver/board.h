#ifndef BOARD_H__
#define BOARD_H__

#include <stdint.h>

#include <rthw.h>
#include "bcm283x.h"

extern unsigned char __bss_start;
extern unsigned char __bss_end;

#define RT_HW_HEAP_BEGIN    (void*)&__bss_end               // TODO check
#define RT_HW_HEAP_END      (void*)(0x0 + 4 * 1024 * 1024)  // TODO check

void rt_hw_board_init(void);

#endif
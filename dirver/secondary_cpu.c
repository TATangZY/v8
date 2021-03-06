#include <rthw.h>
#include <rtthread.h>
#include <stdint.h>

#include "board.h"

#ifdef RT_USING_SMP
#include <interrupt.h>

void rt_hw_secondary_cpu_up(void)//TODO
{
    extern void set_secondary_cpu_boot_address(void);

    set_secondary_cpu_boot_address();//in libcpu cortex-a
    __asm__ volatile ("dsb":::"memory");
    rt_hw_ipi_send(0, 1 << 1);//in libcpu cortex-a
}

//TODO
void secondary_cpu_c_start(void)
{
    rt_hw_vector_init();

    rt_hw_spin_lock(&_cpus_lock);

    arm_gic_cpu_init(0, REALVIEW_GIC_CPU_BASE);
    arm_gic_set_cpu(0, IRQ_PBA8_TIMER0_1, 0x2);

    timer_init(0, 1000);
    rt_hw_interrupt_install(IRQ_PBA8_TIMER0_1, rt_hw_timer2_isr, RT_NULL, "tick");
    rt_hw_interrupt_umask(IRQ_PBA8_TIMER0_1);

    rt_system_scheduler_start();
}

void rt_hw_secondary_cpu_idle_exec(void)
{
     asm volatile ("wfe":::"memory", "cc");
}

#endif
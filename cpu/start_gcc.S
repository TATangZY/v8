.equ Mode_USR,        0x10
.equ Mode_FIQ,        0x11
.equ Mode_IRQ,        0x12
.equ Mode_SVC,        0x13
.equ Mode_ABT,        0x17
.equ Mode_UND,        0x1B
.equ Mode_SYS,        0x1F

.equ I_Bit,           0x80            @ when I bit is set, IRQ is disabled
.equ F_Bit,           0x40            @ when F bit is set, FIQ is disabled

.equ UND_Stack_Size,     0x00000000
.equ SVC_Stack_Size,     0x00000100
.equ ABT_Stack_Size,     0x00000000
.equ RT_FIQ_STACK_PGSZ,  0x00000000
.equ RT_IRQ_STACK_PGSZ,  0x00000100
.equ USR_Stack_Size,     0x00000100

#define ISR_Stack_Size  (UND_Stack_Size + SVC_Stack_Size + ABT_Stack_Size + RT_FIQ_STACK_PGSZ + RT_IRQ_STACK_PGSZ)

.section .data.share.isr
/* stack */
.globl stack_start
.globl stack_top

stack_start:
.rept ISR_Stack_Size
.byte 0
.endr
stack_top:

.text

.globl _reset
_reser:
	/* Disable IRQ & FIQ */
	cpsid if

    /* Check main core */
    mrc p15, 0, r0, c0, c0, 5 /* read cpu mpidr */
    add r0, r0, #0xff       /* TODO check */
    cmp r0, #0
    bne other_core
    b check_hyp

other_core: /* if is not main core */
    bl secondary_cpu_start          /* libcpu cortex-a */
    b  .

check_hyp:  /* Check for HYP mode */
	mrs r0, cpsr_all
	and r0, r0, #0x1F    // [4:0] of cpsr is mode field
	mov r8, #0x1A       // cpsr_m_hyp == 0x1a
	cmp r0, r8
	beq overHyped
	b continue

overHyped: /* Get out of HYP mode */
	ldr r1, =continue
	msr ELR_hyp, r1     // ELR_hyp: exception link register(hyp mode)
	mrs r1, cpsr_all
	and r1, r1, #0x1f	;@ CPSR_MODE_MASK
	orr r1, r1, #0x13	;@ CPSR_MODE_SUPERVISOR
	msr SPSR_hyp, r1
	eret                // 在 Hyp模式下执行的时候，Spsr_hyp的内容赋给CPSR而ELR_Hyp的值赋给PC

continue:
    /* enable smp */
    bl arm_smp_enable

    /* init and enable mmu and caches */
    bl clean_invalidate_l1_dcache
    bl clean_invalidate_l2_dcache
    bl set_up_mmu //TODO
    bl rt_hw_mmu_enable //enable caches and mmu

    /* set the cpu to SVC32 mode and disable interrupt */
    mrs     r0, cpsr
    bic     r0, r0, #0x1f
    orr     r0, r0, #0x13
    msr     cpsr_c, r0      // cpsr_c is [7:0] of cpsr
                            // 只切换到了 svc，没有 disable interrupt？

    bl stacks_setup     //TODO CHECK

    /* clear .bss */
    mov     r0,#0                   /* get a zero                       */
    ldr     r1,=__bss_start         /* bss start                        */
    ldr     r2,=__bss_end           /* bss end                          */

bss_loop:
    cmp     r1,r2                   /* check if data to clear           */
    strlo   r0,[r1],#4              /* clear 4 bytes                    */
    blo     bss_loop                /* loop until done                  */

    /* start RT-Thread Kernel */
    ldr     pc, _rtthread_startup
_rtthread_startup:
    .word rtthread_startup          /* start secondary core in this process */

stacks_setup:
    ldr     r0, =stack_top

    @  Set the startup stack for svc
    mov     sp, r0
	sub     r0, r0, #SVC_Stack_Size

    @  Enter Undefined Instruction Mode and set its Stack Pointer
    cps     #Mode_UND
    mov     sp, r0
    sub     r0, r0, #UND_Stack_Size

    @  Enter Abort Mode and set its Stack Pointer
    cps     #Mode_ABT
    mov     sp, r0
    sub     r0, r0, #ABT_Stack_Size

    @  Enter FIQ Mode and set its Stack Pointer
    cps     #Mode_FIQ
    mov     sp, r0
    sub     r0, r0, #RT_FIQ_STACK_PGSZ

    @  Enter IRQ Mode and set its Stack Pointer
    cps     #Mode_IRQ
    mov     sp, r0
    sub     r0, r0, #RT_IRQ_STACK_PGSZ

    /* come back to SVC mode */
    cps     #Mode_SVC
    bx      lr

.text
.globl arm_smp_enable
arm_smp_enable:
    mrc p15, 1, r0, r1, c15
    orr r0, r0, #(0x1 << 6)
    mcr p15, 0, r0, c15
    bx lr

.globl arm_smp_disable
arm_smp_disable:
    mrc p15, 1, r0, r1, c15
    bic r0, r0, #(0x1 << 6)
    mcr p15, 0, r0, c15
    bx lr

.globl rt_hw_mmu_enable
rt_hw_mmu_enable:
    mrc p15, 0, r0, c1, c0, 0   //read sctlr
    orr r0, r0, #(0x1 << 2)     //the C bit (data cache)
    orr r0, r0, #(0x1 << 12)    //the I bit (instruction cache)
    orr r0, r0, #0x1            //the M bit (MMU)
    mcr p15, 0, r0, c1, c0, 0   //write sctlr
    dsb
    bx lr

.globl clean_invalidate_l1_dcache
clean_invalidate_l1_dcache:
    mrc p15, 0, r1, c1, c0, 0   //read sctlr(system control register)
    bic r1, r1, #(0x1 << 2)     //disable data cache
    mcr p15, 0, r1, c1, c0, 0   //write

    mov r0, #0x0                // R0 = 0x0 for L1 dcache 0x2 for L2 dcache.
    mcr p15, 2, r0, c0, c0, 0   // CSSELR Cache Size Selection Register.
    mrc p15, 1, r4, c0, c0, 0   // CCSIDR read Cache Size.
    and r1, r4, #0x7
    add r1, r1, #0x4            // R1 = Cache Line Size.
    ldr r3, =0x7FFF
    and r2, r3, r4, lsr #13     // R2 = Cache Set Number – 1.
    ldr r3, =0x3FF
    and r3, r3, r4, lsr #3      // R3 = Cache Associativity Number – 1.
    clz r4, r3                  // R4 = way position in CISW instruction.
    mov r5, #0                  // R5 = way loop counter.
    way_loop:
    mov r6, #0                  // R6 = set loop counter.
    set_loop:
    orr r7, r0, r5, lsl r4      // Set way.
    orr r7, r7, r6, lsl r1      // Set set.
    mcr p15, 0, r7, c7, c6, 2   // DCCISW R7.
    add r6, r6, #1              // Increment set counter.
    cmp r6, r2                  // Last set reached yet?
    ble set_loop                // If not, iterate set_loop,
    add R5, R5, #1              // else, next way.
    cmp R5, R3                  // Last way reached yet?
    ble way_loop                // if not, iterate way_loop.
    bx lr

.globl clean_invalidate_l2_dcache
clean_invalidate_l2_dcache:
    mrc p15, 0, r1, c1, c0, 0   //read sctlr(system control register)
    bic r1, r1, #(0x1 << 2)     //disable data cache
    mcr p15, 0, r1, c1, c0, 0   //write

    mov r0, #0x2                // R0 = 0x0 for L1 dcache 0x2 for L2 dcache.
    mcr p15, 2, r0, c0, c0, 0   // CSSELR Cache Size Selection Register.
    mrc p15, 1, r4, c0, c0, 0   // CCSIDR read Cache Size.
    and r1, r4, #0x7
    add r1, r1, #0x4            // R1 = Cache Line Size.
    ldr r3, =0x7FFF
    and r2, r3, r4, lsr #13     // R2 = Cache Set Number – 1.
    ldr r3, =0x3FF
    and r3, r3, r4, lsr #3      // R3 = Cache Associativity Number – 1.
    clz r4, r3                  // R4 = way position in CISW instruction.
    mov r5, #0                  // R5 = way loop counter.
    way_loop:
    mov r6, #0                  // R6 = set loop counter.
    set_loop:
    orr r7, r0, r5, lsl r4      // Set way.
    orr r7, r7, r6, lsl r1      // Set set.
    mcr p15, 0, r7, c7, c6, 2   // DCCISW R7.
    add r6, r6, #1              // Increment set counter.
    cmp r6, r2                  // Last set reached yet?
    ble set_loop                // If not, iterate set_loop,
    add R5, R5, #1              // else, next way.
    cmp R5, R3                  // Last way reached yet?
    ble way_loop                // if not, iterate way_loop.
    bx lr

/* exception handlers: undef, swi, padt, dabt, resv, irq, fiq          */
.section .text.isr, "ax"
    .align  5
.globl vector_fiq
vector_fiq:
    stmfd   sp!,{r0-r7,lr}
    bl      rt_hw_trap_fiq
    ldmfd   sp!,{r0-r7,lr}
    subs    pc, lr, #4

.globl      rt_interrupt_enter
.globl      rt_interrupt_leave
.globl      rt_thread_switch_interrupt_flag
.globl      rt_interrupt_from_thread
.globl      rt_interrupt_to_thread

.globl      rt_current_thread
.globl      vmm_thread
.globl      vmm_virq_check

    .align  5
.globl vector_irq
vector_irq:
    stmfd   sp!, {r0-r12,lr}

    bl      rt_interrupt_enter
    bl      rt_hw_trap_irq
    bl      rt_interrupt_leave

    @ if rt_thread_switch_interrupt_flag set, jump to
    @ rt_hw_context_switch_interrupt_do and don't return
    ldr     r0, =rt_thread_switch_interrupt_flag
    ldr     r1, [r0]
    cmp     r1, #1
    beq     rt_hw_context_switch_interrupt_do

    ldmfd   sp!, {r0-r12,lr}
    subs    pc,  lr, #4

rt_hw_context_switch_interrupt_do:
    mov     r1,  #0         @ clear flag
    str     r1,  [r0]

    mov     r1, sp          @ r1 point to {r0-r3} in stack
    add     sp, sp, #4*4
    ldmfd   sp!, {r4-r12,lr}@ reload saved registers
    mrs     r0,  spsr       @ get cpsr of interrupt thread
    sub     r2,  lr, #4     @ save old task's pc to r2

    @ Switch to SVC mode with no interrupt. If the usr mode guest is
    @ interrupted, this will just switch to the stack of kernel space.
    @ save the registers in kernel space won't trigger data abort.
    msr     cpsr_c, #I_Bit|F_Bit|Mode_SVC

    stmfd   sp!, {r2}       @ push old task's pc
    stmfd   sp!, {r4-r12,lr}@ push old task's lr,r12-r4
    ldmfd   r1,  {r1-r4}    @ restore r0-r3 of the interrupt thread
    stmfd   sp!, {r1-r4}    @ push old task's r0-r3
    stmfd   sp!, {r0}       @ push old task's cpsr

    ldr     r4,  =rt_interrupt_from_thread
    ldr     r5,  [r4]
    str     sp,  [r5]       @ store sp in preempted tasks's TCB

    ldr     r6,  =rt_interrupt_to_thread
    ldr     r6,  [r6]
    ldr     sp,  [r6]       @ get new task's stack pointer

    ldmfd   sp!, {r4}       @ pop new task's cpsr to spsr
    msr     spsr_cxsf, r4

    ldmfd   sp!, {r0-r12,lr,pc}^ @ pop new task's r0-r12,lr & pc, copy spsr to cpsr

.macro push_svc_reg
    sub     sp, sp, #17 * 4         @/* Sizeof(struct rt_hw_exp_stack)  */
    stmia   sp, {r0 - r12}          @/* Calling r0-r12                  */
    mov     r0, sp
    mrs     r6, spsr                @/* Save CPSR                       */
    str     lr, [r0, #15*4]         @/* Push PC                         */
    str     r6, [r0, #16*4]         @/* Push CPSR                       */
    cps     #Mode_SVC
    str     sp, [r0, #13*4]         @/* Save calling SP                 */
    str     lr, [r0, #14*4]         @/* Save calling PC                 */
.endm

    .align  5
    .globl  vector_swi
vector_swi:
    push_svc_reg
    bl      rt_hw_trap_swi
    b       .

    .align  5
    .globl  vector_undef
vector_undef:
    push_svc_reg
    bl      rt_hw_trap_undef
    b       .

    .align  5
    .globl  vector_pabt
vector_pabt:
    push_svc_reg
    bl      rt_hw_trap_pabt
    b       .

    .align  5
    .globl  vector_dabt
vector_dabt:
    push_svc_reg
    bl      rt_hw_trap_dabt
    b       .

    .align  5
    .globl  vector_resv
vector_resv:
    push_svc_reg
    bl      rt_hw_trap_resv
    b       .

set_up_mmu:
    // Initialize TTBCR.
    mov r0, #0                  // Use short descriptor.
    mcr p15, 0, r0, c2, c0, 2   // Base address is 16KB aligned.
    // Perform translation table walk for TTBR0.
    // Initialize DACR.
    ldr r1, =0x55555555         // Set all domains as clients.
    mcr p15, 0, r1, c3, c0, 0   // Accesses are checked against the
    // permission bits in the translation tables.
    // Initialize SCTLR.AFE.
    mrc p15, 0, r1, c1, c0, 0   // Read SCTLR.
    bic R1, R1, #(0x1 <<29)     // Set AFE to 0 and disable Access Flag.
    mcr p15, 0, r1, c1, c0, 0   // Write SCTLR.
    // Initialize TTBR0.
    ldr r0, =ttb0_base          // ttb0_base must be a 16KB-aligned address.
    mov r1, #0x2B               // The translation table walk is normal, inner
    orr r1, r0, r1              // and outer cacheable, WB WA, and inner
    mcr p15, 0, r1, c2, c0, 0   // shareable.
    // Set up translation table entries in memory
    ldr r4, =0x00100000         // Increase 1MB address each time.
    ldr r2, =0x00015C06         // Set up translation table descriptor with
    // Secure, global, full accessibility,
    // executable.
    // Domain 0, Shareable, Normal cacheable memory
    ldr r3, =1024               // executes the loop 1024 times to set up
    // 1024 descriptors to cover 0-1GB memory.
    loop:
    str r2, [r0], #4            // Build a page table section entry.
    add r2, r2, r4              // Update address part for next descriptor.
    subs r3, #1
    bne loop
    ldr r2, =0x40010C02         // Set up translation table descriptors with
    // secure, global, full accessibility,
    // Domain=0 Shareable Device-nGnRnE Memory.
    ldr r3, =3072               // Executes loop 3072 times to set up 3072

    // descriptors to cover 1-4GB memory.
    loop2:
    str r2, [r0], #4            // Build a translation table section entry.
    add r2, r2, r4              // Update address part for next descriptor.
    subs r3, #1
    bne loop2
    
    bx lr


.global set_secondary_cpu_boot_address
set_secondary_cpu_boot_address:
    ldr r0, =secondary_cpu_start

    mvn r1, #0 //0xffffffff
    ldr r2, =0x10000034     // TODO check address
    str r1, [r2]
    str r0, [r2, #-4]
    bx lr

.global secondary_cpu_start
secondary_cpu_start:

#ifdef RT_USING_FPU
    mov r4, #0xfffffff
    mcr p15, 0, r4, c1, c0, 2
#endif

    bl arm_smp_enable

    mrc p15, 0, r0, c1, c0, 0   // set sctlr.v to 0
    bic r0, #(1<<13)            // which means that the location of the reset vector is 0x0
    mcr p15, 0, r0, c1, c0, 0   // TODO why?

// TODO check
// TODO stack init ? How?
#ifdef RT_USING_FPU
    cps #Mode_UND
    ldr sp, =und_stack_2_limit
#endif

    cps #Mode_IRQ
    ldr sp, =irq_stack_2_limit

    cps #Mode_FIQ
    ldr sp, =irq_stack_2_limit

    cps #Mode_SVC
    ldr sp, =svc_stack_2_limit

    /* init and enable mmu and caches */
    bl clean_invalidate_l1_dcache
    bl clean_invalidate_l2_dcache
    bl set_up_mmu
    bl rt_hw_mmu_enable     //enable caches and mmu

    b secondary_cpu_c_start
#endif


// TODO check
.bss
.align 2   //align to  2~2=4
svc_stack_2:
    .space (1 << 10)
svc_stack_2_limit:

irq_stack_2:
    .space (1 << 10)
irq_stack_2_limit:

#ifdef RT_USING_FPU
und_stack_2:
    .space (1 << 10)
und_stack_2_limit:
#endif
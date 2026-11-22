.text
.code64

.macro SAVE_REGS
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    cld
.endm

.macro RESTORE_REGS
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax
.endm

.macro IRQ_STUB name, handler
    .global \name
    .type \name,@function
\name:
    SAVE_REGS
    movq %rsp, %rax
    andq $-16, %rsp
    subq $16, %rsp
    movq %rax, 8(%rsp)
    call \handler
    movq 8(%rsp), %rsp
    RESTORE_REGS
    iretq
.endm

IRQ_STUB aether_irq0_stub, aether_irq_timer
IRQ_STUB aether_irq1_stub, aether_irq_keyboard
IRQ_STUB aether_irq12_stub, aether_irq_mouse

.global aether_load_gdt
.type aether_load_gdt,@function
aether_load_gdt:
    lgdt (%rdi)
    pushq $0x08
    leaq 1f(%rip), %rax
    pushq %rax
    lretq
1:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x28, %ax
    ltr %ax
    ret

.global aether_enter_user
.type aether_enter_user,@function
aether_enter_user:
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, aether_user_kernel_rsp(%rip)
    pushq $0x1b
    pushq %rsi
    pushfq
    popq %rax
    andq $-12289, %rax
    orq $0x200, %rax
    cld
    pushq %rax
    pushq $0x23
    pushq %rdi
    iretq

.global aether_syscall_stub
.type aether_syscall_stub,@function
aether_syscall_stub:
    SAVE_REGS
    movq %rsp, %rdi
    andq $-16, %rsp
    subq $16, %rsp
    call aether_syscall_dispatch
    jmp aether_user_return

.global aether_user_return
.type aether_user_return,@function
aether_user_return:
    testq %rax, %rax
    jz 2f
    movq %rax, %rsp
    RESTORE_REGS
    iretq
2:
    movq aether_user_kernel_rsp(%rip), %rsp
    movq $0, aether_user_kernel_rsp(%rip)
    testq %rsp, %rsp
    jz 3f
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    ret
3:
    cli
4:
    hlt
    jmp 4b

.macro EXCEPTION_NOERR vector
    .global aether_exception_\vector\()_stub
    .type aether_exception_\vector\()_stub,@function
aether_exception_\vector\()_stub:
    pushq $0
    pushq $\vector
    jmp aether_exception_common
.endm

.macro EXCEPTION_ERR vector
    .global aether_exception_\vector\()_stub
    .type aether_exception_\vector\()_stub,@function
aether_exception_\vector\()_stub:
    pushq $\vector
    jmp aether_exception_common
.endm

EXCEPTION_NOERR 0
EXCEPTION_NOERR 1
EXCEPTION_NOERR 2
EXCEPTION_NOERR 3
EXCEPTION_NOERR 4
EXCEPTION_NOERR 5
EXCEPTION_NOERR 6
EXCEPTION_NOERR 7
EXCEPTION_ERR 8
EXCEPTION_NOERR 9
EXCEPTION_ERR 10
EXCEPTION_ERR 11
EXCEPTION_ERR 12
EXCEPTION_ERR 13
EXCEPTION_ERR 14
EXCEPTION_NOERR 15
EXCEPTION_NOERR 16
EXCEPTION_ERR 17
EXCEPTION_NOERR 18
EXCEPTION_NOERR 19
EXCEPTION_NOERR 20
EXCEPTION_ERR 21
EXCEPTION_NOERR 22
EXCEPTION_NOERR 23
EXCEPTION_NOERR 24
EXCEPTION_NOERR 25
EXCEPTION_NOERR 26
EXCEPTION_NOERR 27
EXCEPTION_NOERR 28
EXCEPTION_ERR 29
EXCEPTION_ERR 30
EXCEPTION_NOERR 31

.global aether_exception_common
.type aether_exception_common,@function
aether_exception_common:
    SAVE_REGS
    movq %rsp, %rax
    testb $3, 144(%rax)
    jnz aether_user_exception_common
    andq $-16, %rsp
    subq $16, %rsp
    movq %rax, 8(%rsp)
    movq 120(%rax), %rdi  /* vector */
    movq 128(%rax), %rsi  /* error code */
    movq 136(%rax), %rdx  /* instruction pointer */
    movq 144(%rax), %rcx  /* code segment */
    movq 152(%rax), %r8   /* flags */
    movq %cr2, %r9
    call aether_exception
    cli
2:
    hlt
    jmp 2b

.global aether_user_exception_common
.type aether_user_exception_common,@function
aether_user_exception_common:
    movq 120(%rax), %rdi  /* vector */
    movq 128(%rax), %rsi  /* error code */
    movq 136(%rax), %rdx  /* instruction pointer */
    movq 144(%rax), %rcx  /* code segment */
    movq 152(%rax), %r8   /* flags */
    movq %cr2, %r9
    andq $-16, %rsp
    subq $16, %rsp
    call aether_user_exception
    jmp aether_user_return

.global aether_unhandled_stub
.type aether_unhandled_stub,@function
aether_unhandled_stub:
    cli
1:
    hlt
    jmp 1b

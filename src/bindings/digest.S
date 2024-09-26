# This file is taken from http://locklessinc.com/articles/tcp_checksum/

.globl asm_digest_32_le
.type asm_digest_32_le,@function
.align 16
asm_digest_32_le:
	xor %eax, %eax
	test $7, %edi
	jne 5f
0:	mov %esi, %edx
	mov %esi, %ecx
	shr $3, %edx
	je 2f
	shr $6, %ecx
	and $7, %edx
	# A multiple of 64 means we do full executions of the loop
	je 1f
	add $1, %ecx
	# We need to adjust the pointer, because we have a partial loop
	lea -64(%rdi,%rdx,8), %rdi
	# Compute the jump point
	neg %edx
	and $7, %edx
	lea 1f-1(,%rdx,4), %rdx
	jmp *%rdx

.align 16	
1:	adc (%rdi), %rax
	adc 8(%rdi), %rax
	adc 16(%rdi), %rax
	adc 24(%rdi), %rax
	adc 32(%rdi), %rax
	adc 40(%rdi), %rax
	adc 48(%rdi), %rax
	adc 56(%rdi), %rax
	lea 64(%rdi), %rdi
	dec %ecx
	jne 1b
	
	adc $0, %rax
2:	and $7, %esi
	jne  4f # Some odd bytes to do
	
	# Fold down to 16 bits
3:	mov %eax, %edx
	shr $32, %rax
	add %edx, %eax
	adc $0, %eax
	mov %eax, %edx
	shr $16, %eax
	add %dx, %ax
	adc $0, %ax

	not %ax
	retq

	# Add in last bytes
4:	lea (,%esi,8),%ecx
	mov $-1, %rdx
	neg %ecx
	shr %cl, %rdx
	and (%rdi), %rdx
	add %rdx, %rax
	adc $0, %rax
	jmp 3b

5:	test $1, %edi
	jne 9f # Odd-aligned is annoying
	
	mov %edi, %ecx
	neg %ecx
	and $0x7, %ecx
	
	cmp %ecx, %esi
	cmovl %esi, %ecx  # Work to do is min(size, alignment)
	sub %ecx, %esi
		
	test $4, %ecx
	je  6f
	movl (%rdi), %edx
	add %rdx, %rax
	adc $0, %rax
	add $4, %rdi

6:	test $2, %ecx
	je 7f
	movzwq (%rdi), %rdx
	add %rdx, %rax
	adc $0, %rax
	add $2, %rdi

7:	test $1, %ecx
	je 8f
	movzbq (%rdi), %rdx
	add %rdx, %rax
	adc $0, %rax
	add $1, %rdi

8:	test %esi, %esi # Nothing left to do?
	je 3b
	
	# Continue with the rest
	jmp 0b

9:	movzbw (%rdi), %r8w
	inc %rdi
	dec %esi
	je 10f # Only one byte to do?
	call asm_digest_32_le
	not %ax
	xchg %al, %ah
	add %r8w, %ax
	adc $0, %ax
	not %ax
	retq

10:	mov %r8w, %ax
	not %ax
	retq
.size asm_digest_32_le, .-asm_digest_32_le

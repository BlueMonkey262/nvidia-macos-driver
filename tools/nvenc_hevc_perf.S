# Reference GNU-as source for the hex caves in make_nvenc_hevc_t2d.py.
# Assemble with as --64, link with ld -Ttext=0 --entry=0, then objcopy -O binary.
.intel_syntax noprefix
.text
# The sw_t2d helper only clobbers eax/ecx/edx/esi/edi. Match that contract.
.macro tile_math
 mov eax, edi
 and eax, 0x20
 shl eax, 3
 mov edx, edi
 and edx, 0x10
 shl edx, 2
 add eax, edx
 and edi, 15
 add eax, edi
 mov edx, esi
 and edx, 4
 shl edx, 5
 or eax, edx
 shl esi, 4
 and esi, 0x30
 or eax, esi
.endm
.org 0xc160
luma_inline:
 lea rax, [rip + sw_t2d]
 cmp QWORD PTR [r12+0x48], rax
 jne luma_fallback
 tile_math
 jmp 0x8a26
luma_fallback:
 call QWORD PTR [r12+0x48]
 jmp 0x8a26
luma_inline_end:
.org 0xc200
chroma_inline:
 lea rax, [rip + sw_t2d]
 cmp QWORD PTR [r13+0x50], rax
 jne chroma_fallback
 tile_math
 jmp chroma_inline_done
chroma_fallback:
 call QWORD PTR [r13+0x50]
chroma_inline_done:
 add eax, r14d
 jmp 0x8bee
chroma_inline_end:
.org 0xc2a0
luma_direct:
 cmp r13d, 1
 jne luma_copy
 cmp ebx, DWORD PTR [rbp-0x1b8]
 jne luma_copy
 mov r15, r12
 jmp 0x8943
luma_copy:
 call 0xac12
 jmp 0x8943
luma_direct_end:
.org 0xc2e0
luma_restore:
 mov r15, QWORD PTR [rbp-0x218]
 mov r8, QWORD PTR [rbp-0x1e0]
 jmp 0x88e7
luma_restore_end:
.org 0xc320
chroma_direct:
 cmp r13d, 1
 jne chroma_copy
 cmp ebx, r14d
 jne chroma_copy
 mov r12, r15
 jmp 0x8af4
chroma_copy:
 call 0xac12
 jmp 0x8af4
chroma_direct_end:
.set sw_t2d, 0x57d0

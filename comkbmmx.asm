; (C) 2026 By Dimitri Grinkevich
; теперь, бля, йасна вам, зачем нужны не только ключи оптимизации у компиляторов, но и директива таргет=

.model tiny
.586                ; Базовые инструкции Pentium
.mmx                ; Разрешаем инструкции MMX
.code
org 100h

Start:
    jmp Init

; ===========================================================================
; ДАННЫЕ РЕЗИДЕНТА (Кэш-линия P55C = 32 байта)
; ===========================================================================
            ALIGN 32
BufHead     dd 0            
BufTail     dd 0            
OldInt1C    dd 0
OldInt28    dd 0

            ALIGN 32
OldInt2F    dd 0
OldCOM      dd 0
ComBase     dw 03F8h
Busy        db 0
Flag_ComFull  db 0
Flag_BiosFull db 0

            ALIGN 32
; Буфер для сохранения состояния FPU/MMX (108 байт). Выровнен жестко!
FpuState    db 108 dup(0)

            ALIGN 32
; MMX Маска: 0x0F0F (выделение двух нибблов из 16-битного слова)
MmxMask0F   dq 0000000000000F0Fh 

            ALIGN 32
AsciiTable  db '0123456789ABCDEF'
            ALIGN 32
ScanTable   db 0Bh, 02h, 03h, 04h, 05h, 06h, 07h, 08h, 09h, 0Ah, 1Eh, 30h, 2Eh, 20h, 12h, 21h
            ALIGN 32
CapsTable   db 0,0,0,0,0,0,0,0,0,0, 1,1,1,1,1,1

TSR_ID      equ 0E1h
BUF_SIZE    equ 2048
BUF_MASK    equ 000007FFh


; ===========================================================================
; АППАРАТНЫЙ ОБРАБОТЧИК UART (Остается целочисленным!)
; В ISR нельзя использовать MMX, так как FSAVE занимает >100 тактов. 
; Оставляем идеальное U/V спаривание из версии P5.
; ===========================================================================
            ALIGN 32
ComISR proc far
    push eax            ; [U]
    push ebx            ; [V]
    push edx            ; [U]
    push edi            ; [V]

    mov dx, cs:[ComBase]; [U]
    add dx, 5           ; [U]

            ALIGN 16    
ReadLoop:
    in al, dx           
    test al, 1          ; [U]
    jz EndISR           ; [V]

    sub dx, 5           ; [U]
    in al, dx           
    add dx, 5           ; [U]

    mov ebx, cs:[BufTail]  ; [U]
    mov edi, ebx           ; [V]
    inc edi                ; [U]
    
    cmp edi, cs:[BufHead]  ; [V] Спариваем и обходим AGI
    
    and edi, BUF_MASK      ; [U] 
    sete cs:[Flag_ComFull] ; [V] 
    je ReadLoop            ; [U] 

    mov cs:[IntBuf + ebx], al 
    mov cs:[BufTail], edi     
    jmp ReadLoop

            ALIGN 16
EndISR:
    mov al, 20h         ; [U]
    out 20h, al         

    pop edi             ; [U]
    pop edx             ; [V]
    pop ebx             ; [U]
    pop eax             ; [V]
    iret
ComISR endp


; ===========================================================================
; ОБРАБОТЧИКИ DOS
; ===========================================================================
            ALIGN 16
Int1CHandler proc far
    call ProcessRingBuffer  ; RSB: CALL парный к RET внутри процедуры
    jmp cs:[OldInt1C]
Int1CHandler endp

            ALIGN 16
Int28Handler proc far
    call ProcessRingBuffer
    jmp cs:[OldInt28]
Int28Handler endp

            ALIGN 16
Int2FHandler proc far
    cmp ah, TSR_ID      
    jne Chain2F         
    test al, al         
    jne Chain2F         
    mov al, 0FFh        
    iret
Chain2F:
    jmp cs:[OldInt2F]
Int2FHandler endp


; ===========================================================================
; ЯДРО: ВЕКТОРНАЯ РАСПАКОВКА И ИНЪЕКЦИЯ (MMX MAGIC)
; ===========================================================================
            ALIGN 32
ProcessRingBuffer proc near
    cmp cs:[Busy], 1
    je PRB_Exit
    mov cs:[Busy], 1

    push fs
    mov ax, 0040h
    mov fs, ax

    mov ebx, cs:[BufHead]
    cmp ebx, cs:[BufTail]
    je PRB_Cleanup_NoMMX

    sti

    ; --- [CRITICAL MMX CONTEXT SAVE] ---
    ; Сохраняем состояние FPU прерванной программы в память (108 байт).
    fsave cs:[FpuState]
    ; Загружаем маску 0F0F в регистр MM7 (будет лежать там весь цикл)
    movq mm7, cs:[MmxMask0F] 

            ALIGN 16
PRB_Loop:
    mov ebx, cs:[BufHead]
    cmp ebx, cs:[BufTail]
    je PRB_Done

    ; Читаем байт из буфера (например, AL = 0xAB)
    movzx eax, byte ptr cs:[IntBuf + ebx] 
    inc ebx
    and ebx, BUF_MASK
    mov cs:[BufHead], ebx

    ; ===================================================================
    ; [MMX UNPACKING ALGORITHM]
    ; Задача: Превратить 0xAB в AH=0x0A, AL=0x0B без ветвлений и сдвигов в GPR
    ; ===================================================================
    movd mm0, eax        ; MM0 = 0000 0000 0000 00AB  [U]
    movq mm1, mm0        ; MM1 = 0000 0000 0000 00AB  [V]
    psrlw mm1, 4         ; MM1 = 0000 0000 0000 000A  [U] Сдвиг вправо на 4 бита
    
    ; Магия распаковки нижних байт (Interleave low bytes)
    ; MM0 (Dest) младший байт = AB
    ; MM1 (Src)  младший байт = 0A
    ; Результат PUNPCKLBW: 0A AB (склеивает байты в слово)
    punpcklbw mm0, mm1   ; MM0 = 0000 0000 0000 0AAB  [U]
    
    ; Накладываем маску 0x0F0F
    pand mm0, mm7        ; MM0 = 0000 0000 0000 0A0B  [U/V]
    
    ; Выгружаем обратно в GPR.
    ; Теперь у нас идеально: AH = 0x0A (High Nibble), AL = 0x0B (Low Nibble)
    movd eax, mm0        ; EAX = 00000A0B (AH=0A, AL=0B)
    ; ===================================================================

    ; Сохраняем младший ниббл в стек, обрабатываем старший (AH)
    push eax             ; [U] Сохранили AL на потом
    mov al, ah           ; [V] AL = Старший ниббл
    call ProcessNibble   ; [U] Инъекция (вызов через RSB)

    ; Восстанавливаем и обрабатываем младший ниббл (бывший AL)
    pop eax              ; [U]
    ; AL уже содержит младший ниббл!
    call ProcessNibble   ; [U]

    jmp PRB_Loop

            ALIGN 16
PRB_Done:
    ; --- [CRITICAL MMX CONTEXT RESTORE] ---
    ; Очищаем теги MMX (возвращаем регистры FPU в свободное состояние).
    ; БЕЗ ЭТОЙ КОМАНДЫ ПРЕРВАННАЯ ПРОГРАММА ВЫЛЕТИТ С FPU EXCEPTION!
    emms
    ; Восстанавливаем состояние FPU
    frstor cs:[FpuState]

    ; Проверка алертов
    cmp cs:[Flag_ComFull], 1
    jne CheckBios
    mov cs:[Flag_ComFull], 0
    mov eax, 200        
    mov ecx, 300000     
    call PlaySound      

            ALIGN 16
CheckBios:
    cmp cs:[Flag_BiosFull], 1
    jne PRB_Cleanup_NoMMX
    mov cs:[Flag_BiosFull], 0
    mov eax, 9000       
    mov ecx, 400000     
    call PlaySound

PRB_Cleanup_NoMMX:
    pop fs              
    mov cs:[Busy], 0
PRB_Exit:
    ret
ProcessRingBuffer endp


; ===========================================================================
; ИНЪЕКЦИЯ НИББЛА (Оптимизировано под RSB и U/V спаривание)
; Вход: AL = Ниббл (0..15)
; ===========================================================================
            ALIGN 32
ProcessNibble proc near
    movzx ebx, al       ; [U] Мгновенное расширение для индекса

    mov cl, cs:[AsciiTable + ebx]  ; [U]
    mov ch, cs:[ScanTable + ebx]   ; [V]
    mov al, cs:[CapsTable + ebx]   ; [U]
    
    mov dh, fs:[0017h]             ; [V] 
    mov ah, dh                     ; [U] 
    shr ah, 6                      ; [V] 
    and ah, 1                      ; [U] 

    cmp al, ah                     ; [V] 
    je InjectChar                  ; [U] 

    xor dh, 040h                   ; [U] 
    mov fs:[0017h], dh             ; [V] 
    
    push eax            
    push ecx            
    push edx            
    mov eax, 3000       
    mov ecx, 15000      
    call PlaySound
    pop edx             
    pop ecx             
    pop eax             

    ; Вызов UpdateLEDs
    call UpdateLEDs     

            ALIGN 16
InjectChar:
    mov ax, 4F00h
    mov al, ch
    stc
    int 15h
    jc SkipInject

    mov ch, al
    
    cli                 

    mov bx, fs:[001Ch]  
    mov dx, bx          ; [U]
    add dx, 2           ; [V]

    ; Branchless математика
    cmp dx, 003Eh       ; [U]
    setae al            ; [V]
    movzx eax, al       ; [U]
    shl eax, 5          ; [V]
    sub dx, ax          ; [U] 
    
    cmp dx, fs:[001Ah]  
    je  BiosOverrun     

    mov fs:[bx], cx     
    mov fs:[001Ch], dx  
    sti

    push eax            
    push ecx            
    mov eax, 1000       
    mov ecx, 2000       
    call PlaySound
    pop ecx             
    pop eax             
    ret

            ALIGN 16
BiosOverrun:
    sti
    mov cs:[Flag_BiosFull], 1 
SkipInject:
    ret
ProcessNibble endp


; ===========================================================================
; ЗВУКОВОЙ ДВИЖОК 
; ===========================================================================
            ALIGN 16
PlaySound proc near
    push eax
    push ebx
    in al, 61h
    or al, 03h
    out 61h, al
    mov al, 0B6h        
    out 43h, al
    mov ax, bx          
    out 42h, al         
    mov al, ah
    out 42h, al         
            ALIGN 16
WaitMicroseconds:
    in al, 80h          
    dec ecx             ; [U] Спаривается!
    jnz WaitMicroseconds; [V]
    in al, 61h
    and al, 0FCh        
    out 61h, al
    pop ebx
    pop eax
    ret
PlaySound endp


; ===========================================================================
; СВЕТОДИОДЫ
; ===========================================================================
            ALIGN 16
UpdateLEDs proc near
    push eax
    push ecx
    mov al, fs:[0017h]
    shr al, 4           
    and al, 07h         
    mov ah, al
    call WaitKbd
    jc EndLED
    mov al, 0EDh        
    out 60h, al
    call WaitKbd
    jc EndLED
    mov al, ah          
    out 60h, al
            ALIGN 16
EndLED:
    pop ecx
    pop eax
    ret
UpdateLEDs endp

            ALIGN 16
WaitKbd proc near
    mov cx, 0FFFFh
            ALIGN 16    
WaitLoop:
    in al, 64h
    test al, 02h        
    jz WaitDone
    dec cx              
    jnz WaitLoop
    stc
    ret
            ALIGN 16
WaitDone:
    clc
    ret
WaitKbd endp


ResidentEnd label byte
IntBuf equ offset ResidentEnd


; ===========================================================================
; ИНИЦИАЛИЗАЦИЯ И ДЕТЕКЦИЯ CPUID / MMX
; ===========================================================================
            ALIGN 32
Init:
    ; 0. ПРОВЕРКА НАЛИЧИЯ CPUID И MMX (Обязательный шаг для P55C кода!)
    ; Проверяем, можно ли изменить 21-й бит регистра EFLAGS (ID Flag)
    pushfd
    pop eax
    mov ecx, eax
    xor eax, 00200000h              ; Инвертируем ID бит
    push eax
    popfd
    pushfd
    pop eax
    cmp eax, ecx
    je NoCPUID                      ; Бит не изменился -> 386/486

    ; CPUID поддерживается. Проверяем наличие MMX.
    mov eax, 1
    cpuid
    test edx, 00800000h             ; 23-й бит в EDX = поддержка MMX
    jz NoMMX

    ; 1. Парсинг командной строки
    xor ecx, ecx                    
    mov cl, byte ptr [0080h]        
    cmp ecx, 2                      
    jl  Usage                       

    mov al, [0082h]                 
    cmp al, '1'
    je  SetupCOM1
    cmp al, '2'
    je  SetupCOM2
    jmp Usage

SetupCOM1:
    mov [ComBase], 03F8h            
    mov bh, 4                       
    jmp CheckInstalled

SetupCOM2:
    mov [ComBase], 02F8h            
    mov bh, 3                       

CheckInstalled:
    mov ax, (TSR_ID shl 8)          
    int 2Fh
    cmp al, 0FFh                    
    je  AlreadyInst

    push fs
    mov ax, 0040h
    mov fs, ax
    movzx eax, byte ptr [ComBase]   
    mov dx, fs:[0000h]              
    test dx, dx                     
    jz PortMissing                  

    ; Настройка UART (115200 бод, 8N1, FIFO, OUT2)
    mov dx, [ComBase]
    add dx, 3                       
    mov al, 80h                     
    out dx, al
    
    sub dx, 3                       
    mov al, 01h                     
    out dx, al
    inc dx                          
    xor al, al                      
    out dx, al                      
    
    add dx, 2                       
    mov al, 03h                     
    out dx, al
    
    sub dx, 1                       
    mov al, 0C7h                    
    out dx, al
    
    add dx, 2                       
    mov al, 0Bh                     
    out dx, al

    sub dx, 3                       
    mov al, 01h                     
    out dx, al

    ; Перехват векторов DOS/BIOS
    mov ax, 351Ch
    int 21h
    mov word ptr [OldInt1C], bx
    mov word ptr [OldInt1C+2], es
    mov dx, offset Int1CHandler
    mov ax, 251Ch
    int 21h

    mov ax, 3528h
    int 21h
    mov word ptr [OldInt28], bx
    mov word ptr [OldInt28+2], es
    mov dx, offset Int28Handler
    mov ax, 2528h
    int 21h

    mov ax, 352Fh
    int 21h
    mov word ptr [OldInt2F], bx
    mov word ptr [OldInt2F+2], es
    mov dx, offset Int2FHandler
    mov ax, 252Fh
    int 21h

    ; Установка ISR
    xor ax, ax                      
    mov al, bh                      
    add al, 08h                     
    mov ah, 35h                     
    int 21h                         
    mov word ptr [OldCOM], bx
    mov word ptr [OldCOM+2], es
    
    mov dx, offset ComISR
    mov ah, 25h                     
    int 21h

    ; Разблокировка IRQ
    mov cl, bh                      
    mov ah, 1
    shl ah, cl                      
    not ah                          
    in al, 21h                      
    and al, ah                      
    out 21h, al                     

    pop fs                          

    mov dx, offset MsgOk
    mov ah, 09h
    int 21h

    ; Расчет памяти
    mov edx, offset ResidentEnd     
    add edx, BUF_SIZE               
    add edx, 15                     
    shr edx, 4                      
    
    mov ax, 3100h                   
    int 21h                         

; --- ОШИБКИ ---
NoCPUID:
    mov dx, offset MsgNoCPUID
    jmp PrintExit
NoMMX:
    mov dx, offset MsgNoMMX
    jmp PrintExit
Usage:
    mov dx, offset MsgUsage
    jmp PrintExit
PortMissing:
    pop fs
    mov dx, offset MsgNoPort
    jmp PrintExit
AlreadyInst:
    mov dx, offset MsgErr
    jmp PrintExit
PrintExit:
    mov ah, 09h
    int 21h
    mov ax, 4C01h                   
    int 21h

; --- ДАННЫЕ (Без выравнивания в хвосте) ---
MsgNoCPUID db 'Fatal: CPUID instruction not supported. Need Pentium+.', 13, 10, '$'
MsgNoMMX   db 'Fatal: MMX Technology not detected. Need Pentium MMX.', 13, 10, '$'
MsgUsage   db 'Usage: KEYINJ6.COM /1 (COM1) or /2 (COM2)', 13, 10, '$'
MsgErr     db 'Fatal: TSR already resident.', 13, 10, '$'
MsgNoPort  db 'Error: Selected COM port not found in BIOS BDA.', 13, 10, '$'
MsgOk      db 'KEYINJ v6.0 (Pentium MMX Vectorized) Loaded.', 13, 10
           db 'MMX Byte-to-Nibble Unpacking & FPU Safe-State Active.', 13, 10, '$'

end Start

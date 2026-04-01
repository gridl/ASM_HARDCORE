.model tiny
.686p               ; Инструкции Pentium Pro + Привилегированные
.mmx                ; MMX инструкции
.code
org 100h

Start:
    jmp Init

; ===========================================================================
; SHARED DATA (Выравнивание 64 байта для предотвращения False Sharing кэша)
; ===========================================================================
            ALIGN 64
BufTail     dd 0                ; Пишет Core 0
            ALIGN 64
BufHead     dd 0                ; Пишет Core 1
            ALIGN 64
HwLock      dd 0                ; Аппаратный спинлок (0 = свободно, 1 = занято)

            ALIGN 64
MmxMask0F   dq 0000000000000F0Fh 
AsciiTable  db '0123456789ABCDEF'
ScanTable   db 0Bh, 02h, 03h, 04h, 05h, 06h, 07h, 08h, 09h, 0Ah, 1Eh, 30h, 2Eh, 20h, 12h, 21h

BUF_SIZE    equ 2048
BUF_MASK    equ 000007FFh
APIC_BASE   equ 0FEE00000h      ; Физический адрес Local APIC

; Данные для Unreal Mode
GDT         dq 0                ; Null descriptor
GDT_Data    dq 00CF93000000FFFFh ; 4GB Data segment (P=1, DPL=0, Type=Data R/W, Limit=4GB)
GDT_Ptr     dw 15               ; Limit (2 * 8 - 1)
            dd 0                ; Физический адрес GDT (заполнится в Init)

; ===========================================================================
; ЯДРО 0 (BSP): Обработка COM-порта (Прерывания)
; ===========================================================================
            ALIGN 32
ComISR proc far
    pushad
    mov dx, 03F8h               ; Порт COM1 (база)
    add dx, 5                   ; Line Status Register
ReadLoop_C0:
    in al, dx
    test al, 1
    jz EndISR_C0                ; Данных больше нет

    sub dx, 5
    in al, dx                   ; Читаем байт
    add dx, 5

    mov ebx, cs:[BufTail]
    mov edi, ebx
    inc edi
    and edi, BUF_MASK
    
    cmp edi, cs:[BufHead]       ; Проверка переполнения (смотрим на Ядро 1)
    je ReadLoop_C0              ; Буфер полон, игнорируем байт

    mov cs:[IntBuf + ebx], al
    mov cs:[BufTail], edi       ; Публикуем данные для Ядра 1
    jmp ReadLoop_C0

EndISR_C0:
    mov al, 20h
    out 20h, al                 ; EOI для контроллера прерываний
    popad
    iret
ComISR endp


; ===========================================================================
; ЯДРО 1 (AP): Обработка данных и инъекция (Поллинг)
; ===========================================================================
            ; Это ядро должно стартовать с адреса, кратного 4096 байт!
            ; Мы обеспечим это при копировании или расчете вектора.
            ALIGN 4096
AP_Entry:
    cli                         ; На Ядре 1 прерывания запрещены ВСЕГДА
    xor ax, ax
    mov ds, ax                  ; Работаем в контексте физических адресов
    mov es, ax
    
    ; Настройка стека Ядра 1 (в конце нашей программы)
    mov ax, cs
    mov ss, ax
    mov esp, offset ApStackTop

AP_MainLoop:
    mov ebx, cs:[BufHead]
    cmp ebx, cs:[BufTail]       ; Сравниваем с указателем Ядра 0
    je AP_Idle

    ; --- MMX РАСПАКОВКА ---
    movzx eax, byte ptr cs:[IntBuf + ebx]
    movd mm0, eax
    movq mm1, mm0
    psrlw mm1, 4
    punpcklbw mm0, mm1          ; Склеиваем нибблы в байты
    pand mm0, cs:[MmxMask0F]    ; Маскируем лишнее
    movd eax, mm0               ; AH = High Nibble, AL = Low Nibble

    ; Инкремент головы буфера (освобождаем место для Ядра 0)
    inc ebx
    and ebx, BUF_MASK
    mov cs:[BufHead], ebx

    ; Инъекция обоих нибблов
    push eax                    ; Сохранили AL
    mov al, ah
    call AP_Inject              ; Инъекция старшего
    pop eax
    call AP_Inject              ; Инъекция младшего
    
    jmp AP_MainLoop

AP_Idle:
    pause                       ; Снижаем нагрузку на шину памяти
    jmp AP_MainLoop

; --- Процедура инъекции для Ядра 1 ---
AP_Inject:
    movzx ebx, al
    mov cl, cs:[AsciiTable + ebx]
    mov ch, cs:[ScanTable + ebx]

    call AcquireLock            ; Захватываем железный спинлок

    ; Прямая запись в BDA (Bios Data Area)
    mov bx, 0040h
    mov ds, bx
    mov bx, ds:[001Ch]          ; Текущий хвост буфера клавиатуры
    mov dx, bx
    add dx, 2
    cmp dx, 003Eh
    jl  AP_Store
    mov dx, 001Eh               ; Заворот буфера
AP_Store:
    cmp dx, ds:[001Ah]          ; Проверка на переполнение буфера BIOS
    je  AP_Release
    
    mov ds:[bx], cx             ; Записываем скан-код и символ
    mov ds:[001Ch], dx          ; Обновляем указатель хвоста

    ; Звуковое подтверждение (прямое управление портами)
    mov eax, 1000               ; Тон
    mov ecx, 2000               ; Длительность
    call AP_Beep

AP_Release:
    call ReleaseLock            ; Освобождаем железо
    push cs
    pop ds
    ret

; --- Аппаратная синхронизация ---
AcquireLock:
    mov eax, 1
    lock xchg eax, cs:[HwLock]  ; Атомарно ставим 1
    test eax, eax
    jnz AcquireLock             ; Если уже была 1 - крутимся в цикле
    ret

ReleaseLock:
    mov dword ptr cs:[HwLock], 0
    ret

AP_Beep:
    in al, 61h
    or al, 3
    out 61h, al
    mov al, 0B6h
    out 43h, al
    mov ax, 1193                ; Делитель для 1кГц
    out 42h, al
    mov al, ah
    out 42h, al
AP_BeepLoop:
    dec ecx
    jnz AP_BeepLoop
    in al, 61h
    and al, 0FCh
    out 61h, al
    ret

; ===========================================================================
; ИНИЦИАЛИЗАЦИЯ (ВЫПОЛНЯЕТСЯ ТОЛЬКО ЯДРОМ 0)
; ===========================================================================
Init:
    ; 1. Вход в Unreal Mode
    cli
    xor eax, eax
    mov ax, ds
    shl eax, 4
    add eax, offset GDT
    mov dword ptr [GDT_Ptr + 2], eax ; Записываем физ. адрес GDT
    
    lgdt fword ptr [GDT_Ptr]
    
    mov eax, cr0
    or al, 1                    ; Включаем Protected Mode
    mov cr0, eax
    jmp $+2                     ; Очистка конвейера
    
    mov bx, 8                   ; Индекс дескриптора GDT_Data
    mov fs, bx                  ; Загружаем "безлимитный" селектор в FS
    
    and al, 0FEh                ; Выключаем Protected Mode
    mov cr0, eax
    sti                         ; Мы снова в Real Mode, но FS теперь видит 4 ГБ!

    ; 2. Детекция процессора и APIC
    mov eax, 1
    cpuid
    test edx, 1 shl 9           ; Проверка наличия APIC
    jz NoApic

    ; 3. Пробуждение Ядра 1 (INIT-SIPI Sequence)
    ; Вычисляем вектор старта для Ядра 1
    xor eax, eax
    mov ax, cs
    shl eax, 4
    add eax, offset AP_Entry    ; Физический адрес точки входа
    shr eax, 12                 ; Делим на 4096 (получаем Вектор)
    mov bl, al                  ; Сохраняем вектор в BL

    ; Посылаем INIT IPI (Сброс Ядра 1)
    ; Пишем в Local APIC ICR (Interrupt Command Register)
    mov dword ptr fs:[APIC_BASE + 310h], 0 ; Destination: All excluding self
    mov dword ptr fs:[APIC_BASE + 300h], 000C4500h ; INIT, Level Assert

    ; Пауза ~10мс (через BIOS или пустой цикл)
    mov cx, 0FFFFh
Wait1: loop Wait1

    ; Посылаем STARTUP IPI (SIPI) с нашим вектором
    mov eax, 000C4600h
    mov al, bl                  ; Добавляем вектор в команду
    mov dword ptr fs:[APIC_BASE + 300h], eax

    ; Второе SIPI (согласно спецификации Intel для надежности)
    mov cx, 0FFFFh
Wait2: loop Wait2
    mov dword ptr fs:[APIC_BASE + 300h], eax

    ; 4. Настройка прерывания COM1 (IRQ4 -> Int 0Ch)
    mov ax, 250Ch
    mov dx, offset ComISR
    int 21h

    ; Разрешаем IRQ4 в контроллере прерываний (PIC)
    in al, 21h
    and al, 0EFh
    out 21h, al

    ; Настройка самого UART (115200, 8N1)
    mov dx, 03FBh
    mov al, 80h
    out dx, al                  ; DLAB=1
    mov dx, 03F8h
    mov al, 01h                 ; Low byte (115200)
    out dx, al
    mov dx, 03F9h
    mov al, 00h                 ; High byte
    out dx, al
    mov dx, 03FBh
    mov al, 03h                 ; 8N1, DLAB=0
    out dx, al
    mov dx, 03F9h
    mov al, 01h                 ; Разрешить прерывание по приему данных
    out dx, al
    mov dx, 03FCh
    mov al, 0Bh                 ; OUT2, RTS, DTR
    out dx, al

    ; 5. Завершение работы (TSR)
    mov dx, offset MsgOk
    mov ah, 09h
    int 21h

    mov dx, (offset ApStackTop - offset Start + 15) shr 4
    add dx, (BUF_SIZE shr 4)
    mov ax, 3100h               ; Keep Resident
    int 21h

NoApic:
    mov dx, offset MsgNoApic
    mov ah, 09h
    int 21h
    mov ax, 4C01h
    int 21h

MsgOk     db 'SMP KEYINJ v8.0 Active. Core 1 is now polling COM-buffer.', 13, 10, '$'
MsgNoApic db 'Error: Local APIC not found! This machine is not SMP-capable.', 13, 10, '$'

            ALIGN 16
IntBuf      db BUF_SIZE dup(0)  ; Наш кольцевой буфер
            db 512 dup(0)       ; Стек для Ядра 1
ApStackTop  label byte

end Start

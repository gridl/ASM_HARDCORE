; (C) 2026 By Dimitri Grinkevich
; теперь, бля, йасна вам, зачем нужны не только ключи оптимизации у компиляторов, но и директива таргет=


.model tiny
.486                ; Включаем набор инструкций 80486
.code
org 100h            ; DOS .COM формат

Start:
    jmp Init

; ===========================================================================
; ДАННЫЕ РЕЗИДЕНТА (ВЫРОВНЕННЫЕ ДЛЯ L1 КЭША 486-го)
; Директива ALIGN 4 гарантирует, что 32-битные переменные ложатся 
; ровно в 32-битную шину данных, считываясь за 1 такт без пенальти.
; ===========================================================================
            ALIGN 4
OldInt1C    dd 0
OldInt28    dd 0
OldInt2F    dd 0
OldCOM      dd 0

            ALIGN 4
BufHead     dd 0            
BufTail     dd 0            

            ALIGN 4
ComBase     dw 03F8h
Busy        db 0
Flag_ComFull  db 0
Flag_BiosFull db 0

; Таблицы выравниваем по границе кэш-линии (16 байт) для мгновенного предвыборки
            ALIGN 16
AsciiTable  db '0123456789ABCDEF'
            ALIGN 16
ScanTable   db 0Bh, 02h, 03h, 04h, 05h, 06h, 07h, 08h, 09h, 0Ah, 1Eh, 30h, 2Eh, 20h, 12h, 21h
            ALIGN 16
CapsTable   db 0,0,0,0,0,0,0,0,0,0, 1,1,1,1,1,1

TSR_ID      equ 0E1h
BUF_SIZE    equ 2048
BUF_MASK    equ 000007FFh


; ===========================================================================
; АППАРАТНЫЙ ОБРАБОТЧИК ПРЕРЫВАНИЯ UART (ISR)
; Оптимизирован под конвейер 80486.
; ===========================================================================
            ALIGN 4
ComISR proc far
    ; [ОПТИМИЗАЦИЯ 486]: Избегаем PUSHAD (11 тактов). 
    ; Делаем 4 ручных PUSH по 1 такту каждый. Экономия 7 тактов!
    push eax
    push ebx
    push edx
    push edi

    mov dx, cs:[ComBase]
    add dx, 5           ; DX = LSR (Line Status Register)

            ALIGN 4     ; Выравниваем цель перехода для быстрого предвыборки (prefetch)
ReadLoop:
    in al, dx
    test al, 1          ; Есть данные?
    jz EndISR

    sub dx, 5           ; DX = RBR
    in al, dx           ; Читаем байт из порта
    add dx, 5           

    ; Вычисление следующего хвоста кольцевого буфера
    mov ebx, cs:[BufTail]
    mov edi, ebx
    inc edi
    and edi, BUF_MASK   
    
    ; --- Branchless проверка переполнения (SETE) ---
    ; Вместо CMP и Jcc (что ломает конвейер на 486), мы используем SETE.
    ; Если EDI == BufHead, ZF=1, и SETE пишет 1 в флаг. 
    cmp edi, cs:[BufHead]
    sete cs:[Flag_ComFull] ; Ставим флаг переполнения без ветвления!
    je  ReadLoop           ; Если буфер полон, байт уже прочитан из порта, просто игнорим запись

    ; Пишем в память, используя 32-битный индекс
    mov cs:[IntBuf + ebx], al
    mov cs:[BufTail], edi
    jmp ReadLoop

            ALIGN 4
EndISR:
    mov al, 20h
    out 20h, al         ; Сигнал EOI контроллеру прерываний

    pop edi             ; [ОПТИМИЗАЦИЯ 486]: 4 такта на восстановление
    pop edx
    pop ebx
    pop eax
    iret
ComISR endp


; ===========================================================================
; ОБРАБОТЧИКИ DOS (Таймер, Простой, Мультиплексор)
; ===========================================================================
            ALIGN 4
Int1CHandler proc far
    call ProcessRingBuffer
    jmp cs:[OldInt1C]
Int1CHandler endp

            ALIGN 4
Int28Handler proc far
    call ProcessRingBuffer
    jmp cs:[OldInt28]
Int28Handler endp

            ALIGN 4
Int2FHandler proc far
    cmp ah, TSR_ID
    jne Chain2F
    cmp al, 00h
    jne Chain2F
    mov al, 0FFh
    iret
Chain2F:
    jmp cs:[OldInt2F]
Int2FHandler endp


; ===========================================================================
; ЯДРО ИНЪЕКЦИИ И УПРАВЛЕНИЯ ЗВУКОМ
; ===========================================================================
            ALIGN 4
ProcessRingBuffer proc near
    cmp cs:[Busy], 1
    je PRB_Exit
    mov cs:[Busy], 1

    push fs
    mov ax, 0040h
    mov fs, ax          ; FS указывает на сегмент BIOS (BDA)

    sti                 ; Разрешаем аппаратные прерывания

            ALIGN 4
PRB_Loop:
    mov ebx, cs:[BufHead]
    cmp ebx, cs:[BufTail]
    je PRB_Done

    mov al, cs:[IntBuf + ebx]
    inc ebx
    and ebx, BUF_MASK
    mov cs:[BufHead], ebx

    mov dl, fs:[0017h]  ; Сохраняем флаги клавиатуры BIOS

    ; Старший полубайт
    mov ah, al
    shr ah, 4
    call ProcessNibble

    ; Младший полубайт
    mov ah, al
    and ah, 0Fh
    call ProcessNibble

    ; Восстанавливаем CapsLock (если изменился)
    cmp fs:[0017h], dl
    je PRB_SkipRestore
    mov fs:[0017h], dl  
    call UpdateLEDs

            ALIGN 4
PRB_SkipRestore:
    jmp PRB_Loop

            ALIGN 4
PRB_Done:
    ; Проверка флагов переполнения для вывода звуковых алертов
    cmp cs:[Flag_ComFull], 1
    jne CheckBios
    mov cs:[Flag_ComFull], 0
    ; Звук переполнения COM (Скрежет)
    mov eax, 200        
    mov ecx, 300000     
    call PlaySound      

            ALIGN 4
CheckBios:
    cmp cs:[Flag_BiosFull], 1
    jne PRB_Cleanup
    mov cs:[Flag_BiosFull], 0
    ; Звук переполнения BIOS (Гудок)
    mov eax, 9000       
    mov ecx, 400000     
    call PlaySound

PRB_Cleanup:
    pop fs              
    mov cs:[Busy], 0
PRB_Exit:
    ret
ProcessRingBuffer endp


; ===========================================================================
; ИНЪЕКЦИЯ СИМВОЛА (BRANCHLESS МАГИЯ)
; ===========================================================================
            ALIGN 4
ProcessNibble proc near
    movzx ebx, ah       ; Мгновенное расширение для индекса

    mov cl, cs:[AsciiTable + ebx]
    mov ch, cs:[ScanTable + ebx]
    mov al, cs:[CapsTable + ebx]

    ; 386/486 Битовая магия
    bt word ptr fs:[0017h], 6  
    setc ah                    
    cmp al, ah                 
    je InjectChar              

    btc word ptr fs:[0017h], 6 
    
    ; Звук клика CapsLock
    pushad
    mov eax, 3000       
    mov ecx, 15000      
    call PlaySound
    popad
    call UpdateLEDs     

            ALIGN 4
InjectChar:
    mov ax, 4F00h
    mov al, ch
    stc
    int 15h
    jc SkipInject

    mov ch, al
    
    cli                 ; CRITICAL: Блокировка прерываний

    mov bx, fs:[001Ch]  ; Хвост буфера BIOS
    mov dx, bx
    add dx, 2           ; DX = Хвост + 2

    ; Branchless закольцовка системного буфера ---
    ; Буфер BIOS лежит от 001Eh до 003Eh. Если DX >= 003Eh, нужно вычесть 20h.
    ; На 8086/286 мы писали CMP + JL. Тут мы используем конвейер по максимуму!
    
    cmp dx, 003Eh       ; Сравниваем DX с 62 (3Eh)
    setae al            ; Если DX >= 3Eh, AL = 1 (иначе 0)
    movzx eax, al       ; EAX = 1 или 0
    shl eax, 5          ; Умножаем на 32 (20h). EAX теперь 20h или 0h
    sub dx, ax          ; Вычитаем 20h (закольцовка) или 0 (оставляем как есть)!
    
    ; -----------------------------------------------------------------

    cmp dx, fs:[001Ah]  ; Проверка переполнения системного буфера
    je  BiosOverrun     

    mov fs:[bx], cx     ; Вброс скан-кода и ASCII
    mov fs:[001Ch], dx  ; Сдвиг хвоста
    sti

    ; Успешный клик
    pushad
    mov eax, 1000       
    mov ecx, 2000       
    call PlaySound
    popad
    ret

            ALIGN 4
BiosOverrun:
    sti
    mov cs:[Flag_BiosFull], 1 
SkipInject:
    ret
ProcessNibble endp


; ===========================================================================
; ЗВУКОВОЙ ДВИЖОК
; ===========================================================================
            ALIGN 4
PlaySound proc near
    pushad
    in al, 61h
    or al, 03h
    out 61h, al

    mov al, 0B6h        
    out 43h, al
    mov ax, bx          
    out 42h, al         
    mov al, ah
    out 42h, al         

            ALIGN 4     ; Цикл задержки выравниваем для кэша!
WaitMicroseconds:
    in al, 80h          ; Hardware Delay (~1 us)
    loop WaitMicroseconds

    in al, 61h
    and al, 0FCh        
    out 61h, al
    popad
    ret
PlaySound endp


; ===========================================================================
; УПРАВЛЕНИЕ СВЕТОДИОДАМИ КЛАВИАТУРЫ
; ===========================================================================
            ALIGN 4
UpdateLEDs proc near
    pushad
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
            ALIGN 4
EndLED:
    popad
    ret
UpdateLEDs endp

            ALIGN 4
WaitKbd proc near
    mov cx, 0FFFFh
            ALIGN 4     ; Кэш-линия для поллинга порта
WaitLoop:
    in al, 64h
    test al, 02h        
    jz WaitDone
    loop WaitLoop
    stc
    ret
            ALIGN 4
WaitDone:
    clc
    ret
WaitKbd endp


ResidentEnd label byte
IntBuf equ offset ResidentEnd


; ===========================================================================
; ИНИЦИАЛИЗАЦИЯ
; ===========================================================================
            ALIGN 4
Init:
    ; 1. Парсинг командной строки
    movzx ecx, byte ptr [0080h]     
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
    ; 2. Проверка мультиплексора (уже установлен?)
    mov ax, (TSR_ID shl 8)          
    int 2Fh
    cmp al, 0FFh                    
    je  AlreadyInst

    ; 3. Проверка BDA (есть ли порт физически)
    push fs
    mov ax, 0040h
    mov fs, ax
    movzx eax, byte ptr [ComBase]   
    mov dx, fs:[0000h]              ; Читаем адрес COM1 из BDA
    test dx, dx
    jz PortMissing                  

    ; 4. Настройка UART (115200 бод, 8N1, FIFO, OUT2)
    mov dx, [ComBase]
    add dx, 3                       
    mov al, 80h                     ; DLAB = 1
    out dx, al
    
    sub dx, 3                       
    mov al, 01h                     ; Делитель LSB
    out dx, al
    inc dx                          
    mov al, 00h                     ; Делитель MSB
    out dx, al
    
    add dx, 2                       
    mov al, 03h                     ; 8N1, DLAB = 0
    out dx, al
    
    sub dx, 1                       
    mov al, 0C7h                    ; FIFO Enable, Clear, 14-byte trigger
    out dx, al
    
    add dx, 2                       
    mov al, 0Bh                     ; OUT2=1, RTS=1, DTR=1
    out dx, al

    sub dx, 3                       
    mov al, 01h                     ; IER: Enable RDA
    out dx, al

    ; 5. Перехват векторов DOS/BIOS
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

    ; 6. Установка ISR для COM порта
    movzx ax, bh                    
    add al, 08h                     
    mov ah, 35h
    int 21h                         
    mov word ptr [OldCOM], bx
    mov word ptr [OldCOM+2], es
    
    mov dx, offset ComISR
    mov ah, 25h                     
    int 21h

    ; 7. Разблокировка IRQ в контроллере прерываний 8259A
    mov cl, bh                      
    mov ah, 1
    shl ah, cl                      
    not ah                          
    in al, 21h                      
    and al, ah                      
    out 21h, al                     

    pop fs                          

    ; 8. Успешный выход с TSR
    mov dx, offset MsgOk
    mov ah, 09h
    int 21h

    ; Расчет памяти (с branchless математикой 386/486)
    mov edx, offset ResidentEnd
    add edx, BUF_SIZE               
    add edx, 15                     
    shr edx, 4                      
    
    mov ax, 3100h                   
    int 21h                         

; --- Зона обработки ошибок ---
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

; --- Данные (не требуют выравнивания) ---
MsgUsage  db 'Usage: KEYINJ4.COM /1 (COM1) or /2 (COM2)', 13, 10, '$'
MsgErr    db 'Fatal: TSR already resident.', 13, 10, '$'
MsgNoPort db 'Error: Selected COM port not found in BIOS BDA.', 13, 10, '$'
MsgOk     db 'KEYINJ v4.0 (80486 Pipelined Mode) Loaded.', 13, 10
          db 'ALIGN 4 Prefetching & Branchless Logic Active.', 13, 10, '$'

end Start

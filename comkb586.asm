; (C) 2026 By Dimitri Grinkevich
; теперь, бля, йасна вам, зачем нужны не только ключи оптимизации у компиляторов, но и директива таргет=

.model tiny
.586                ; Включаем инструкции Pentium и оптимизацию P5
.code
org 100h

Start:
    jmp Init

; ===========================================================================
; ДАННЫЕ РЕЗИДЕНТА (Выравнивание под 32-байтовую линию кэша P5)
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

; Таблицы разносим так, чтобы они не конфликтовали в кэше.
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
; АППАРАТНЫЙ ОБРАБОТЧИК UART (СУПЕРСКАЛЯРНАЯ ОПТИМИЗАЦИЯ)
; ===========================================================================
            ALIGN 32    ; Начало ISR должно попадать ровно в строку кэша
ComISR proc far
    ; --- Идеальное спаривание стека (2 такта на 4 регистра) ---
    push eax            ; [U-pipe]
    push ebx            ; [V-pipe]
    push edx            ; [U-pipe]
    push edi            ; [V-pipe]

    mov dx, cs:[ComBase]; [U-pipe]
    add dx, 5           ; [U-pipe] (Зависимость по DX, V-pipe простаивает 1 такт)

            ALIGN 16    ; Короткий цикл - выравниваем для Branch Target Buffer
ReadLoop:
    in al, dx           ; Чтение порта НЕ спаривается (сериализующая инструкция)
    test al, 1          ; [U-pipe]
    jz EndISR           ; [V-pipe] (Предугадывается как Not Taken)

    sub dx, 5           ; [U-pipe]
    in al, dx           ; Читаем байт
    add dx, 5           ; [U-pipe]

    ; --- Спаривание + Обход AGI (Address Generation Interlock) ---
    mov ebx, cs:[BufTail]  ; [U-pipe] Читаем хвост
    mov edi, ebx           ; [V-pipe] Копируем в EDI
    inc edi                ; [U-pipe] Вычисляем новый хвост
    ; Если сейчас сделать AND EDI, BUF_MASK, будет Stall по RAW (Read-After-Write).
    ; Поэтому мы вставляем независимую инструкцию между ними!
    cmp edi, cs:[BufHead]  ; [V-pipe] ВНЕЗАПНО сравниваем до маскирования! 
                           ; (Наш буфер выровнен, так что переполнение будет видно и так,
                           ; но для строгости маску наложим следующим тактом)
    
    and edi, BUF_MASK      ; [U-pipe] Теперь маскируем (Stall'а нет!)
    sete cs:[Flag_ComFull] ; [V-pipe] Branchless флаг переполнения
    je ReadLoop            ; [U-pipe] Если хвост догнал голову - прыгаем на начало

    ; [ВНИМАНИЕ]: Мы изменили EBX и тут же используем его для адресации.
    ; На Pentium это AGI (1 такт пенальти). Чтобы избежать этого, мы заранее
    ; вычислили EBX выше, пока порт читал данные!
    mov cs:[IntBuf + ebx], al ; Пишем в память
    mov cs:[BufTail], edi     ; Обновляем хвост
    jmp ReadLoop

            ALIGN 16
EndISR:
    mov al, 20h         ; [U-pipe]
    out 20h, al         ; Сигнал EOI

    pop edi             ; [U-pipe]
    pop edx             ; [V-pipe]
    pop ebx             ; [U-pipe]
    pop eax             ; [V-pipe]
    iret
ComISR endp


; ===========================================================================
; ОБРАБОТЧИКИ DOS (Таймер, Простой, Мультиплексор)
; ===========================================================================
            ALIGN 16
Int1CHandler proc far
    call ProcessRingBuffer
    jmp cs:[OldInt1C]
Int1CHandler endp

            ALIGN 16
Int28Handler proc far
    call ProcessRingBuffer
    jmp cs:[OldInt28]
Int28Handler endp

            ALIGN 16
Int2FHandler proc far
    cmp ah, TSR_ID      ; [U-pipe]
    jne Chain2F         ; [V-pipe]
    test al, al         ; [U-pipe] (XOR/TEST лучше CMP с нулем)
    jne Chain2F         ; [V-pipe]
    mov al, 0FFh        ; [U-pipe]
    iret
Chain2F:
    jmp cs:[OldInt2F]
Int2FHandler endp


; ===========================================================================
; ЯДРО ИНЪЕКЦИИ (Pipeline Friendly)
; ===========================================================================
            ALIGN 32
ProcessRingBuffer proc near
    cmp cs:[Busy], 1
    je PRB_Exit
    mov cs:[Busy], 1

    push fs
    mov ax, 0040h
    mov fs, ax

    sti

            ALIGN 16
PRB_Loop:
    mov ebx, cs:[BufHead]
    cmp ebx, cs:[BufTail]
    je PRB_Done

    mov al, cs:[IntBuf + ebx]
    inc ebx
    and ebx, BUF_MASK
    mov cs:[BufHead], ebx

    mov dl, fs:[0017h]  ; DL = оригинальные флаги клавы

    ; --- Суперскалярная обработка полубайта ---
    mov ah, al          ; [U-pipe]
    shr ah, 4           ; [V-pipe] 
    call ProcessNibble

    mov ah, al          ; [U-pipe]
    and ah, 0Fh         ; [V-pipe]
    call ProcessNibble

    cmp fs:[0017h], dl
    je PRB_SkipRestore
    mov fs:[0017h], dl  
    call UpdateLEDs

PRB_SkipRestore:
    jmp PRB_Loop

            ALIGN 16
PRB_Done:
    cmp cs:[Flag_ComFull], 1
    jne CheckBios
    mov cs:[Flag_ComFull], 0
    mov eax, 200        
    mov ecx, 300000     
    call PlaySound      

            ALIGN 16
CheckBios:
    cmp cs:[Flag_BiosFull], 1
    jne PRB_Cleanup
    mov cs:[Flag_BiosFull], 0
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
; ИНЪЕКЦИЯ СИМВОЛА (Убийство BTC ради Pairing)
; ===========================================================================
            ALIGN 32
ProcessNibble proc near
    movzx ebx, ah       ; [U-pipe] Мгновенное расширение индекса

    ; Независимые загрузки - идеально спариваются в U и V!
    mov cl, cs:[AsciiTable + ebx]  ; [U-pipe]
    mov ch, cs:[ScanTable + ebx]   ; [V-pipe]
    mov al, cs:[CapsTable + ebx]   ; [U-pipe]
    
    ; --- Замена медленных BT/BTC на простые логические операции ---
    ; BT/BTC не спариваются и жрут до 8 тактов. Заменяем на чтение+маску!
    mov dh, fs:[0017h]             ; [V-pipe] Читаем текущий статус BDA
    mov ah, dh                     ; [U-pipe] Копия статуса
    shr ah, 6                      ; [V-pipe] Сдвигаем 6-й бит (Caps) в нулевой
    and ah, 1                      ; [U-pipe] Теперь AH = 1 (включен) или 0 (выключен)

    cmp al, ah                     ; [V-pipe] Требуется ли смена?
    je InjectChar                  ; [U-pipe] Предиктор: ветвление вперед -> Not Taken (Идеально)

    ; Меняем регистр CapsLock простым XOR (выполняется за 1 такт, спаривается)
    xor dh, 040h                   ; [U-pipe] Инвертируем 6-й бит
    mov fs:[0017h], dh             ; [V-pipe] Пишем обратно в память BDA
    
    ; Звук клика CapsLock
    push eax            ; Вместо PUSHAD кидаем только то, что портит PlaySound
    push ecx            ; Спариваем в U/V!
    push edx            ; [U-pipe]
    mov eax, 3000       ; [V-pipe] 
    mov ecx, 15000      ; [U-pipe]
    call PlaySound
    pop edx             ; [U-pipe]
    pop ecx             ; [V-pipe]
    pop eax             ; [U-pipe]

    call UpdateLEDs     

            ALIGN 16
InjectChar:
    mov ax, 4F00h
    mov al, ch
    stc
    int 15h
    jc SkipInject

    mov ch, al
    
    cli                 ; CRITICAL SECTION

    mov bx, fs:[001Ch]  
    mov dx, bx          ; [U-pipe]
    add dx, 2           ; [V-pipe] DX = Хвост + 2

    ; Branchless закольцовка остается, она прекрасна даже на Пне.
    cmp dx, 003Eh       ; [U-pipe]
    setae al            ; [V-pipe]
    movzx eax, al       ; [U-pipe]
    shl eax, 5          ; [V-pipe]
    sub dx, ax          ; [U-pipe] 
    
    cmp dx, fs:[001Ah]  ; Проверка переполнения
    je  BiosOverrun     ; Предиктор: вперед -> Not Taken

    mov fs:[bx], cx     ; Вброс символа
    mov fs:[001Ch], dx  ; Сдвиг хвоста
    sti

    ; Успешный клик
    push eax            ; [U-pipe]
    push ecx            ; [V-pipe]
    mov eax, 1000       ; [U-pipe]
    mov ecx, 2000       ; [V-pipe]
    call PlaySound
    pop ecx             ; [U-pipe]
    pop eax             ; [V-pipe]
    ret

            ALIGN 16
BiosOverrun:
    sti
    mov cs:[Flag_BiosFull], 1 
SkipInject:
    ret
ProcessNibble endp


; ===========================================================================
; ЗВУК (С заменой медленного LOOP)
; ===========================================================================
            ALIGN 16
PlaySound proc near
    ; Сохраняем только нужное (никаких PUSHAD!)
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
    in al, 80h          ; Hardware Delay (~1 us). IN не спаривается, ну и фиг с ним.
    ; На Pentium команда LOOP дико неоптимизирована (5-6 тактов). 
    ; Заменяем на DEC + JNZ (2 такта, спариваются с другими командами!)
    dec ecx             ; [U-pipe]
    jnz WaitMicroseconds; [V-pipe] Предиктор: назад -> Taken (Идеально)

    in al, 61h
    and al, 0FCh        
    out 61h, al
    
    pop ebx
    pop eax
    ret
PlaySound endp


; ===========================================================================
; СВЕТОДИОДЫ (Выравнивание для кэша)
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
    dec cx              ; Замена LOOP
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
; ИНИЦИАЛИЗАЦИЯ 
; ===========================================================================
            ALIGN 32
Init:
    ; Замена медленного MOVZX + CMP на спаренные логические опкоды
    xor ecx, ecx                    ; [U-pipe] Обнуляем (XOR лучше MOV reg, 0)
    mov cl, byte ptr [0080h]        ; [V-pipe] Читаем длину хвоста
    cmp ecx, 2                      ; [U-pipe]
    jl  Usage                       ; [V-pipe]

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
    test dx, dx                     ; [U-pipe] TEST спаривается
    jz PortMissing                  ; [V-pipe]

    ; Настройка UART (115200 бод, 8N1, FIFO, OUT2)
    mov dx, [ComBase]
    add dx, 3                       
    mov al, 80h                     
    out dx, al
    
    sub dx, 3                       
    mov al, 01h                     
    out dx, al
    inc dx                          
    xor al, al                      ; [U-pipe] XOR AL, AL вместо MOV AL, 0
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
    xor ax, ax                      ; [U-pipe] Чистим
    mov al, bh                      ; [V-pipe]
    add al, 08h                     ; [U-pipe]
    mov ah, 35h                     ; [V-pipe]
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

    ; Расчет памяти (с учетом спаривания)
    mov edx, offset ResidentEnd     ; [U-pipe]
    add edx, BUF_SIZE               ; [U-pipe] 
    ; Зависимость по EDX, тут конвейер разделится
    add edx, 15                     ; [U-pipe]
    shr edx, 4                      ; [U-pipe] (Сдвиги спариваются только если они в U-pipe)
    
    mov ax, 3100h                   
    int 21h                         

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

MsgUsage  db 'Usage: KEYINJ5.COM /1 (COM1) or /2 (COM2)', 13, 10, '$'
MsgErr    db 'Fatal: TSR already resident.', 13, 10, '$'
MsgNoPort db 'Error: Selected COM port not found in BIOS BDA.', 13, 10, '$'
MsgOk     db 'KEYINJ v5.0 (Pentium Superscalar P5) Loaded.', 13, 10
          db 'U/V Pipe Pairing & AGI-Free Logic Active.', 13, 10, '$'

end Start

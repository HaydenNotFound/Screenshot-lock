; ============================================================
; block_screenshot.asm  (NASM, x64, Windows 10/11)
;
; СЛОИ ЗАЩИТЫ, пока эта программа запущена:
;
;   1) PrintScreen (без модификаторов)
;   2) Alt + PrintScreen
;   3) Win + Shift + S (Ножницы)              
;   4) Win + PrintScreen (сохранение в файл)
;   5) Win + Alt + PrintScreen и Win + PrtScn 
;   6) Если "Ножницы"/"Screen Sketch" всё-таки запущены ЛЮБЫМ
;      другим способом (значок, меню Пуск, голосовой помощник
;      и т.п., а не клавишами) - фоновый опрос списка процессов
;      (SetTimer раз в ~120 мс + CreateToolhelp32Snapshot)
;      находит такой процесс и завершает его через
;      TerminateProcess до того, как пользователь успеет
;      сделать снимок.
;
; ВАЖНО про п.6: точное имя процесса Snipping Tool / Screen
; Sketch МОЖЕТ ОТЛИЧАТЬСЯ в зависимости от версии/сборки
; Windows. Проверьте на своей машине: Диспетчер задач ->
; "Подробности" -> запустите Ножницы любым способом без этой
; программы -> впишите точное имя .exe в nameXxx ниже.
;
; ОГРАНИЧЕНИЯ, которые остаются в любом случае:
;   - Сторонние программы захвата экрана, запись видео,
;     фото с телефона, удалённый просмотр экрана (RDP/
;     TeamViewer и т.п.) - НЕ блокируются.
;   - Опрос процессов (п.6) - это гонка: интервал ~120 мс можно
;     уменьшить ценой нагрузки на CPU, но 100%-й гарантии
;     "успеть раньше" не даёт ни один метод без прав
;     администратора/драйвера.
;
; Замените "*** " на реальный адрес/название сайта в msgText.
;
; Сборка:
;   nasm -f win64 block_screenshot.asm -o block_screenshot.obj
;   .\GoLink.exe /console /entry main block_screenshot.obj kernel32.dll user32.dll
;   (/console можно убрать, чтобы не было окна терминала)
; ============================================================
; Q: зачем в конце ыфзывать UnregisterHotKey, если программа уже завершает работу? Разве не достаточно просто выйти из программы?
; A: Вызов UnregisterHotKey в конце программы нужно для того, чтобы корректно удалить регистрацию горячих клавиш, 
;    которые были зарегистрированы ранее. Если этого не сделать, то эти горячие клавиши останутся зарегистрированными в системе 
;    даже после завершения программы, что может привести к неожиданному поведению или конфликтам с другими приложениями. 
;    Поэтому важно явно вызвать UnregisterHotKey для каждой зарегистрированной горячей клавиши перед завершением программы.
;
; Q: можно ли завершить программу в терминале нажатием клавиш Ctrk + C? Если да, то что будет с зарегистрированными горячими клавишами?
; A: Да, можно завершить программу в терминале нажатием Ctrl + C. Однако, если программа завершится таким образом, то зарегистрированные горячие клавиши останутся в системе
;
; Q: что будет с установленным хук-обработчиком клавиатуры, если программа завершится?
; A: Если программа завершится, установленный хук-обработчик клавиатуры будет автоматически удален системой. 
;    Однако, если программа завершится некорректно (например, из-за сбоя), хук может остаться активным, 
;    что приведет к непредсказуемому поведению системы. Поэтому важно корректно завершать программу и удалять хук с помощью UnhookWindowsHookEx.
; ============================================================


default rel                          

%define VK_SNAPSHOT          0x2C
%define VK_S_KEY             0x53
%define VK_LWIN              0x5B
%define VK_RWIN              0x5C
%define VK_SHIFT_KEY         0x10
%define VK_MENU_KEY          0x12     ; Alt (левый или правый, значение общее)
%define MOD_ALT              0x0001
%define MOD_WIN              0x0008
%define MOD_NOREPEAT         0x4000
%define WM_HOTKEY            0x0312
%define WM_KEYDOWN           0x0100
%define WM_SYSKEYDOWN        0x0104
%define WM_TIMER             0x0113
%define WM_APP_BLOCKED       0x8001   ; наше собственное сообщение-уведомление
%define MB_OK                     0
%define MB_ICONWARNING         0x30
%define MB_SYSTEMMODAL       0x1000
%define HOTKEY_ID_PRTSCN          1
%define HOTKEY_ID_ALT_PRTSCN      2
%define WH_KEYBOARD_LL           13
%define HC_ACTION                 0
%define TH32CS_SNAPPROCESS   0x00000002
%define PROCESS_TERMINATE    0x0001
%define PROCENTRY_SIZE          304   ; sizeof(PROCESSENTRY32), x64
%define PROCENTRY_PID_OFF         8   ; offset th32ProcessID
%define PROCENTRY_EXE_OFF        44   ; offset szExeFile
%define POLL_INTERVAL_MS        120
%define WM_QUIT              0x0012   ; стандартное сообщение Windows "завершить цикл сообщений"
%define STD_INPUT_HANDLE         -10  ; код для GetStdHandle (консольный stdin)
%define STD_OUTPUT_HANDLE        -11  ; код для GetStdHandle (консольный stdout)
%define INPUT_BUF_SIZE            64  ; буфер под одну введённую строку
%define CP_1251                 1251  ; кодовая страница Windows-1251 (та же, что и байты hintMsg/msgText)

extern RegisterHotKey                 ; символ RegisterHotKey не определен в этом модуле, он будет предоставлен извне, из user32.dll
extern UnregisterHotKey               ; символ UnregisterHotKey не определен в этом модуле, он будет предоставлен из��не, из user32.dll
extern GetMessageA                    ; символ GetMessageA не определен в этом модуле, он будет предоставлен извне, из user32.dll
extern PostThreadMessageA             ; символ PostThreadMessageA не определен в этом модуле, он будет предоставлен извне, из user32.dll
extern MessageBoxA                    ; символ MessageBoxA не определен в этом модуле, он будет предоставлен извне, из user32.dll
extern ExitProcess                    ; символ ExitProcess не определен в этом модуле, он будет предоставлен извне, из kernel32.dll
extern GetLastError                   ; символ GetLastError не определен в этом модуле, он будет предоставлен извне, из kernel32.dll
extern wsprintfA                      ; символ wsprintfA не определен в этом модуле, он будет предоставлен извне, из user32.dll
extern SetWindowsHookExA              ; символ SetWindowsHookExA не определен в этом модуле, он будет предоставлен извне, из user32.dll
extern UnhookWindowsHookEx            ; символ UnhookWindowsHookEx не определен в этом модуле, он будет предоставлен извне, из user32.dll
extern CallNextHookEx                 ; символ CallNextHookEx не определен в этом модуле, он будет предоставлен извне, из user32.dll
extern GetAsyncKeyState               ; символ GetAsyncKeyState не определен в этом модуле, он будет предоставлен извне, из user32.dll
extern GetCurrentThreadId             ; символ GetCurrentThreadId не определен в этом модуле, он будет предоставлен извне, из kernel32.dll
extern SetTimer                       ; символ SetTimer не определен в этом модуле, он будет предоставлен извне, из user32.dll
extern KillTimer                      ; символ KillTimer не определен в этом модуле, он будет предоставлен извне, из user32.dll
extern CreateToolhelp32Snapshot       ; символ CreateToolhelp32Snapshot не определен в этом модуле, он будет предоставлен извне, из kernel32.dll
extern Process32First                 ; символ Process32First не определен в этом модуле, он будет предоставлен извне, из kernel32.dll
extern Process32Next                  ; символ Process32Next не определен в этом модуле, он будет предоставлен извне, из kernel32.dll
extern OpenProcess                    ; символ OpenProcess не определен в этом модуле, он будет предоставлен извне, из kernel32.dll
extern TerminateProcess               ; символ TerminateProcess не определен в этом модуле, он будет предоставлен извне, из kernel32.dll
extern CloseHandle                    ; символ CloseHandle не определен в этом модуле, он будет предоставлен извне, из kernel32.dll
extern lstrcmpiA                      ; символ lstrcmpiA не определен в этом модуле, он будет предоставлен извне, из user32.dll
extern CreateThread                   ; символ CreateThread не определен в этом модуле, он будет предоставлен извне, из kernel32.dll
extern GetStdHandle                   ; символ GetStdHandle не определен в этом модуле, он будет предоставлен извне, из kernel32.dll
extern ReadFile                       ; символ ReadFile не определен в этом модуле, он будет предоставлен извне, из kernel32.dll
extern WriteFile                      ; символ WriteFile не определен в этом модуле, он будет предоставлен извне, из kernel32.dll
extern SetConsoleOutputCP             ; символ SetConsoleOutputCP не определен в этом модуле, он будет предоставлен извне, из kernel32.dll

section .data
    ; "Внимание" (CP1251), байтами -> не зависит от кодировки
    ; сохранения самого .asm-файла
    msgTitle db 0xC2,0xED,0xE8,0xEC,0xE0,0xED,0xE8,0xE5, 0  ; "Внимание"

    ; "Нет, не в мою смену. Закрой сайт *** и только тогда
    ;  сможешь сделать скриншот.
    ;  Голуби не знают пощады."
    msgText:
        db 0xCD,0xE5,0xF2, ",", " "                         ; "Нет, "
        db 0xED,0xE5, " "                                   ; "не "
        db 0xE2, " "                                        ; "в "
        db 0xEC,0xEE,0xFE, " "                              ; "мою "
        db 0xF1,0xEC,0xE5,0xED,0xF3, ".", " "               ; "смену. "
        db 0xC7,0xE0,0xEA,0xF0,0xEE,0xE9, " "               ; "Закрой "
        db 0xF1,0xE0,0xE9,0xF2, " "                         ; "сайт "
        db "***", " "                                       ; "*** "
        db 0xE8, " "                                        ; "и "
        db 0xF2,0xEE,0xEB,0xFC,0xEA,0xEE, " "               ; "только "
        db 0xF2,0xEE,0xE3,0xE4,0xE0, " "                    ; "тогда "
        db 0xF1,0xEC,0xEE,0xE6,0xE5,0xF8,0xFC, " "          ; "сможешь "
        db 0xF1,0xE4,0xE5,0xEB,0xE0,0xF2,0xFC, " "          ; "сделать "
        db 0xF1,0xEA,0xF0,0xE8,0xED,0xF8,0xEE,0xF2, ".", 10 ; "скриншот.\n"
        db 0xC3,0xEE,0xEB,0xF3,0xE1,0xE8, " "               ; "Голуби "
        db 0xED,0xE5, " "                                   ; "не "
        db 0xE7,0xED,0xE0,0xFE,0xF2, " "                    ; "знают "
        db 0xEF,0xEE,0xF9,0xE0,0xE4,0xFB, "."               ; "пощады."
        db 0

    ; Отладочные строки (чистый ASCII)
    dbgTitle      db "DEBUG", 0
    dbgFmtPrt     db "RegisterHotKey(PrintScreen) FAILED. GetLastError = %d"
                  db 10, "(check: PRINT SCREEN snip toggle must be OFF)", 0
    dbgFmtAltPrt  db "RegisterHotKey(Alt+PrintScreen) FAILED. GetLastError = %d", 0
    dbgFmtHook    db "SetWindowsHookExA(WH_KEYBOARD_LL) FAILED. GetLastError = %d", 0

    ; Имена процессов, которые считаем "инструментом скриншота".
    ; lstrcmpiA регистронезависимый, поэтому регистр букв тут не важен.
    ; При необходимости допишите/исправьте под свою версию Windows.
    nameSnippingTool    db "SnippingTool.exe", 0
    nameScreenSketch    db "ScreenSketch.exe", 0
    nameScreenClipHost1 db "ScreenClippingHost.exe", 0
    nameScreenClipHost2 db "ScreenClipHost.exe", 0

    ; Флаг безопасного завершения, вводимый в терминале. Хранится в
    ; верхнем регистре, т.к. ConsoleWatcherThread явно приводит введённую
    ; строку к верхнему регистру перед сравнением - поэтому "stop",
    ; "Stop", "STOP" и любые другие варианты регистра срабатывают
    ; одинаково. Строка чистый ASCII, CP1251 тут не нужен.
    exitFlag db "STOP", 0

    ; Подсказка, которая печатается в консоль при старте программы.
    ; "Для безопасного завершения программы введите STOP и нажмите Enter."
    ; Байты CP1251 - по тем же причинам, что и msgTitle/msgText выше.
    hintMsg:
        db 0xC4,0xEB,0xFF, " "                                             ; "Для "
        db 0xE1,0xE5,0xE7,0xEE,0xEF,0xE0,0xF1,0xED,0xEE,0xE3,0xEE, " "     ; "безопасного "
        db 0xE7,0xE0,0xE2,0xE5,0xF0,0xF8,0xE5,0xED,0xE8,0xFF, " "          ; "завершения "
        db 0xEF,0xF0,0xEE,0xE3,0xF0,0xE0,0xEC,0xEC,0xFB, " "               ; "программы "
        db 0xE2,0xE2,0xE5,0xE4,0xE8,0xF2,0xE5, " "                         ; "введите "
        db "STOP", " "                                                     ; "STOP "
        db 0xE8, " "                                                       ; "и "
        db 0xED,0xE0,0xE6,0xEC,0xE8,0xF2,0xE5, " "                         ; "нажмите "
        db "Enter.", 13, 10                                                ; "Enter." + CRLF
    hintMsgEnd:
%define HINT_MSG_LEN (hintMsgEnd - hintMsg)   ; длина в байтах, считается ассемблером автоматически

section .bss
    msgStruct    resb 48              ; MSG-структура для GetMessageA, зарезервирует 48 байт
    dbgBuf       resb 160             ; буфер под отформатированную строку
    mainThreadId resd 1               ; id потока, который крутит цикл сообщений
    hHookHandle  resq 1               ; хэндл установленного клавиатурного хука, зарезервирует 8 байт
    timerId      resq 1               ; id таймера опроса процессов
    hSnap        resq 1               ; хэндл снимка списка процессов
    hVictim      resq 1               ; хэндл завершаемого процесса
    procEntry    resb PROCENTRY_SIZE  ; буфер PROCESSENTRY32

    hStdIn          resq 1            ; хэндл стандартного ввода консоли
    hStdOut         resq 1            ; хэндл стандартного вывода консоли
    hWatcherThread  resq 1            ; хэндл потока ConsoleWatcherThread
    bytesRead       resd 1            ; сколько байт реально прочитал ReadFile
    bytesWritten    resd 1            ; сколько байт реально записал WriteFile
    inputBuf        resb INPUT_BUF_SIZE  ; буфер под одну введённую строку

section .text
    global main                       ; точка входа для GoLink.exe
    global LowLevelKeyboardProc       ; экспортируемая функция хука, вызывается SetWindowsHookExA

; ------------------------------------------------------------
; main
; ------------------------------------------------------------
main:
    ; 56 байт = 32 байта "теневого пространства" (обязательны для любого
    ; вызова по соглашению Windows x64) + 16 байт под 5-й и 6-й параметры
    ; CreateThread (единственный вызов в этой функции с более чем 4
    ; параметрами - остальные вызовы используют максимум 32 байта из этого
    ; же запаса). 56 выбрано так, чтобы (RSP mod 16) оставался равным 8
    ; перед каждым call - именно этого требует соглашение вызовов x64.
    sub  rsp, 56

    call GetCurrentThreadId
    mov  [mainThreadId], eax

    ; порядок передачи аргументов в x64 Windows: 1-ый аргумент: rcx, 2-ой аргумент: rdx, 3-ий аргумент: r8, 4-ый аргумент: r9, дальше через стек (push)

    ; --- RegisterHotKey(NULL, HOTKEY_ID_PRTSCN, MOD_NOREPEAT, VK_SNAPSHOT) ---
    xor  ecx, ecx
    mov  edx, HOTKEY_ID_PRTSCN        ; ниже функция RegisterHotKey регистрирует клавишу PrintScreen без модификаторов, как глобальную горячую клавишу
    mov  r8d, MOD_NOREPEAT
    mov  r9d, VK_SNAPSHOT
    call RegisterHotKey               ; это функция WinAPI, которая регистрирует глобальную горячую клавишу, функция возвращает TRUE (1) при успехе, FALSE (0) при ошибке, результат в eax
    test eax, eax
    jnz  .prtscn_ok                   ; прыгает к метке .prtscn_ok, если eax != 0 (успех)
    lea  rcx, [dbgFmtPrt]
    call ShowRegisterFailure          ; прыгает к метке, это функция, которая показывает сообщение об ошибке регистрации горячей клавиши, передавая ей форматированную строку с кодом ошибки GetLastError, эта функция написана в этом же модуле
.prtscn_ok:

    ; --- RegisterHotKey(NULL, HOTKEY_ID_ALT_PRTSCN, MOD_ALT|MOD_NOREPEAT, VK_SNAPSHOT) ---
    xor  ecx, ecx
    mov  edx, HOTKEY_ID_ALT_PRTSCN    ; нмже функция RegisterHotKey регистрирует клвишу Alt+PrintScreen, как глобальную горячую клавишу
    mov  r8d, MOD_ALT | MOD_NOREPEAT
    mov  r9d, VK_SNAPSHOT
    call RegisterHotKey               ; это функция WinAPI, которая регистрирует глобальную горячую клавишу, функция возвращает TRUE (1) при успехе, FALSE (0) при ошибке, результат в eax
    test eax, eax
    jnz  .altprtscn_ok                ; прыгает к метке .altprtscn_ok, если eax != 0 (успех)
    lea  rcx, [dbgFmtAltPrt]
    call ShowRegisterFailure          ; прыгает к метке, это функция, которая показывает сообщение об ошибке регистрации горячей клавиши, передавая ей форматированную строку с кодом ошибки GetLastError, эта функция написана в этом же модуле
.altprtscn_ok:

    ; --- SetWindowsHookExA(WH_KEYBOARD_LL, LowLevelKeyboardProc, NULL, 0) ---
    mov  ecx, WH_KEYBOARD_LL
    lea  rdx, [LowLevelKeyboardProc]
    xor  r8d, r8d
    xor  r9d, r9d
    call SetWindowsHookExA            ; это функция WinAPI, которая устанавливает низкоуровневый клавиатурный хук, функция возвращает хэндл хука в rax, если успех, или NULL (0) при ошибке
    mov  [hHookHandle], rax
    test rax, rax
    jnz  .hook_ok
    lea  rcx, [dbgFmtHook]
    call ShowRegisterFailure          ; прыгает к метке, это функция, которая показывает сообщение об ошибке установки хука, передавая ей форматированную строку с кодом ошибки GetLastError, эта функция написана в этом же модуле
.hook_ok:

    ; --- SetTimer(NULL, 0, POLL_INTERVAL_MS, NULL) -> периодический опрос ---
    xor  ecx, ecx
    xor  edx, edx
    mov  r8d, POLL_INTERVAL_MS
    xor  r9d, r9d
    call SetTimer                     ; это функция WinAPI, которая устанавливает таймер (таймер нужен в коде для периодического опроса процессов), функция возвращает идентификатор таймера в rax, если успех, или 0 при ошибке
    mov  [timerId], rax

    ; --- напечатать в консоль подсказку про флаг безопасного завершения ---
    ; По умолчанию консоль Windows ждёт байты в своей кодовой странице
    ; (обычно OEM 866 для русской локали), а не в CP1251, в которой
    ; записан hintMsg - без этой подмены текст превращается в кракозябры
    ; (ровно то, что видно на скриншоте). SetConsoleOutputCP указывает
    ; консоли интерпретировать ВСЁ, что пишется в неё после этого вызова,
    ; как CP1251 - ту же кодировку, что и у msgTitle/msgText для MessageBoxA.
    mov  ecx, CP_1251
    call SetConsoleOutputCP

    mov  ecx, STD_OUTPUT_HANDLE
    call GetStdHandle
    mov  [hStdOut], rax

    mov  rcx, [hStdOut]
    lea  rdx, [hintMsg]
    mov  r8d, HINT_MSG_LEN
    lea  r9, [bytesWritten]
    mov  qword [rsp+32], 0            ; 5-й параметр WriteFile: lpOverlapped = NULL
    call WriteFile

    ; --- CreateThread(NULL, 0, ConsoleWatcherThread, NULL, 0, NULL) ---
    ; запускаем поток, который будет слушать консоль и ждать флаг STOP,
    ; параллельно с тем, как главный поток крутит цикл сообщений ниже
    xor  ecx, ecx                     ; lpThreadAttributes = NULL
    xor  edx, edx                     ; dwStackSize = 0 (по умолчанию)
    lea  r8, [ConsoleWatcherThread]   ; lpStartAddress
    xor  r9d, r9d                     ; lpParameter = NULL (потоку ничего не передаём)
    mov  qword [rsp+32], 0            ; 5-й параметр: dwCreationFlags = 0 (запустить сразу)
    mov  qword [rsp+40], 0            ; 6-й параметр: lpThreadId = NULL (id потока не нужен)
    call CreateThread                 ; возвращает хэндл потока в rax, или NULL при ошибке
    mov  [hWatcherThread], rax

.msgloop:
    lea  rcx, [msgStruct]             ; msgStruct - это структура MSG, которая будет использоваться для извлечения сообщений из очереди сообщений текущего потока
    xor  edx, edx
    xor  r8d, r8d
    xor  r9d, r9d
    call GetMessageA                  ; это функция WinAPI, которая извлекает сообщение из очереди сообщений текущего потока, функция возвращает значение в eax: > 0 если сообщение получено, 0 если WM_QUIT, < 0 если ошибка

    cmp  eax, 0
    je   .done
    cmp  eax, -1
    je   .msgloop

    mov  eax, [msgStruct+8]           ; MSG.message
    cmp  eax, WM_HOTKEY
    je   .showWarning                 ; если сообщение является горячей клавишей, то прыгаем к метке .showWarning, чтобы показать предупреждение
    cmp  eax, WM_APP_BLOCKED
    je   .showWarning
    cmp  eax, WM_TIMER
    je   .onTimer
    jmp  .msgloop

.showWarning:                         ; показывает предупреждение о том, что скриншот заблокирован
    xor  ecx, ecx
    lea  rdx, [msgText]
    lea  r8,  [msgTitle]
    mov  r9d, MB_OK | MB_ICONWARNING | MB_SYSTEMMODAL
    call MessageBoxA                  ; это функция WinAPI, которая показывает модальное окно с сообщением, передавая заголовок, текст и стиль окна
    jmp  .msgloop

.onTimer:
    call ScanAndKillScreenshotTools   ; это функция, которая сканирует список процессов и завершает процессы, которые считаются инструментами скриншота (например, Snipping Tool), вызывается при получении сообщения WM_TIMER
    jmp  .msgloop

.done:
    mov  ecx, HOTKEY_ID_PRTSCN    
    call UnregisterHotKey
    mov  ecx, HOTKEY_ID_ALT_PRTSCN
    call UnregisterHotKey             ; функция UnregisterHotKey удаляет регистрацию горячей клавиши, передавая идентификатор горячей клавиши, удаление регистрации горячей клавиши необходимо для корректного завершения программы
    mov  rcx, [hHookHandle]
    test rcx, rcx
    jz   .skipUnhook
    call UnhookWindowsHookEx
.skipUnhook:

    xor  ecx, ecx
    mov  rdx, [timerId]
    call KillTimer                    ; это функция WinAPI, которая останавливает таймер, передавая идентификатор таймера, таймер нужен для периодического опроса процессов, поэтому его нужно остановить перед завершением программы

    ; поток ConsoleWatcherThread к этому моменту уже сделал своё дело
    ; (это он прислал WM_QUIT) и больше не нужен; ExitProcess ниже всё
    ; равно немедленно завершит все потоки процесса, но закрыть хэндл -
    ; хороший тон (освобождаем объект ядра, а не сам поток - поток как
    ; исполнение уже выполнил свою задачу)
    mov  rcx, [hWatcherThread]
    test rcx, rcx
    jz   .skipCloseWatcher
    call CloseHandle
.skipCloseWatcher:

    xor  ecx, ecx
    call ExitProcess                  ; это функция WinAPI, которая завершает процесс, передавая код выхода (0), завершение процесса необходимо для корректного завершения программы


ShowRegisterFailure:
    push rbx
    sub  rsp, 32
    mov  rbx, rcx                     ; сохранить указатель на формат

    call GetLastError
    mov  r8d, eax
    lea  rcx, [dbgBuf]
    mov  rdx, rbx
    call wsprintfA

    xor  ecx, ecx
    lea  rdx, [dbgBuf]
    lea  r8,  [dbgTitle]
    mov  r9d, MB_OK | MB_ICONWARNING
    call MessageBoxA                   ; это функция WinAPI, которая показывает модальное окно с сообщением, передавая заголовок, текст и стиль окна

    add  rsp, 32
    pop  rbx
    ret

; ------------------------------------------------------------
; LowLevelKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam)
;   rcx=nCode  rdx=wParam  r8=lParam -> KBDLLHOOKSTRUCT*
;
; Ловит и "глотает" (return 1, без CallNextHookEx):
;   - S при зажатых Win+Shift   (Ножницы)
;   - PrintScreen при зажатом Win, с Alt или без  (сохранение
;     в файл И Xbox Game Bar - оба идут через один и тот же
;     код ниже, т.к. в обоих случаях Win обязательно зажат)
; ------------------------------------------------------------
LowLevelKeyboardProc:                  ; функция хука клавиатуры, вызывается системой при каждом нажатии клавиши
    push rbx
    push rsi
    push rdi
    sub  rsp, 32

    mov  rbx, rcx                      ; nCode
    mov  rsi, rdx                      ; wParam
    mov  rdi, r8                       ; lParam -> KBDLLHOOKSTRUCT*

    cmp  ebx, HC_ACTION
    jne  .passthrough                  ; если nCode != HC_ACTION, то прыгаем к метке .passthrough, чтобы передать управление следующему хуку в цепочке, где HC_ACTION - код, который указывает, что нужно обработать сообщение о нажатии клавиши

    mov  eax, esi
    cmp  eax, WM_KEYDOWN
    je   .checkkey                     ; если wParam == WM_KEYDOWN, то прыгаем к метке .checkkey, чтобы проверить, какая клавиша была нажата, где WM_KEYDOWN - это сообщение о нажатии клавиши
    cmp  eax, WM_SYSKEYDOWN           
    je   .checkkey
    jmp  .passthrough

.checkkey:
    mov  eax, [rdi]                    ; KBDLLHOOKSTRUCT.vkCode (первое поле)
    cmp  eax, VK_S_KEY
    je   .maybeWinShiftS               ; если нажата клавиша S, то прыгаем к метке .maybeWinShiftS, чтобы проверить, зажаты ли Win и Shift
    cmp  eax, VK_SNAPSHOT
    je   .maybeWinPrtScn               ; если нажата клавиша PrintScreen, то прыгаем к метке .maybeWinPrtScn, чтобы проверить, зажат ли Win
    jmp  .passthrough                  ; если нажата любая другая клавиша, то прыгаем к метке .passthrough, чтобы передать управление следующему хуку в цепочке

.maybeWinShiftS:                       ; этот кусок кода проверяет, зажаты ли клавиши Win и Shift при нажатии клавиши S
    mov  ecx, VK_LWIN
    call GetAsyncKeyState
    test ax, 0x8000
    jnz  .wss_winIsDown
    mov  ecx, VK_RWIN
    call GetAsyncKeyState
    test ax, 0x8000
    jz   .passthrough
.wss_winIsDown:                        ; если зажат Win, проверяем Shift
    mov  ecx, VK_SHIFT_KEY
    call GetAsyncKeyState
    test ax, 0x8000
    jz   .passthrough
    jmp  .suppressAndNotify            ; если зажаты Win и Shift, то прыгаем к метке .suppressAndNotify, чтобы подавить нажатие клавиши S и показать уведомление

.maybeWinPrtScn:
    mov  ecx, VK_LWIN
    call GetAsyncKeyState              ; проверяем, зажат ли левый Win
    test ax, 0x8000
    jnz  .suppressAndNotify
    mov  ecx, VK_RWIN
    call GetAsyncKeyState
    test ax, 0x8000
    jz   .passthrough
    jmp  .suppressAndNotify

.suppressAndNotify:                    ; если нажата запрещённая комбинация клавиш, то отправляем сообщение главному потоку, чтобы показать предупреждение
    mov  ecx, [mainThreadId]
    mov  edx, WM_APP_BLOCKED
    xor  r8d, r8d
    xor  r9d, r9d
    call PostThreadMessageA            ; это функция WinAPI, которая отправляет сообщение в очередь сообщений указанного потока, передавая идентификатор потока, сообщение и параметры сообщения

    mov  eax, 1
    jmp  .hookdone

.passthrough:
    xor  ecx, ecx
    movsxd rdx, ebx
    mov  r8, rsi
    mov  r9, rdi
    call CallNextHookEx

.hookdone:
    add  rsp, 32
    pop  rdi
    pop  rsi
    pop  rbx
    ret


ScanAndKillScreenshotTools:            ; эта функция сканирует список процессов и завершает процессы, которые считаются инструментами скриншота (например, Snipping Tool)
    sub  rsp, 40

    mov  ecx, TH32CS_SNAPPROCESS
    xor  edx, edx
    call CreateToolhelp32Snapshot      ; это функция WinAPI, которая создаёт снимок текущих процессов в системе, передавая флаги и идентификатор процесса (0 для всех процессов), функция возвращает хэндл снимка в rax, или INVALID_HANDLE_VALUE (-1) при ошибке
    cmp  rax, -1
    je   .scanDone                     ; если CreateToolhelp32Snapshot вернул INVALID_HANDLE_VALUE, то прыгаем к метке .scanDone, чтобы завершить функцию, т.к. не удалось получить список процессов
    mov  [hSnap], rax

    mov  dword [procEntry], PROCENTRY_SIZE  
    mov  rcx, [hSnap]
    lea  rdx, [procEntry]
    call Process32First                ; это функция WinAPI, которая получает информацию о первом процессе в снимке процессов, передавая хэндл снимка и указатель на структуру PROCESSENTRY32, функция возвращает TRUE (1) при успехе, FALSE (0) при ошибке
    test eax, eax
    jz   .closeSnap                    ; если Process32First вернул FALSE, то прыгаем к метке .closeSnap, чтобы закрыть хэндл снимка и завершить функцию, т.к. не удалось получить информацию о первом процессе

.loopNext:
    lea  rcx, [procEntry + PROCENTRY_EXE_OFF]
    lea  rdx, [nameSnippingTool]
    call lstrcmpiA                     ; это функция WinAPI, которая сравнивает две строки без учёта регистра, возвращая 0 при совпадении
    test eax, eax
    jz   .killIt                       ; если lstrcmpiA вернул 0, то прыгаем к метке .killIt, чтобы завершить процесс Snipping Tool

    lea  rcx, [procEntry + PROCENTRY_EXE_OFF]
    lea  rdx, [nameScreenSketch]
    call lstrcmpiA                     ; это функция WinAPI, которая сравнивает две строки без учёта регистра, возвращая 0 при совпадении
    test eax, eax
    jz   .killIt

    lea  rcx, [procEntry + PROCENTRY_EXE_OFF]
    lea  rdx, [nameScreenClipHost1]
    call lstrcmpiA
    test eax, eax
    jz   .killIt

    lea  rcx, [procEntry + PROCENTRY_EXE_OFF]
    lea  rdx, [nameScreenClipHost2]
    call lstrcmpiA
    test eax, eax
    jnz  .getNext

.killIt:
    mov  ecx, PROCESS_TERMINATE
    xor  edx, edx
    mov  r8d, [procEntry + PROCENTRY_PID_OFF]
    call OpenProcess
    test rax, rax
    jz   .getNext
    mov  [hVictim], rax

    mov  rcx, rax
    mov  edx, 1
    call TerminateProcess

    mov  rcx, [hVictim]
    call CloseHandle

    ; показать то же предупреждение, что и для клавиш
    mov  ecx, [mainThreadId]
    mov  edx, WM_APP_BLOCKED
    xor  r8d, r8d
    xor  r9d, r9d
    call PostThreadMessageA

.getNext:
    mov  rcx, [hSnap]
    lea  rdx, [procEntry]
    call Process32Next
    test eax, eax
    jnz  .loopNext

.closeSnap:
    mov  rcx, [hSnap]
    call CloseHandle

.scanDone:
    add  rsp, 40
    ret

; ------------------------------------------------------------
; ConsoleWatcherThread(LPVOID lpParameter)  -- rcx = lpParameter (не используем)
;
; Работает в ОТДЕЛЬНОМ потоке (создан через CreateThread в main),
; параллельно главному циклу сообщений. В бесконечном цикле читает
; строки из консоли (ReadFile на STD_INPUT_HANDLE) и сравнивает
; каждую введённую строку (без учёта регистра, через lstrcmpiA) с
; exitFlag ("STOP"). При совпадении посылает главному потоку
; WM_QUIT через PostThreadMessageA - это и есть "безопасное
; завершение по флагу из терминала": основной цикл получает
; WM_QUIT, GetMessageA возвращает 0, и main идёт по ветке .done,
; которая корректно снимает все хоткеи/хук/таймер перед выходом.
; ------------------------------------------------------------
ConsoleWatcherThread:
    sub  rsp, 56                       ; тот же запас, что и в main - на случай вызовов с 2 параметрами в стеке

    mov  ecx, STD_INPUT_HANDLE
    call GetStdHandle
    mov  [hStdIn], rax

.readLoop:
    ; ReadFile(hStdIn, inputBuf, INPUT_BUF_SIZE-1, &bytesRead, NULL)
    ; БЛОКИРУЕТ этот поток до тех пор, пока пользователь не нажмёт Enter
    ; в консоли - именно поэтому это обязательно должен быть отдельный
    ; поток, а не часть главного цикла сообщений
    mov  rcx, [hStdIn]
    lea  rdx, [inputBuf]
    mov  r8d, INPUT_BUF_SIZE - 1       ; оставляем место под завершающий 0
    lea  r9, [bytesRead]
    mov  qword [rsp+32], 0             ; 5-й параметр ReadFile: lpOverlapped = NULL
    call ReadFile
    test eax, eax
    jz   .watcherDone                  ; ReadFile вернул ошибку -> прекращаем слежение

    mov  eax, [bytesRead]
    cmp  eax, 0
    je   .watcherDone                  ; 0 байт = конец ввода (stdin закрыт/EOF) -> прекращаем

    mov  byte [inputBuf + rax], 0      ; закрываем прочитанную строку нулём

    ; обрезаем завершающие \r и/или \n (ReadFile их не убирает сам)
    mov  ecx, [bytesRead]
.trimBack:
    cmp  ecx, 0
    je   .trimDone
    movzx eax, byte [inputBuf + rcx - 1]
    cmp  al, 13                        ; '\r'
    je   .trimChar
    cmp  al, 10                        ; '\n'
    je   .trimChar
    jmp  .trimDone
.trimChar:
    mov  byte [inputBuf + rcx - 1], 0
    dec  ecx
    jmp  .trimBack
.trimDone:

    ; приводим введённую строку к верхнему регистру побайтово, чтобы
    ; "stop", "Stop", "StOp" и т.д. - всё засчитывалось так же, как "STOP"
    xor  ecx, ecx                      ; ecx = индекс текущего байта
.upperLoop:
    movzx eax, byte [inputBuf + rcx]
    test al, al
    jz   .upperDone                    ; дошли до конца строки (нулевой байт)
    cmp  al, 'a'
    jb   .upperNext
    cmp  al, 'z'
    ja   .upperNext
    sub  al, 0x20                      ; 'a'..'z' -> 'A'..'Z' (разница ровно 0x20)
    mov  byte [inputBuf + rcx], al
.upperNext:
    inc  ecx
    jmp  .upperLoop
.upperDone:

    ; сравниваем уже приведённую к верхнему регистру строку с флагом
    lea  rcx, [inputBuf]
    lea  rdx, [exitFlag]
    call lstrcmpiA
    test eax, eax
    jnz  .readLoop                     ; не совпало -> ждём следующую строку

    ; совпало -> просим главный поток выйти штатным путём
    mov  ecx, [mainThreadId]
    mov  edx, WM_QUIT
    xor  r8d, r8d
    xor  r9d, r9d
    call PostThreadMessageA
    ; дальше просто завершаем сам поток-наблюдатель; .done в main
    ; выполнится, когда главный поток обработает WM_QUIT

.watcherDone:
    add  rsp, 56
    xor  eax, eax                      ; код возврата потока (не используется)
    ret

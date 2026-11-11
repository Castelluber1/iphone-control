# iphone-control.ps1 - Etapa 3: a janela "AirPlay Video Stream" (uxplay-windows) vira tela de toque do iPhone.
# Windows PowerShell 5.1 + WinRT + Win32 (C# inline via Add-Type). Nada instalado.
#
# O PC se apresenta ao iPhone como UM aparelho BLE HID composto:
#   Report ID 1 = teclado (igual ao ble-keyboard-testble-keyboard.ps1)
#   Report ID 2 = ponteiro ABSOLUTO 0..32767 (padrao) ou mouse relativo (-Relative)
#   Report ID 3 = consumer control (Home = 0x0040)
# Mudou o descritor -> no iPhone: Esquecer este dispositivo e parear de novo (o iOS guarda o Report Map antigo).
#
# Uso (a partir da raiz do workspace):
#   powershell -ExecutionPolicy Bypass -File .\iphone-control.ps1
#   ... -SelfTest              testa tudo o que da sem iPhone (nao anuncia, nao segura teclado/mouse)
#   ... -SelfTestAdvertise     idem + anuncia o servico BLE por 5 s
#   ... -Screenshot            salva so a area de video da janela em .tmp\screen.png
#   ... -Send "tap 0.5 0.5"    manda um comando para o app rodando (canal local 127.0.0.1)
#   ... -Relative              mouse relativo (plano B, precisa calibrar -RelWidth/-RelHeight)
#   ... -Headless              sem console: comandos so pelo canal local (usado pelo painel iPhoneControl.exe); 'quit' encerra
#
# Com o app rodando:
#   clique/arraste na janela do espelho = toque/arraste no iPhone; roda do mouse = rolagem
#   janela do espelho em foco = o teclado do PC digita no iPhone (Ctrl+letra vira Cmd+letra)
#   Ctrl+V = digita o clipboard do PC no iPhone (quebra de linha vira espaco; -PasteNewlines mantem = Enter)
#   Ctrl+Shift+V = Cmd+V (cola o clipboard do proprio iPhone)
#   Ctrl+Shift+F12 = liga/desliga a captura (de qualquer janela)
#   Ctrl+Shift+F11 = janela do espelho sempre no topo (liga/desliga)
#   Ctrl+Shift+F10 = afixar o espelho na altura da tela (liga/desliga; padrao ligado, -NoFit desliga)
#   Esc durante um Ctrl+V longo = cancela a digitacao | Esc fora disso = voltar (toca no "<" do canto, -BackX/-BackY)
#   Ctrl+Shift+1..9 = digita a resposta pronta N do respostas.txt (nunca aperta Enter) | Ctrl+Shift+S = roda o sugerir.ps1
#   chip CONTROLE LIGADO/DESLIGADO na barra de titulo do espelho
#   No console: mesmos comandos do canal local (ver HandleCommand), texto solto = digitar, q = sair
param(
    [switch]$SelfTest, [switch]$SelfTestAdvertise,
    [switch]$Screenshot, [string]$ScreenshotPath = '',
    [string]$Send = '',
    [switch]$Relative, [int]$RelWidth = 0, [int]$RelHeight = 0, [int]$RelStep = 10,
    [int]$Port = 47380,
    [switch]$PasteNewlines, [int]$PasteMax = 4000,    # colar: por padrao quebra de linha vira espaco (Enter envia no WhatsApp)
    [double]$ScrollStep = 0.18, [int]$ScrollMs = 400,   # roda do mouse = swipe: fracao da altura por tick, duracao do swipe
    [int]$WheelUnits = 6,                              # rodinha: unidades de roda HID enviadas ao iPhone por clique da rodinha do PC
    [int]$WheelThreshold = 40,                         # rodinha: soma de delta para o 1o tick de uma rajada (depois 1 tick a cada 120)
    [double]$VideoAspect = 0,
    [switch]$NoFit,                                    # nao encaixar a janela do espelho na altura util da tela
    [int]$KeyDelayMs = 12,                             # pausa apos apertar e apos soltar cada tecla (12 = valor testado; menor = mais rapido)
    [double]$BackX = 0.05, [double]$BackY = 0.077,     # 'voltar' / Esc: toque no botao "<" do canto superior esquerdo (retrato)
    [string]$WindowTitle = 'AirPlay Video Stream',
    [switch]$Headless                                  # sem ler o console (painel iPhoneControl.exe); comandos so pelo canal local
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tmpDir = Join-Path $here '.tmp'
if ($ScreenshotPath -eq '') { $ScreenshotPath = Join-Path $tmpDir 'screen.png' }

# ======================================================================================================
# Cliente do canal local (-Send): nao precisa de Bluetooth
# ======================================================================================================
if ($Send -ne '') {
    $wc = New-Object System.Net.WebClient
    $wc.Proxy = $null
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers.Add('X-iPhone-Control', '1')
    $wc.Headers.Add('Content-Type', 'text/plain; charset=utf-8')
    try { $wc.UploadString("http://127.0.0.1:$Port/", 'POST', $Send) }
    catch { Write-Host "ERRO: $($_.Exception.Message) (o iphone-control.ps1 esta rodando?)" -ForegroundColor Red; exit 1 }
    exit 0
}

# ======================================================================================================
# Win32: hooks de mouse/teclado, geometria da janela, screenshot, servidor HTTP em 127.0.0.1
# ======================================================================================================
$cs = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class IPC {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct MSLL { public POINT pt; public uint mouseData, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct KBLL { public uint vk, scan, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr w, l; public uint time; public POINT pt; }
    delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);

    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc p, IntPtr mod, uint tid);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int c, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] static extern bool PostThreadMessage(uint tid, uint msg, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string c, string t);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint tid);
    [DllImport("user32.dll")] static extern short GetKeyState(int vk);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ToUnicodeEx(uint vk, uint scan, byte[] state, StringBuilder buf, int n, uint flags, IntPtr hkl);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();

    public static string Title = "AirPlay Video Stream";
    public static volatile bool Enabled = true;
    public static double VideoAspect = 0;           // largura/altura do video; 0 = ocupa a area cliente toda
    public static ConcurrentQueue<string> Events = new ConcurrentQueue<string>();
    public static string HookStatus = "parado";
    // Acorda o loop do PowerShell na hora (em vez de esperar o proximo ciclo de polling).
    public static AutoResetEvent Wake = new AutoResetEvent(false);
    static void Push(string e) { Events.Enqueue(e); Wake.Set(); }
    // iPhone inscrito (atualizado pelo PowerShell). Sem iPhone, a roda do mouse passa para o Windows.
    public static volatile bool Connected = false;
    // Timer do Windows em 1 ms: sem isso Start-Sleep 5 dura ~15,6 ms (medido 2026-11-10).
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint p);
    [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint p);
    public static void FastTimer(bool on) { try { if (on) timeBeginPeriod(1); else timeEndPeriod(1); } catch (Exception) { } }

    // ---------------- DPI: coordenadas fisicas, iguais as do hook ----------------
    public static string InitDpi() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return "PerMonitorV2"; } catch (Exception) { }
        try { if (SetProcessDPIAware()) return "SystemAware"; } catch (Exception) { }
        return "nao alterado";
    }

    // ---------------- janela e area de video ----------------
    static IntPtr hwnd = IntPtr.Zero;
    public static IntPtr Window() {
        IntPtr h = hwnd;
        if (h == IntPtr.Zero || !IsWindow(h)) { h = FindWindow(null, Title); hwnd = h; }
        return h;
    }
    public static IntPtr ConsoleWindow() { return GetConsoleWindow(); }

    // Retangulo do video dentro da area cliente (w x h), centralizado, com a proporcao 'aspect' (0 = tudo).
    public static int[] ComputeVideoRect(int w, int h, double aspect) {
        int x = 0, y = 0, vw = w, vh = h;
        if (aspect > 0 && w > 0 && h > 0) {
            if ((double)w / h > aspect) { vw = (int)Math.Round(h * aspect); x = (w - vw) / 2; }
            else { vh = (int)Math.Round(w / aspect); y = (h - vh) / 2; }
        }
        return new int[] { x, y, vw, vh };
    }
    public static bool ClientScreen(IntPtr h, out RECT c) {
        c = new RECT();
        if (h == IntPtr.Zero || IsIconic(h)) return false;
        RECT r; if (!GetClientRect(h, out r)) return false;
        POINT p = new POINT(); if (!ClientToScreen(h, ref p)) return false;
        if (r.R < 10 || r.B < 10) return false;
        c.L = p.X; c.T = p.Y; c.R = p.X + r.R; c.B = p.Y + r.B;
        return true;
    }
    public static bool VideoRect(IntPtr h, out RECT v) {
        v = new RECT();
        RECT c; if (!ClientScreen(h, out c)) return false;
        int[] q = ComputeVideoRect(c.R - c.L, c.B - c.T, VideoAspect);
        v.L = c.L + q[0]; v.T = c.T + q[1]; v.R = v.L + q[2]; v.B = v.T + q[3];
        return true;
    }
    public static string Describe() {
        IntPtr h = Window();
        if (h == IntPtr.Zero) return "janela '" + Title + "' nao encontrada";
        RECT c, v;
        if (!ClientScreen(h, out c) || !VideoRect(h, out v)) return "janela minimizada ou sem area cliente";
        return string.Format("cliente {0}x{1} em ({2},{3}); video {4}x{5} em ({6},{7}); proporcao {8}",
            c.R - c.L, c.B - c.T, c.L, c.T, v.R - v.L, v.B - v.T, v.L, v.T,
            VideoAspect > 0 ? VideoAspect.ToString("0.0000", CultureInfo.InvariantCulture) : "cheia");
    }
    static bool Inside(RECT r, POINT p) { return p.X >= r.L && p.X < r.R && p.Y >= r.T && p.Y < r.B; }
    static string Norm(RECT r, POINT p) {
        double u = (p.X - r.L + 0.5) / (double)(r.R - r.L), v = (p.Y - r.T + 0.5) / (double)(r.B - r.T);
        u = Math.Max(0, Math.Min(1, u)); v = Math.Max(0, Math.Min(1, v));
        return u.ToString("0.00000", CultureInfo.InvariantCulture) + " " + v.ToString("0.00000", CultureInfo.InvariantCulture);
    }

    // ---------------- hooks ----------------
    static HookProc mouseProc, keyProc;
    static uint hookTid;
    static volatile bool dragging = false, passThrough = false;
    static bool lshift, rshift, lctrl, rctrl, lalt, ralt, lwin, rwin;
    // "dedo preso": o soltar (WM_LBUTTONUP) pode se perder (Win+L, UAC, hook atrasado). StuckCheck solta sozinho.
    static readonly object dragLock = new object();
    static int dragStartTick, dragEvtTick, stuckUpCount;
    public static bool Dragging { get { return dragging; } }
    // Chamado a cada 200 ms (thread do indicador). GetAsyncKeyState so vale quando o clique PASSOU para o Windows:
    // clique engolido pelo hook nao atualiza o estado assincrono do botao, entao ai vale o foco e o tempo sem movimento.
    public static void StuckCheck() {
        if (!dragging) return;
        lock (dragLock) {
            if (!dragging) return;
            int now = Environment.TickCount; string why = null;
            IntPtr h = Window();
            if (h == IntPtr.Zero) why = "janela do espelho sumiu";
            else if (passThrough) {
                if (now - dragStartTick > 300) {
                    if ((GetAsyncKeyState(0x01) & 0x8000) == 0) { if (++stuckUpCount >= 2) why = "botao fisico ja solto"; }
                    else stuckUpCount = 0;
                }
            } else if (now - dragStartTick > 600 && GetForegroundWindow() != h) why = "foco saiu do espelho (Win+L, UAC ou troca de janela)";
            if (why == null && now - dragEvtTick > 15000) why = "15 s sem movimento com o dedo encostado";
            if (why != null) { dragging = false; Push("stuck " + why); Push("up "); }
        }
    }

    public static void StartHooks() {
        Thread t = new Thread(HookLoop); t.IsBackground = true; t.Start();
        for (int i = 0; i < 100 && HookStatus == "parado"; i++) Thread.Sleep(10);
    }
    public static void StopHooks() { if (hookTid != 0) PostThreadMessage(hookTid, 0x0012, IntPtr.Zero, IntPtr.Zero); }
    static void HookLoop() {
        hookTid = GetCurrentThreadId();
        mouseProc = MouseProc; keyProc = KeyProc;
        IntPtr mod = GetModuleHandle(null);
        IntPtr mh = SetWindowsHookEx(14, mouseProc, mod, 0);
        int e1 = Marshal.GetLastWin32Error();
        IntPtr kh = SetWindowsHookEx(13, keyProc, mod, 0);
        int e2 = Marshal.GetLastWin32Error();
        HookStatus = (mh != IntPtr.Zero ? "mouse ok" : "mouse FALHOU (" + e1 + ")") + ", " + (kh != IntPtr.Zero ? "teclado ok" : "teclado FALHOU (" + e2 + ")");
        MSG m;
        while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
        if (mh != IntPtr.Zero) UnhookWindowsHookEx(mh);
        if (kh != IntPtr.Zero) UnhookWindowsHookEx(kh);
        HookStatus = "parado";
    }

    static int lastHoverTick = -100000;
    static IntPtr MouseProc(int code, IntPtr w, IntPtr l) {
        try {
            if (code >= 0) {
                int msg = w.ToInt32();
                MSLL m = (MSLL)Marshal.PtrToStructure(l, typeof(MSLL));
                bool injected = (m.flags & 1) != 0;
                RECT v;
                if (msg == 0x020A) return WheelProc(code, w, l, m, injected);
                lock (dragLock) {
                    if (dragging && msg == 0x0201 && !injected) {   // clique novo com o dedo ainda encostado: o soltar anterior se perdeu
                        dragging = false; Push("stuck clique novo com o dedo ainda encostado"); Push("up ");
                    }
                    if (dragging) {
                        if (msg == 0x0200) {                     // arrastando: move (o cursor do Windows anda normal)
                            dragEvtTick = Environment.TickCount;
                            if (VideoRect(Window(), out v)) Push("move " + Norm(v, m.pt));
                        } else if (msg == 0x0202) {              // soltou
                            dragging = false;
                            Push("up " + (VideoRect(Window(), out v) ? Norm(v, m.pt) : ""));
                            if (!passThrough) return new IntPtr(1);
                        }
                    } else if (Enabled && !injected && msg == 0x0200 && Environment.TickCount - lastHoverTick >= 30) {
                        // passando o mouse por cima do espelho: o ponteiro do iPhone acompanha (sem botao), assim o
                        // clique ja encontra o ponteiro no lugar certo e nao cai onde ele estava antes
                        IntPtr h = Window();
                        if (h != IntPtr.Zero && VideoRect(h, out v) && Inside(v, m.pt) && GetAncestor(WindowFromPoint(m.pt), 2) == h) {
                            lastHoverTick = Environment.TickCount;
                            Push("hover " + Norm(v, m.pt));
                        }
                    } else if (Enabled && !injected && msg == 0x0201) {
                        IntPtr h = Window();
                        if (h != IntPtr.Zero && VideoRect(h, out v) && Inside(v, m.pt) && GetAncestor(WindowFromPoint(m.pt), 2) == h) {
                            dragging = true; dragStartTick = dragEvtTick = Environment.TickCount; stuckUpCount = 0;
                            // janela sem foco: o 1o clique tambem passa para ela, assim ela ganha o foco do teclado
                            passThrough = GetForegroundWindow() != h;
                            Push("down " + Norm(v, m.pt));
                            if (!passThrough) return new IntPtr(1);
                        }
                    }
                }
            }
        } catch (Exception) { }
        return CallNextHookEx(IntPtr.Zero, code, w, l);
    }

    // Rodinha: sem exigir "Connected" (era a regressao: com ele falso a rodinha passava para o Windows e o iPhone nao rolava;
    // sem iPhone o PowerShell so ignora e avisa). Aceita rodinha injetada (driver de mouse com rolagem suave injeta).
    // Rodinha de alta resolucao manda deltas pequenos (medido: -13, 26). Por rajada (mesmo sentido, pausa < 1000 ms) soma os
    // deltas: o 1o tick sai quando |soma| >= WheelThreshold (padrao 40) e depois 1 tick a cada 120 a mais, entao um clique
    // normal (120) continua = 1 tick e uma rajada lenta de deltas pequenos rola ao menos 1 vez por ~120 somado.
    // Diagnostico: 1 linha por rajada (recebida, injetada?, motivo se ignorada).
    public static int WheelThreshold = 40;
    static int wheelSum = 0, wheelSent = 0, lastWheelTick = -100000;
    static IntPtr WheelProc(int code, IntPtr w, IntPtr l, MSLL m, bool injected) {
        int now = Environment.TickCount;
        int delta = (short)((m.mouseData >> 16) & 0xFFFF);
        bool newBurst = now - lastWheelTick > 1500;
        string why = null; RECT v = new RECT(); IntPtr h = Window();
        if (!Enabled) why = "captura desligada";
        else if (dragging) why = "arrastando";
        else if (h == IntPtr.Zero) why = "janela '" + Title + "' nao encontrada";
        else if (!VideoRect(h, out v)) why = "area de video desconhecida";
        else {
            // basta o cursor estar sobre a janela do espelho: a conta de "dentro do video" falhava (log: "fora da area de video")
            // com o cursor em cima do espelho; a posicao do swipe e limitada a faixa segura depois
            IntPtr under = GetAncestor(WindowFromPoint(m.pt), 2);
            if (under != h && under != chipHwnd) why = "cursor fora do espelho (" + ProcOf(under) + ")";
        }
        if (newBurst) Push("wheeldiag Rodinha: delta " + delta + (injected ? " (injetada)" : "") + (why == null ? " -> rola o iPhone" : " -> IGNORADA: " + why) + " | iPhone inscrito=" + (Connected ? "sim" : "nao"));
        if (why != null) { lastWheelTick = now; return CallNextHookEx(IntPtr.Zero, code, w, l); }
        if (now - lastWheelTick > 1000 || (wheelSum != 0 && (delta > 0) != (wheelSum > 0))) { wheelSum = 0; wheelSent = 0; }   // pausa ou mudou o sentido
        lastWheelTick = now;
        wheelSum += delta;
        int abs = Math.Abs(wheelSum), th = Math.Max(1, Math.Min(120, WheelThreshold));
        int want = abs >= th ? 1 + (abs - th) / 120 : 0;
        if (want > wheelSent) { int ticks = (want - wheelSent) * Math.Sign(wheelSum); wheelSent = want; Push("wheel " + ticks + " " + Norm(v, m.pt)); }
        return new IntPtr(1);
    }

    static int SpecialUsage(uint vk) {
        switch (vk) {
            case 0x0D: return 0x28; case 0x1B: return 0x29; case 0x08: return 0x2A; case 0x09: return 0x2B;
            case 0x2E: return 0x4C; case 0x27: return 0x4F; case 0x25: return 0x50; case 0x28: return 0x51; case 0x26: return 0x52;
            case 0x24: return 0x4A; case 0x23: return 0x4D; case 0x21: return 0x4B; case 0x22: return 0x4E;
        }
        return 0;
    }
    static int LetterDigitUsage(uint vk) {
        if (vk >= 0x41 && vk <= 0x5A) return 4 + (int)(vk - 0x41);
        if (vk >= 0x31 && vk <= 0x39) return 0x1E + (int)(vk - 0x31);
        if (vk == 0x30) return 0x27;
        return 0;
    }
    static bool IsModifier(uint vk) {
        return (vk >= 0xA0 && vk <= 0xA5) || vk == 0x10 || vk == 0x11 || vk == 0x12 || vk == 0x5B || vk == 0x5C || vk == 0x14 || vk == 0x90 || vk == 0x91;
    }
    public static string Translate(uint vk, uint scan, bool shift, bool altgr, IntPtr hkl) {
        byte[] ks = new byte[256];
        if (shift) { ks[0x10] = 0x80; ks[0xA0] = 0x80; }
        if (altgr) { ks[0x11] = 0x80; ks[0x12] = 0x80; ks[0xA2] = 0x80; ks[0xA5] = 0x80; }
        if ((GetKeyState(0x14) & 1) != 0) ks[0x14] = 0x01;
        StringBuilder sb = new StringBuilder(8);
        int n = ToUnicodeEx(vk, scan, ks, sb, 8, 0, hkl);
        if (n <= 0) return "";                               // -1 = tecla morta (acento), espera a proxima
        StringBuilder o = new StringBuilder();
        for (int i = 0; i < n && i < sb.Length; i++) if (sb[i] >= 0x20) o.Append(sb[i]);
        return o.ToString();
    }
    public static IntPtr LayoutOf(IntPtr h) { return GetKeyboardLayout(GetWindowThreadProcessId(h, IntPtr.Zero)); }

    // ---------------- clipboard do Windows (Win32 direto: nao depende de thread STA) ----------------
    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr h);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint f);
    [DllImport("user32.dll")] static extern bool IsClipboardFormatAvailable(uint f);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr h);
    [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr h);
    [DllImport("user32.dll")] static extern uint EnumClipboardFormats(uint f);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClipboardFormatName(uint f, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormat(string n);
    [DllImport("user32.dll")] static extern IntPtr GetOpenClipboardWindow();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardOwner();
    [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")] static extern uint GetWindowPid(IntPtr h, out uint pid);
    public static string ClipboardInfo = "";                // de onde veio o texto, ou por que nao veio
    static string ProcOf(IntPtr h) {
        if (h == IntPtr.Zero) return "?";
        try { uint pid; GetWindowPid(h, out pid); return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch (Exception) { return "?"; }
    }
    static string ListFormats() {                          // so com o clipboard aberto
        StringBuilder o = new StringBuilder(); uint f = 0; int n = 0;
        while ((f = EnumClipboardFormats(f)) != 0 && n < 30) {
            StringBuilder nm = new StringBuilder(128);
            string name = f >= 0xC000 && GetClipboardFormatName(f, nm, 128) > 0 ? nm.ToString() : "#" + f;
            if (o.Length > 0) o.Append(", "); o.Append(name); n++;
        }
        return o.Length > 0 ? o.ToString() : "(vazio)";
    }
    static string ReadGlobalUni(IntPtr h) {
        IntPtr p = GlobalLock(h); if (p == IntPtr.Zero) return null;
        try {
            long chars = (long)(GlobalSize(h).ToUInt64() / 2);
            if (chars <= 0) return "";
            string s = Marshal.PtrToStringUni(p, (int)Math.Min(chars, 4L * 1024 * 1024));
            int z = s.IndexOf('\0'); return z >= 0 ? s.Substring(0, z) : s;
        } finally { GlobalUnlock(h); }
    }
    static byte[] ReadGlobalBytes(IntPtr h) {
        IntPtr p = GlobalLock(h); if (p == IntPtr.Zero) return null;
        try {
            long n = Math.Min((long)GlobalSize(h).ToUInt64(), 16L * 1024 * 1024);
            byte[] b = new byte[n]; Marshal.Copy(p, b, 0, (int)n); return b;
        } finally { GlobalUnlock(h); }
    }
    static int HeaderInt(string all, string key) {
        int i = all.IndexOf(key); if (i < 0) return -1;
        i += key.Length; int j = i; while (j < all.Length && char.IsDigit(all[j])) j++;
        int v; return int.TryParse(all.Substring(i, j - i), out v) ? v : -1;
    }
    // "HTML Format" (CF_HTML): cabecalho com offsets em bytes UTF-8 + HTML. Devolve so o texto do fragmento.
    public static string HtmlToText(byte[] b) {
        int len = Array.IndexOf(b, (byte)0); if (len < 0) len = b.Length;
        string all = Encoding.UTF8.GetString(b, 0, len);
        int sf = HeaderInt(all, "StartFragment:"), ef = HeaderInt(all, "EndFragment:");
        string frag;
        if (sf >= 0 && ef > sf && ef <= len) frag = Encoding.UTF8.GetString(b, sf, ef - sf);
        else {
            int i = all.IndexOf("<!--StartFragment-->"), j = all.IndexOf("<!--EndFragment-->");
            if (i >= 0 && j > i) frag = all.Substring(i + 20, j - i - 20);
            else { int k = all.IndexOf('<'); frag = k >= 0 ? all.Substring(k) : all; }
        }
        frag = System.Text.RegularExpressions.Regex.Replace(frag, @"(?is)<(script|style)\b[^>]*>.*?</\1\s*>", "");
        frag = System.Text.RegularExpressions.Regex.Replace(frag, @"(?s)<!--.*?-->", "");
        frag = System.Text.RegularExpressions.Regex.Replace(frag, @"[\r\n\t]+", " ");
        frag = System.Text.RegularExpressions.Regex.Replace(frag, @"(?i)<br\s*/?>", "\n");
        frag = System.Text.RegularExpressions.Regex.Replace(frag, @"(?i)</(p|div|li|tr|h[1-6]|pre|blockquote)\s*>", "\n");
        frag = System.Text.RegularExpressions.Regex.Replace(frag, @"<[^>]*>", "");
        frag = WebUtility.HtmlDecode(frag);
        frag = System.Text.RegularExpressions.Regex.Replace(frag, @"[ ]*\n[ ]*", "\n");
        frag = System.Text.RegularExpressions.Regex.Replace(frag, @" {2,}", " ");
        return frag.Trim();
    }
    // null = sem texto; ClipboardInfo diz o motivo (ocupado, formatos presentes, dono). Le CF_UNICODETEXT
    // (o Windows sintetiza a partir de CF_TEXT); se o programa so pos HTML, extrai o texto do "HTML Format".
    public static string ClipboardText() {
        ClipboardInfo = "";
        string why = "";
        for (int attempt = 0; attempt < 3; attempt++) {
            bool open = false; int delay = 10;
            for (int i = 0; i < 8 && !open; i++) { open = OpenClipboard(IntPtr.Zero); if (!open) { Thread.Sleep(delay); delay = Math.Min(delay * 2, 200); } }
            if (!open) { ClipboardInfo = "clipboard ocupado por outro programa (" + ProcOf(GetOpenClipboardWindow()) + "), tente de novo"; return null; }
            bool retry = false;
            try {
                string owner = ProcOf(GetClipboardOwner());
                if (IsClipboardFormatAvailable(13)) {
                    IntPtr h = GetClipboardData(13);
                    if (h != IntPtr.Zero) { string s = ReadGlobalUni(h); if (!string.IsNullOrEmpty(s)) { ClipboardInfo = "texto (CF_UNICODETEXT) de " + owner; return s; } }
                    else retry = true;
                }
                uint html = RegisterClipboardFormat("HTML Format");
                if (html != 0 && IsClipboardFormatAvailable(html)) {
                    IntPtr h = GetClipboardData(html);
                    if (h != IntPtr.Zero) {
                        byte[] b = ReadGlobalBytes(h); string s = b == null ? null : HtmlToText(b);
                        if (!string.IsNullOrEmpty(s)) { ClipboardInfo = "HTML Format (sem texto puro) de " + owner; return s; }
                    } else retry = true;
                }
                why = (retry ? "o programa que copiou (" + owner + ") nao entregou o texto" : "sem texto (dono: " + owner + ")") + "; formatos: " + ListFormats();
            } finally { CloseClipboard(); }
            if (!retry) break;
            Thread.Sleep(80);
        }
        ClipboardInfo = why;
        return null;
    }
    // Normaliza o que veio do clipboard para o que o teclado sabe digitar. NormalizeInfo = o que mudou.
    public static string NormalizeInfo = "";
    public static string NormalizePaste(string s) {
        if (s == null) return null;
        StringBuilder o = new StringBuilder(s.Length);
        int sp = 0, q = 0, dash = 0, zw = 0, tab = 0, ell = 0, bul = 0;
        foreach (char c in s) {
            switch (c) {
                case '\u00A0': case '\u2007': case '\u202F': case '\u3000': case '\u2000': case '\u2001': case '\u2002': case '\u2003':
                case '\u2004': case '\u2005': case '\u2006': case '\u2008': case '\u2009': case '\u200A': case '\u205F':
                    o.Append(' '); sp++; break;
                case '\t': o.Append(' '); tab++; break;            // Tab no iPhone pula de campo
                case '\u200B': case '\u200C': case '\u200D': case '\u2060': case '\uFEFF': case '\u00AD': case '\u200E': case '\u200F':
                    zw++; break;
                case '\u201C': case '\u201D': case '\u201E': case '\u201F': case '\u2033': case '\u00AB': case '\u00BB':
                    o.Append('"'); q++; break;
                case '\u2018': case '\u2019': case '\u201A': case '\u201B': case '\u2032': case '\u2039': case '\u203A':
                    o.Append('\''); q++; break;
                case '\u2010': case '\u2011': case '\u2012': case '\u2013': case '\u2014': case '\u2015': case '\u2212':
                    o.Append('-'); dash++; break;
                case '\u2026': o.Append("..."); ell++; break;
                case '\u2022': case '\u00B7': case '\u25CF': case '\u25E6': case '\u2023': case '\u2043': o.Append('-'); bul++; break;
                case '\u2028': case '\u2029': o.Append('\n'); break;
                default: o.Append(c); break;
            }
        }
        List<string> parts = new List<string>();
        if (sp > 0) parts.Add(sp + " espaco(s) especiais->espaco");
        if (tab > 0) parts.Add(tab + " tab->espaco");
        if (zw > 0) parts.Add(zw + " invisivel(is) removido(s)");
        if (q > 0) parts.Add(q + " aspa(s) curva(s)->reta");
        if (dash > 0) parts.Add(dash + " travessao(oes)->-");
        if (ell > 0) parts.Add(ell + " reticencias->...");
        if (bul > 0) parts.Add(bul + " marcador(es)->-");
        NormalizeInfo = string.Join(", ", parts.ToArray());
        return o.ToString();
    }
    // Digitacao longa (colar): Esc na janela do espelho ou Ctrl+Shift+F12 cancela.
    public static volatile bool Typing = false, CancelTyping = false;
    static bool vHeld = false;

    static IntPtr KeyProc(int code, IntPtr w, IntPtr l) {
        try {
            if (code >= 0) {
                KBLL k = (KBLL)Marshal.PtrToStructure(l, typeof(KBLL));
                int msg = w.ToInt32();
                bool down = msg == 0x0100 || msg == 0x0104, up = msg == 0x0101 || msg == 0x0105;
                uint vk = k.vk;
                switch (vk) {
                    case 0xA0: lshift = down; break; case 0xA1: rshift = down; break;
                    case 0xA2: lctrl = down; break; case 0xA3: rctrl = down; break;
                    case 0xA4: lalt = down; break; case 0xA5: ralt = down; break;
                    case 0x5B: lwin = down; break; case 0x5C: rwin = down; break;
                }
                if (up && vk == 0x56) vHeld = false;                                     // solta o V em qualquer janela (nao trava o Ctrl+V)
                if (IsModifier(vk)) return CallNextHookEx(IntPtr.Zero, code, w, l);   // modificadores sempre passam
                bool shift = lshift || rshift, altgr = ralt, ctrl = (lctrl || rctrl) && !altgr;
                if (down && vk == 0x7B && ctrl && shift) {                              // Ctrl+Shift+F12
                    Enabled = !Enabled; if (!Enabled) CancelTyping = true; Push("toggle " + (Enabled ? "on" : "off"));
                    return new IntPtr(1);
                }
                if (down && vk == 0x79 && ctrl && shift) {                              // Ctrl+Shift+F10: afixar na altura da tela
                    AutoFit = !AutoFit; if (AutoFit) { FitReason = "religado"; FitRequest = true; actBurst = 0; }
                    FitStatus = AutoFit ? "ligado" : "desligado"; Push("fit " + (AutoFit ? "on" : "off"));
                    return new IntPtr(1);
                }
                if (down && vk == 0x7A && ctrl && shift) {                              // Ctrl+Shift+F11: espelho sempre no topo
                    MirrorTopmost = !MirrorTopmost; ApplyTopmost(); Push("topmost " + (MirrorTopmost ? "on" : "off"));
                    return new IntPtr(1);
                }
                bool injected = (k.flags & 0x10) != 0;
                if (Enabled && !injected && !lalt && !lwin && !rwin) {                // Alt+Tab, Win+... ficam com o Windows
                    IntPtr h = Window();
                    if (h != IntPtr.Zero && GetForegroundWindow() == h) {
                        if (up) { if (vk == 0x56) vHeld = false; return new IntPtr(1); }
                        if (down) {
                            if (Typing && vk == 0x1B) { CancelTyping = true; return new IntPtr(1); }   // Esc cancela o colar em andamento
                            if (vk == 0x1B && !ctrl && !shift) { Push("back"); return new IntPtr(1); }   // Esc = voltar (o iOS nao trata Esc como voltar)
                            if (ctrl && shift && vk >= 0x31 && vk <= 0x39) { Push("reply " + (vk - 0x30)); return new IntPtr(1); }   // Ctrl+Shift+1..9 = resposta pronta N
                            if (ctrl && shift && vk == 0x53) { Push("suggest"); return new IntPtr(1); }   // Ctrl+Shift+S = sugerir.ps1
                            int mods = (shift ? 0x02 : 0) | (ctrl ? 0x08 : 0);       // Ctrl do PC -> Cmd do iPhone
                            int usage = SpecialUsage(vk);
                            if (usage != 0) { Push("key " + usage + " " + mods); return new IntPtr(1); }
                            if (ctrl && vk == 0x56) {                                  // V
                                // Ctrl+V = cola o clipboard do PC (digitado); Ctrl+Shift+V = Cmd+V (clipboard do iPhone)
                                if (!vHeld) Push(shift ? "key " + LetterDigitUsage(vk) + " 8" : "paste");
                                vHeld = true;
                                return new IntPtr(1);
                            }
                            if (ctrl) {
                                int u = LetterDigitUsage(vk);
                                if (u != 0) Push("key " + u + " " + mods);
                                return new IntPtr(1);
                            }
                            string s = Translate(vk, k.scan, shift, altgr, LayoutOf(h));
                            if (s.Length > 0) Push("text " + s);
                            return new IntPtr(1);
                        }
                    }
                }
            }
        } catch (Exception) { }
        return CallNextHookEx(IntPtr.Zero, code, w, l);
    }

    // ---------------- indicador "CONTROLE LIGADO / DESLIGADO" + sempre no topo ----------------
    // Chip pequeno na barra de titulo do espelho: sem borda, click-through, nunca pega foco. Segue a janela a cada 200 ms.
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    public static volatile bool MirrorTopmost = false;
    static IntPtr topmostApplied = IntPtr.Zero;
    public static string OverlayStatus = "parado";
    public static void ApplyTopmost() {
        IntPtr h = Window(); if (h == IntPtr.Zero) { topmostApplied = IntPtr.Zero; return; }
        SetWindowPos(h, MirrorTopmost ? new IntPtr(-1) : new IntPtr(-2), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);   // NOSIZE|NOMOVE|NOACTIVATE
        topmostApplied = MirrorTopmost ? h : IntPtr.Zero;
    }

    // ---------------- afixar na altura da tela: a janela cabe inteira na area util (acima da barra de tarefas) ----------------
    // Coordenadas fisicas (processo PerMonitorV2). Janela nova / video girou = encaixa: altura util - margem, largura pela
    // proporcao, topo no topo da area util, mesma posicao horizontal. Fora isso so corrige se a janela sair da area util.
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
    [StructLayout(LayoutKind.Sequential)] struct GUITHREADINFO { public int cbSize; public uint flags; public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret; public RECT rcCaret; }
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int n);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO g);
    public static volatile bool AutoFit = true, FitRequest = false;
    public static string FitStatus = "aguardando a janela", FitReason = "";
    static IntPtr fitHwnd = IntPtr.Zero;
    static bool fitPendingNew = false;
    static int fitSeenTick, lastFitTick, lastActTick, burstStart, actBurst;
    static double lastFitAspect = 0;

    // Pura (testavel): retangulo VISIVEL da janela {x, y, w, h} dentro da area util.
    public static int[] ComputeFit(int wl, int wt, int wr, int wb, int ncW, int ncH, double aspect, int margin, int curL) {
        int workW = wr - wl, workH = wb - wt;
        int fh = workH - margin;
        int ch = Math.Max(50, fh - ncH);
        int cw = (int)Math.Round(ch * aspect);
        int fw = cw + ncW;
        int maxW = workW - 2 * margin;
        if (fw > maxW) { fw = maxW; cw = Math.Max(50, fw - ncW); ch = (int)Math.Round(cw / aspect); fh = ch + ncH; }
        int x = Math.Max(wl, Math.Min(wr - fw, curL));
        return new int[] { x, wt, fw, fh };
    }
    // proporcao do video: a detectada, ou a da area cliente quando o video ocupa a janela toda
    public static double EffectiveAspect(double a) {
        if (a > 0) return a;
        RECT c; if (!ClientScreen(Window(), out c)) return 0;
        return (double)(c.R - c.L) / (c.B - c.T);
    }
    static bool FitGeo(IntPtr h, out RECT wr, out RECT fr, out RECT c, out RECT work, out int margin) {
        wr = new RECT(); fr = new RECT(); c = new RECT(); work = new RECT(); margin = 8;
        if (h == IntPtr.Zero || !GetWindowRect(h, out wr) || !ClientScreen(h, out c)) return false;
        // retangulo visivel (sem a borda invisivel de redimensionar do Windows 10/11)
        try { if (DwmGetWindowAttribute(h, 9, out fr, Marshal.SizeOf(typeof(RECT))) != 0 || fr.R <= fr.L) fr = wr; } catch (Exception) { fr = wr; }
        IntPtr mon = MonitorFromWindow(h, 2);                  // MONITOR_DEFAULTTONEAREST: monitor onde a janela esta
        MONITORINFO mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (mon == IntPtr.Zero || !GetMonitorInfo(mon, ref mi)) return false;
        work = mi.rcWork;
        double sc = 1.0; try { uint d = GetDpiForWindow(h); if (d > 0) sc = d / 96.0; } catch (Exception) { }
        margin = (int)Math.Round(8 * sc);
        return true;
    }
    static string DoFit(IntPtr h, bool apply, string reason) {
        RECT wr, fr, c, work; int m;
        if (!FitGeo(h, out wr, out fr, out c, out work, out m)) return "sem geometria (janela fechada ou minimizada?)";
        double a = EffectiveAspect(VideoAspect);
        if (a < 0.05 || a > 20) return "proporcao desconhecida";
        int ncW = (fr.R - fr.L) - (c.R - c.L), ncH = (fr.B - fr.T) - (c.B - c.T);   // barra de titulo + bordas visiveis
        int[] q = ComputeFit(work.L, work.T, work.R, work.B, ncW, ncH, a, m, fr.L);
        int dl = fr.L - wr.L, dt = fr.T - wr.T, dr = wr.R - fr.R, db = wr.B - fr.B;
        string s = string.Format(CultureInfo.InvariantCulture, "area util {0}x{1} em ({2},{3}); janela {4}x{5} em ({6},{7}) -> {8}x{9} em ({10},{11}); proporcao {12:0.0000}; {13}",
            work.R - work.L, work.B - work.T, work.L, work.T, fr.R - fr.L, fr.B - fr.T, fr.L, fr.T, q[2], q[3], q[0], q[1], a, reason);
        if (!apply) return "plano: " + s;
        SetWindowPos(h, IntPtr.Zero, q[0] - dl, q[1] - dt, q[2] + dl + dr, q[3] + dt + db, 0x0010 | 0x0004 | 0x0200);   // NOACTIVATE|NOZORDER|NOOWNERZORDER
        lastFitAspect = a; lastFitTick = Environment.TickCount;
        return "encaixada: " + s;
    }
    static bool InsideWork(RECT f, RECT w) { return f.L >= w.L - 1 && f.T >= w.T - 1 && f.R <= w.R + 1 && f.B <= w.B + 1; }
    static bool UserBusy(IntPtr h) {                           // nao briga: botao apertado ou arrastando/redimensionando
        if (dragging) return true;
        if ((GetAsyncKeyState(0x01) & 0x8000) != 0 || (GetAsyncKeyState(0x02) & 0x8000) != 0) return true;
        GUITHREADINFO g = new GUITHREADINFO(); g.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
        return GetGUIThreadInfo(GetWindowThreadProcessId(h, IntPtr.Zero), ref g) && (g.flags & 0x2) != 0;   // GUI_INMOVESIZE
    }
    // comando 'fit' do console/canal: aplica agora (apply=false so mostra o plano)
    public static string FitNow(bool apply) {
        IntPtr h = Window(); if (h == IntPtr.Zero) return "janela '" + Title + "' nao encontrada";
        if (IsIconic(h) || IsZoomed(h)) return "janela minimizada/maximizada: nada a fazer";
        string r = DoFit(h, apply, "comando"); if (apply) FitStatus = r; return r;
    }
    // chamado pelo PowerShell quando a proporcao do video e (re)detectada
    public static void AspectChanged() {
        double va = EffectiveAspect(VideoAspect), la = lastFitAspect;
        if (va <= 0 || la <= 0) return;
        if ((va < 1) != (la < 1)) { FitReason = "video girou"; FitRequest = true; }
        else if (Environment.TickCount - lastFitTick < 10000 && Math.Abs(va - la) / la > 0.03) { FitReason = "ajuste fino da proporcao"; FitRequest = true; }
    }
    static void FitTick(IntPtr h) {
        if (h == IntPtr.Zero || !IsWindowVisible(h)) { fitHwnd = IntPtr.Zero; return; }
        int now = Environment.TickCount;
        if (h != fitHwnd) { fitHwnd = h; fitSeenTick = now; fitPendingNew = true; }
        if (!AutoFit || IsIconic(h) || IsZoomed(h) || UserBusy(h)) return;
        if (now - lastActTick < 800) return;
        if (fitPendingNew && now - fitSeenTick < 1200) return;   // deixa o uxplay terminar de abrir/dimensionar
        RECT wr, fr, c, work; int m;
        if (!FitGeo(h, out wr, out fr, out c, out work, out m)) return;
        string r = null;
        if (fitPendingNew || FitRequest) {
            r = DoFit(h, true, fitPendingNew ? "janela nova" : FitReason); fitPendingNew = false; FitRequest = false;
        } else if (!InsideWork(fr, work)) {
            if (fr.B - fr.T > work.B - work.T || fr.R - fr.L > work.R - work.L) r = DoFit(h, true, "maior que a area util");
            else {
                int fw = fr.R - fr.L, fh = fr.B - fr.T;
                int x = Math.Max(work.L, Math.Min(work.R - fw, fr.L)), y = Math.Max(work.T, Math.Min(work.B - fh, fr.T));
                SetWindowPos(h, IntPtr.Zero, x - (fr.L - wr.L), y - (fr.T - wr.T), 0, 0, 0x0001 | 0x0010 | 0x0004 | 0x0200);   // NOSIZE|NOACTIVATE|NOZORDER
                r = string.Format("movida para dentro da area util: ({0},{1}) -> ({2},{3})", fr.L, fr.T, x, y);
            }
        }
        if (r == null) return;
        lastActTick = now;
        if (now - burstStart > 15000) { burstStart = now; actBurst = 0; }
        if (++actBurst > 6) { AutoFit = false; FitStatus = "pausado: a janela nao fica no lugar (Ctrl+Shift+F10 religa)"; Push("fitlog Afixar " + FitStatus); return; }
        FitStatus = r; Push("fitlog Afixar: " + r);
    }
    class Chip : System.Windows.Forms.Form {
        public bool On = true; public string Text2 = ""; public Font F;
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override System.Windows.Forms.CreateParams CreateParams {
            get { System.Windows.Forms.CreateParams cp = base.CreateParams; cp.ExStyle |= 0x20 | 0x8000000 | 0x80 | 0x8; return cp; }   // TRANSPARENT|NOACTIVATE|TOOLWINDOW|TOPMOST (LAYERED vem do Opacity)
        }
        protected override void WndProc(ref System.Windows.Forms.Message m) {
            if (m.Msg == 0x21) { m.Result = new IntPtr(3); return; }   // WM_MOUSEACTIVATE -> MA_NOACTIVATE
            if (m.Msg == 0x84) { m.Result = new IntPtr(-1); return; }  // WM_NCHITTEST -> HTTRANSPARENT
            base.WndProc(ref m);
        }
        protected override void OnPaint(System.Windows.Forms.PaintEventArgs e) {
            e.Graphics.Clear(On ? Color.FromArgb(30, 142, 62) : Color.FromArgb(95, 99, 104));
            if (F != null) System.Windows.Forms.TextRenderer.DrawText(e.Graphics, Text2, F, ClientRectangle, Color.White,
                System.Windows.Forms.TextFormatFlags.HorizontalCenter | System.Windows.Forms.TextFormatFlags.VerticalCenter | System.Windows.Forms.TextFormatFlags.SingleLine);
        }
    }
    static Chip chip;
    static IntPtr chipHwnd = IntPtr.Zero;   // o hook compara com isto (Control.Handle nao pode ser lido de outra thread)
    public static void StartOverlay() {
        Thread t = new Thread(delegate() {
            try {
                Chip f = new Chip();
                f.FormBorderStyle = System.Windows.Forms.FormBorderStyle.None; f.ShowInTaskbar = false; f.TopMost = true;
                f.StartPosition = System.Windows.Forms.FormStartPosition.Manual; f.Location = new Point(-32000, -32000); f.Size = new Size(20, 10);
                f.Opacity = 0.93;
                IntPtr force = f.Handle;
                chipHwnd = force; chip = f;
                System.Windows.Forms.Timer tm = new System.Windows.Forms.Timer(); tm.Interval = 200;
                tm.Tick += delegate { try { OverlayTick(f); } catch (Exception ex) { OverlayStatus = "erro: " + ex.Message; } };
                tm.Start();
                OverlayStatus = "ok";
                System.Windows.Forms.Application.Run();
                tm.Stop(); f.Dispose();
            } catch (Exception ex) { OverlayStatus = "falhou: " + ex.Message; }
        });
        t.SetApartmentState(ApartmentState.STA); t.IsBackground = true; t.Start();
        for (int i = 0; i < 100 && OverlayStatus == "parado"; i++) Thread.Sleep(10);
    }
    public static void StopOverlay() {
        Chip f = chip; if (f == null) return;
        try { f.BeginInvoke((Action)delegate { System.Windows.Forms.Application.ExitThread(); }); } catch (Exception) { }
    }
    static double chipScale = 0;
    static void OverlayTick(Chip f) {
        IntPtr h = Window();
        if (MirrorTopmost && h != IntPtr.Zero && h != topmostApplied) ApplyTopmost();   // janela renasceu: reaplica
        try { FitTick(h); } catch (Exception ex) { FitStatus = "erro: " + ex.Message; }
        try { StuckCheck(); } catch (Exception) { }
        RECT wr, c;
        if (h == IntPtr.Zero || !IsWindowVisible(h) || IsIconic(h) || !GetWindowRect(h, out wr) || !ClientScreen(h, out c)) { if (f.Visible) f.Hide(); return; }
        double sc = 1.0; try { uint d = GetDpiForWindow(h); if (d > 0) sc = d / 96.0; } catch (Exception) { }
        if (f.F == null || Math.Abs(sc - chipScale) > 0.01) { if (f.F != null) f.F.Dispose(); f.F = new Font("Segoe UI", (float)(11 * sc), FontStyle.Bold, GraphicsUnit.Pixel); chipScale = sc; }
        bool on = Enabled; string text = on ? "CONTROLE LIGADO" : "DESLIGADO";
        Size ts = System.Windows.Forms.TextRenderer.MeasureText(text, f.F);
        int w = ts.Width + (int)(12 * sc), hh = ts.Height + (int)(2 * sc);
        int bar = c.T - wr.T, x, y;
        if (bar >= hh + 2) {                                   // dentro da barra de titulo, antes dos botoes min/max/fechar
            y = wr.T + (bar - hh) / 2;
            x = wr.R - (int)(150 * sc) - w;
            if (x < wr.L + (int)(8 * sc)) x = wr.L + ((wr.R - wr.L) - w) / 2;
        } else {                                               // janela sem barra: logo acima dela, se couber na tela
            y = wr.T - hh - 2; x = c.L + ((c.R - c.L) - w) / 2;
            if (y < System.Windows.Forms.Screen.FromHandle(h).Bounds.Top) { if (f.Visible) f.Hide(); return; }
        }
        // so aparece se aquele pedaco da janela do espelho estiver visivel (nao flutua por cima de outras janelas)
        POINT p = new POINT(); p.X = x + w / 2; p.Y = y + hh / 2;
        IntPtr under = GetAncestor(WindowFromPoint(p), 2);
        if (under != h && under != f.Handle) { if (f.Visible) f.Hide(); return; }
        bool changed = f.On != on || f.Text2 != text;
        f.On = on; f.Text2 = text;
        if (!f.Visible) f.Show();
        SetWindowPos(f.Handle, new IntPtr(-1), x, y, w, hh, 0x0010);   // HWND_TOPMOST, NOACTIVATE
        if (changed) f.Invalidate();
    }

    // ---------------- captura ----------------
    static bool MostlyBlack(Bitmap b) {
        int dark = 0, total = 0;
        for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) {
            Color c = b.GetPixel(Math.Min(b.Width - 1, (x * b.Width) / 16 + b.Width / 32), Math.Min(b.Height - 1, (y * b.Height) / 16 + b.Height / 32));
            total++; if (c.R + c.G + c.B < 24) dark++;
        }
        return dark == total;
    }
    public static string LastCaptureMethod = "";
    // Area cliente da janela. PrintWindow(PW_RENDERFULLCONTENT) primeiro; se vier preto, copia da tela (pega o que estiver por cima).
    public static Bitmap CaptureClient(IntPtr h) {
        RECT wr, c;
        if (!GetWindowRect(h, out wr) || !ClientScreen(h, out c)) return null;
        int ww = wr.R - wr.L, wh = wr.B - wr.T;
        Bitmap cl = null;
        using (Bitmap full = new Bitmap(ww, wh, PixelFormat.Format32bppArgb)) {
            bool ok;
            using (Graphics g = Graphics.FromImage(full)) { IntPtr dc = g.GetHdc(); ok = PrintWindow(h, dc, 2); g.ReleaseHdc(dc); }
            Rectangle r = Rectangle.Intersect(new Rectangle(c.L - wr.L, c.T - wr.T, c.R - c.L, c.B - c.T), new Rectangle(0, 0, ww, wh));
            if (ok && r.Width > 0 && r.Height > 0) {
                cl = full.Clone(r, PixelFormat.Format32bppArgb);
                if (MostlyBlack(cl)) { cl.Dispose(); cl = null; } else LastCaptureMethod = "PrintWindow";
            }
        }
        if (cl == null) {
            cl = new Bitmap(c.R - c.L, c.B - c.T, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(cl)) g.CopyFromScreen(c.L, c.T, 0, 0, new Size(c.R - c.L, c.B - c.T));
            LastCaptureMethod = "CopyFromScreen";
        }
        return cl;
    }
    public static string Screenshot(string path) {
        IntPtr h = Window();
        if (h == IntPtr.Zero) return "ERRO: janela '" + Title + "' nao encontrada";
        if (IsIconic(h)) return "ERRO: janela minimizada";
        using (Bitmap cl = CaptureClient(h)) {
            if (cl == null) return "ERRO: nao consegui capturar";
            int[] q = ComputeVideoRect(cl.Width, cl.Height, VideoAspect);
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            using (Bitmap vid = cl.Clone(new Rectangle(q[0], q[1], q[2], q[3]), PixelFormat.Format32bppArgb)) vid.Save(path, ImageFormat.Png);
            return "ok " + path + " " + q[2] + "x" + q[3] + " via " + LastCaptureMethod;
        }
    }
    // Procura faixas pretas simetricas (letterbox). Achou: ajusta VideoAspect e devolve true.
    public static bool DetectBars(Bitmap b, out double aspect, out string info) {
        aspect = 0; info = "";
        int w = b.Width, h = b.Height;
        BitmapData d = b.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        int[] px = new int[w * h];
        Marshal.Copy(d.Scan0, px, 0, px.Length);
        b.UnlockBits(d);
        Func<int, bool> colDark = delegate(int x) { for (int y = 0; y < h; y += 3) { int c = px[y * w + x]; if (((c >> 16) & 255) + ((c >> 8) & 255) + (c & 255) > 40) return false; } return true; };
        Func<int, bool> rowDark = delegate(int y) { for (int x = 0; x < w; x += 3) { int c = px[y * w + x]; if (((c >> 16) & 255) + ((c >> 8) & 255) + (c & 255) > 40) return false; } return true; };
        int left = 0; while (left < w / 3 && colDark(left)) left++;
        int right = 0; while (right < w / 3 && colDark(w - 1 - right)) right++;
        int top = 0; while (top < h / 3 && rowDark(top)) top++;
        int bottom = 0; while (bottom < h / 3 && rowDark(h - 1 - bottom)) bottom++;
        info = string.Format("faixas esq={0} dir={1} cima={2} baixo={3} em {4}x{5}", left, right, top, bottom, w, h);
        if (left >= w / 3 || top >= h / 3) { info += " (imagem escura: inconclusivo)"; return false; }
        if (left > 2 && right > 2 && Math.Abs(left - right) <= 3 && top <= 2 && bottom <= 2) { aspect = (double)(w - left - right) / h; return true; }
        if (top > 2 && bottom > 2 && Math.Abs(top - bottom) <= 3 && left <= 2 && right <= 2) { aspect = (double)w / (h - top - bottom); return true; }
        if (left <= 2 && right <= 2 && top <= 2 && bottom <= 2) { info += " (sem faixas: video ocupa a janela)"; aspect = 0; return true; }
        info += " (assimetrico: inconclusivo)";
        return false;
    }
    public static string DetectAspect() {
        IntPtr h = Window();
        if (h == IntPtr.Zero) return "janela nao encontrada";
        using (Bitmap cl = CaptureClient(h)) {
            if (cl == null) return "nao consegui capturar";
            double a; string info;
            if (DetectBars(cl, out a, out info)) { VideoAspect = a; return "ok " + info; }
            return "falhou " + info;
        }
    }
    // Igual, mas nao altera VideoAspect (para conferir se o video girou antes de aceitar).
    public static bool PeekAspect(out double a, out string info) {
        a = 0; info = "";
        IntPtr h = Window();
        if (h == IntPtr.Zero || IsIconic(h)) { info = "janela nao encontrada"; return false; }
        using (Bitmap cl = CaptureClient(h)) {
            if (cl == null) { info = "nao consegui capturar"; return false; }
            return DetectBars(cl, out a, out info);
        }
    }

    // ---------------- canal de comandos: HTTP minimo so em 127.0.0.1 ----------------
    public class Req { public string Cmd; public string Resp = ""; public ManualResetEventSlim Done = new ManualResetEventSlim(false); }
    public static BlockingCollection<Req> Requests = new BlockingCollection<Req>(32);   // limite: alem disso responde 503
    static TcpListener listener;
    public static int Port;
    public static void StartServer(int port) {
        Port = port;
        listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        Thread t = new Thread(delegate() {
            while (true) {
                TcpClient c;
                try { c = listener.AcceptTcpClient(); } catch (Exception) { return; }
                ThreadPool.QueueUserWorkItem(HandleClient, c);
            }
        });
        t.IsBackground = true; t.Start();
    }
    public static void StopServer() { try { listener.Stop(); } catch (Exception) { } }
    static void Reply(NetworkStream s, int code, string body) {
        byte[] b = Encoding.UTF8.GetBytes(body + "\n");
        string head = "HTTP/1.1 " + code + (code == 200 ? " OK" : " Error") + "\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: " + b.Length + "\r\nConnection: close\r\n\r\n";
        byte[] hb = Encoding.ASCII.GetBytes(head);
        s.Write(hb, 0, hb.Length); s.Write(b, 0, b.Length);
    }
    static void HandleClient(object o) {
        TcpClient c = (TcpClient)o;
        try {
            c.ReceiveTimeout = 5000;
            NetworkStream s = c.GetStream();
            byte[] buf = new byte[70000]; int len = 0, hdrEnd = -1;
            while (hdrEnd < 0 && len < buf.Length) {
                int n = s.Read(buf, len, buf.Length - len); if (n <= 0) break; len += n;
                for (int i = 3; i < len; i++) if (buf[i - 3] == 13 && buf[i - 2] == 10 && buf[i - 1] == 13 && buf[i] == 10) { hdrEnd = i - 3; break; }
            }
            if (hdrEnd < 0) { Reply(s, 400, "pedido invalido"); return; }
            string[] lines = Encoding.ASCII.GetString(buf, 0, hdrEnd).Split(new string[] { "\r\n" }, StringSplitOptions.None);
            string[] rl = lines[0].Split(' ');
            string target = rl.Length > 1 ? rl[1] : "/";
            Dictionary<string, string> hd = new Dictionary<string, string>();
            for (int i = 1; i < lines.Length; i++) { int p = lines[i].IndexOf(':'); if (p > 0) hd[lines[i].Substring(0, p).Trim().ToLowerInvariant()] = lines[i].Substring(p + 1).Trim(); }
            string host; hd.TryGetValue("host", out host);
            // so localhost: bloqueia DNS rebinding (Host), pagina web (Origin) e pedido sem o header proprio (CSRF)
            if (host != "127.0.0.1:" + Port && host != "localhost:" + Port) { Reply(s, 403, "host recusado"); return; }
            if (hd.ContainsKey("origin")) { Reply(s, 403, "origin recusado"); return; }
            if (!hd.ContainsKey("x-iphone-control")) { Reply(s, 403, "falta o header X-iPhone-Control"); return; }
            int cl = 0; string cls; if (hd.TryGetValue("content-length", out cls)) int.TryParse(cls, out cl);
            if (cl < 0 || cl > 65536) { Reply(s, 413, "corpo grande demais"); return; }
            int have = len - (hdrEnd + 4);
            byte[] body = new byte[cl];
            Array.Copy(buf, hdrEnd + 4, body, 0, Math.Min(have, cl));
            while (have < cl) { int n = s.Read(body, have, cl - have); if (n <= 0) break; have += n; }
            string cmd = Encoding.UTF8.GetString(body, 0, Math.Min(have, cl)).Trim();
            if (cmd.Length == 0) { int q = target.IndexOf("?c="); if (q >= 0) cmd = Uri.UnescapeDataString(target.Substring(q + 3).Replace('+', ' ')).Trim(); }
            if (cmd.Length == 0) { Reply(s, 400, "comando vazio"); return; }
            Req r = new Req(); r.Cmd = cmd;
            if (!Requests.TryAdd(r)) { Reply(s, 503, "fila cheia (app ocupado), tente de novo"); return; }
            Wake.Set();
            if (!r.Done.Wait(120000)) { Reply(s, 504, "timeout esperando o app"); return; }
            Reply(s, 200, r.Resp);
        } catch (Exception) { } finally { try { c.Close(); } catch (Exception) { } }
    }
    // para o SelfTest: cliente HTTP numa thread, enquanto o PowerShell atende a fila
    public static Task<string> TestClient(int port, string body, bool header, string origin, string host) {
        return Task.Run(delegate() {
            try {
                using (TcpClient c = new TcpClient()) {
                    c.Connect(IPAddress.Loopback, port);
                    NetworkStream s = c.GetStream();
                    byte[] b = Encoding.UTF8.GetBytes(body);
                    string h = "POST / HTTP/1.1\r\nHost: " + host + "\r\nContent-Length: " + b.Length + "\r\n";
                    if (header) h += "X-iPhone-Control: 1\r\n";
                    if (!string.IsNullOrEmpty(origin)) h += "Origin: " + origin + "\r\n";
                    h += "\r\n";
                    byte[] hb = Encoding.ASCII.GetBytes(h);
                    s.Write(hb, 0, hb.Length); s.Write(b, 0, b.Length);
                    using (StreamReader rd = new StreamReader(s, Encoding.UTF8)) {
                        string all = rd.ReadToEnd();
                        string status = all.Split('\n')[0].Trim();
                        int p = all.IndexOf("\r\n\r\n");
                        return status + " | " + (p >= 0 ? all.Substring(p + 4).Trim() : "");
                    }
                }
            } catch (Exception e) { return "EXC " + e.Message; }
        });
    }
}
'@
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing, System.Windows.Forms -Language CSharp
$dpi = [IPC]::InitDpi()
[IPC]::Title = $WindowTitle
[IPC]::WheelThreshold = $WheelThreshold
if ($VideoAspect -gt 0) { [IPC]::VideoAspect = $VideoAspect }
[IPC]::AutoFit = -not $NoFit; if ($NoFit) { [IPC]::FitStatus = 'desligado (-NoFit)' }

# ======================================================================================================
# -Screenshot sozinho (sem Bluetooth)
# ======================================================================================================
if ($Screenshot) {
    if ($VideoAspect -le 0) { $null = [IPC]::DetectAspect() }
    Write-Output ([IPC]::Screenshot($ScreenshotPath))
    Write-Output ([IPC]::Describe())
    exit 0
}

# ======================================================================================================
# log
# ======================================================================================================
New-Item -ItemType Directory -Force (Join-Path $here 'logs') | Out-Null
$logFile = Join-Path $here ("logs\control-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$script:promptShown = $false
$script:buffer = ''
$script:quitRequested = $false
function Log([string]$msg, [string]$color = 'Gray') {
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $msg
    if ($script:promptShown) { try { [Console]::Write("`r" + (' ' * ([Console]::WindowWidth - 1)) + "`r") } catch {} }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch {}
    if ($script:promptShown) { ShowPrompt }
}
Log "Log: $logFile | DPI: $dpi | modo: $(if ($Relative) { 'RELATIVO' } else { 'ABSOLUTO' })"

# ======================================================================================================
# Report Map composto
# ======================================================================================================
$kbMap = @(   # Report ID 1: teclado, IDENTICO ao ble-keyboard-testble-keyboard.ps1 (fica primeiro: iOS trata como teclado de verdade)
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01,
    0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
    0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
    0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xC0)
# Report ID 2: 5 botoes + X/Y + roda + pan. Layout testado em iPhone.
$mouseHead = @(0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x02, 0x09, 0x01, 0xA1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x03, 0x81, 0x01)
$mouseAbsXY = @(0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x16, 0x00, 0x00, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02,   # X,Y 0..32767 absoluto
    0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06)                                                  # roda
$mouseRelXY = @(0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06)   # X,Y,roda -127..127
$mouseTail = @(0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06, 0xC0, 0xC0)
# Report ID 3: consumer control, um uso de 16 bits (Home da Apple = 0x0040)
$consumerMap = @(0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x03, 0x15, 0x00, 0x26, 0xFF, 0x03, 0x19, 0x00, 0x2A, 0xFF, 0x03, 0x75, 0x10, 0x95, 0x01, 0x81, 0x00, 0xC0)
$xy = if ($Relative) { $mouseRelXY } else { $mouseAbsXY }
[byte[]]$reportMap = @($kbMap + $mouseHead + $xy + $mouseTail + $consumerMap)
$mouseLen = if ($Relative) { 5 } else { 7 }

# Le o descritor e soma os bits de entrada por Report ID (confere com o tamanho que mandamos).
function ParseReportMap([byte[]]$m) {
    $i = 0; $size = 0; $count = 0; $id = 0; $depth = 0; $in = @{}
    while ($i -lt $m.Length) {
        $b = $m[$i]; $n = $b -band 3; if ($n -eq 3) { $n = 4 }
        $v = 0; for ($j = 0; $j -lt $n; $j++) { $v = $v -bor ([int]$m[$i + 1 + $j] -shl (8 * $j)) }
        switch ($b -band 0xFC) {
            0x74 { $size = $v } 0x94 { $count = $v } 0x84 { $id = $v }
            0x80 { if (-not $in.ContainsKey($id)) { $in[$id] = 0 }; $in[$id] += $size * $count }
            0xA0 { $depth++ } 0xC0 { $depth-- }
        }
        $i += 1 + $n
    }
    @{ Depth = $depth; InBits = $in; End = $i }
}

# ======================================================================================================
# GATT (mesma estrutura da v2, com 3 Input Reports)
# ======================================================================================================
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceProvider, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Devices.Bluetooth.BluetoothAdapter, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
$asTaskOp = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [Type]$t) { $task = $asTaskOp.MakeGenericMethod($t).Invoke($null, @($op)); $task.Wait(-1) | Out-Null; $task.Result }

$G = 'Windows.Devices.Bluetooth.GenericAttributeProfile'
function U16([int]$x) { [guid]('0000{0:x4}-0000-1000-8000-00805f9b34fb' -f $x) }
function Buf([byte[]]$b) { [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsBuffer($b) }
$Read = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicProperties]::Read
$WriteNR = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicProperties]::WriteWithoutResponse
$Notify = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicProperties]::Notify
$EncReq = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattProtectionLevel]::EncryptionRequired
function Step($name, $r) { if ($r.Error -ne 'Success') { throw "FALHOU em '$name': BluetoothError=$($r.Error)" }; Log "  ok  $name" }
function AddChar($svc, [int]$uuid, $props, [byte[]]$static, $name) {
    $p = New-Object "$G.GattLocalCharacteristicParameters"
    $p.CharacteristicProperties = $props
    $p.ReadProtectionLevel = $EncReq
    $p.WriteProtectionLevel = $EncReq
    if ($static) { $p.StaticValue = (Buf $static) }
    $r = Await ($svc.CreateCharacteristicAsync((U16 $uuid), $p)) ([Type]"$G.GattLocalCharacteristicResult")
    Step $name $r
    $r.Characteristic
}
function AddInputReport($svc, [int]$id, [int]$len, $name) {
    $c = AddChar $svc 0x2A4D ($Read -bor $Notify) ([byte[]](@(0) * $len)) "Input Report $name (ID $id, $len bytes)"
    $dp = New-Object "$G.GattLocalDescriptorParameters"
    $dp.ReadProtectionLevel = $EncReq
    $dp.StaticValue = (Buf ([byte[]]($id, 0x01)))
    Step "  Report Reference ID $id" (Await ($c.CreateDescriptorAsync((U16 0x2908), $dp)) ([Type]"$G.GattLocalDescriptorResult"))
    $c
}

$provider = $null
function PublishGatt {
    $adapter = Await ([Windows.Devices.Bluetooth.BluetoothAdapter]::GetDefaultAsync()) ([Windows.Devices.Bluetooth.BluetoothAdapter])
    Log "Adaptador: LE=$($adapter.IsLowEnergySupported) Peripheral=$($adapter.IsPeripheralRoleSupported)"
    $res = Await ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceProvider]::CreateAsync((U16 0x1812))) ([Type]"$G.GattServiceProviderResult")
    Step 'GattServiceProvider.CreateAsync(0x1812)' $res
    $script:provider = $res.ServiceProvider
    $svc = $script:provider.Service
    $null = AddChar $svc 0x2A4A $Read ([byte[]](0x11, 0x01, 0x00, 0x02)) 'HID Information 0x2A4A'
    $null = AddChar $svc 0x2A4B $Read $reportMap "Report Map 0x2A4B ($($reportMap.Length) bytes)"
    $null = AddChar $svc 0x2A4C $WriteNR $null 'HID Control Point 0x2A4C'
    $null = AddChar $svc 0x2A4E ($Read -bor $WriteNR) ([byte[]](0x01)) 'Protocol Mode 0x2A4E'
    $script:kbReport = AddInputReport $svc 1 8 'teclado'
    $script:mouseReport = AddInputReport $svc 2 $mouseLen 'ponteiro'
    $script:consumerReport = AddInputReport $svc 3 2 'consumer'
}
function StartAdv {
    $ap = New-Object "$G.GattServiceProviderAdvertisingParameters"
    $ap.IsConnectable = $true
    $ap.IsDiscoverable = $true
    $script:provider.StartAdvertising($ap)
    Start-Sleep -Milliseconds 1500
    Log "Status do anuncio: $($script:provider.AdvertisementStatus)"
    [string]$script:provider.AdvertisementStatus -eq 'Started'
}

# ---------- inscritos / conexoes ----------
function SubscribedIds {
    $ids = @()
    try { foreach ($cl in $script:kbReport.SubscribedClients) { $ids += [string]$cl.Session.DeviceId.Id } } catch {}
    , $ids
}
function SubCount($c) { $n = 0; try { foreach ($x in $c.SubscribedClients) { $n++ } } catch {}; $n }
# Lista de conectados SEM travar o loop: FindAllAsync leva 30-150 ms (medido); dispara e colhe no proximo PollState.
$script:connTask = $null
function ConnectedLE {
    try {
        if ($null -eq $script:connTask) {
            $sel = [Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelectorFromConnectionStatus('Connected')
            $script:connTask = $asTaskOp.MakeGenericMethod([Windows.Devices.Enumeration.DeviceInformationCollection]).Invoke($null, @([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($sel)))
            return $null
        }
        if (-not $script:connTask.IsCompleted) { return $null }
        $t = $script:connTask; $script:connTask = $null
        if ($t.IsFaulted) { return "erro ao listar ($($t.Exception.InnerException.Message))" }
        $names = @(); foreach ($d in $t.Result) { $names += "'$($d.Name)'" }
        if ($names.Count -eq 0) { 'nenhum' } else { ($names | Sort-Object) -join ', ' }
    } catch { $script:connTask = $null; "erro ao listar ($($_.Exception.Message))" }
}
$script:lastSubs = ''; $script:lastConn = $null; $script:lastAdv = ''
function PollState {
    [IPC]::Connected = [bool](Ready)
    $s = "teclado=$(SubCount $script:kbReport) ponteiro=$(SubCount $script:mouseReport) consumer=$(SubCount $script:consumerReport)"
    if ($s -ne $script:lastSubs) {
        $script:lastSubs = $s
        $color = if ((SubCount $script:mouseReport) -gt 0) { 'Green' } else { 'Yellow' }
        Log "Inscritos: $s" $color
    }
    $conn = ConnectedLE
    if ($null -ne $conn -and $conn -ne $script:lastConn) { $script:lastConn = $conn; Log "Conectados via BLE neste PC: $conn" 'Cyan' }
    $adv = [string]$script:provider.AdvertisementStatus
    if ($adv -ne $script:lastAdv) { $script:lastAdv = $adv; Log "Anuncio: $adv" 'Cyan' }
}

# ======================================================================================================
# Envio de relatorios
# ======================================================================================================
$NotifyResultT = [Type]"System.Collections.Generic.IReadOnlyList``1[[$G.GattClientNotificationResult, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]]"
$script:nCount = 0; $script:nTotalMs = 0.0; $script:nMaxMs = 0.0   # tempo de cada notificacao BLE (status mostra)
function NotifyOn($char, [byte[]]$bytes) {
    $nsw = [Diagnostics.Stopwatch]::StartNew()
    $results = Await ($char.NotifyValueAsync((Buf $bytes))) $NotifyResultT
    $ms = $nsw.Elapsed.TotalMilliseconds; $script:nCount++; $script:nTotalMs += $ms; if ($ms -gt $script:nMaxMs) { $script:nMaxMs = $ms }
    $ok = 0
    foreach ($r in $results) { if ([string]$r.Status -eq 'Success') { $ok++ } else { Log "  envio falhou: $($r.Status) (ATT $($r.ProtocolError))" 'Red' } }
    $ok
}

# ---------- teclado (igual a v2) ----------
$SHIFT = 0x02; $ALT = 0x04; $GUI = 0x08
function Tap([byte]$mod, [byte]$key) {
    $ok = NotifyOn $script:kbReport ([byte[]]($mod, 0, $key, 0, 0, 0, 0, 0)); if ($KeyDelayMs -gt 0) { Start-Sleep -Milliseconds $KeyDelayMs }
    $null = NotifyOn $script:kbReport ([byte[]](0, 0, 0, 0, 0, 0, 0, 0)); if ($KeyDelayMs -gt 0) { Start-Sleep -Milliseconds $KeyDelayMs }
    $ok
}
function NotifyStats { if ($script:nCount -eq 0) { 'notificacoes: nenhuma ainda' } else { 'notificacoes BLE: {0} | media {1:N1} ms | max {2:N0} ms' -f $script:nCount, ($script:nTotalMs / $script:nCount), $script:nMaxMs } }
$plain = @{ [char]'0' = 0x27; [char]"`n" = 0x28; [char]"`t" = 0x2B; [char]' ' = 0x2C; [char]'-' = 0x2D; [char]'=' = 0x2E; [char]'[' = 0x2F; [char]']' = 0x30;
    [char]'\' = 0x31; [char]';' = 0x33; [char]"'" = 0x34; [char]'`' = 0x35; [char]',' = 0x36; [char]'.' = 0x37; [char]'/' = 0x38 }
$shifted = @{ [char]')' = 0x27; [char]'!' = 0x1E; [char]'@' = 0x1F; [char]'#' = 0x20; [char]'$' = 0x21; [char]'%' = 0x22; [char]'^' = 0x23; [char]'&' = 0x24;
    [char]'*' = 0x25; [char]'(' = 0x26; [char]'_' = 0x2D; [char]'+' = 0x2E; [char]'{' = 0x2F; [char]'}' = 0x30; [char]'|' = 0x31; [char]':' = 0x33;
    [char]'"' = 0x34; [char]'~' = 0x35; [char]'<' = 0x36; [char]'>' = 0x37; [char]'?' = 0x38 }
function BaseKey([char]$c) {
    $i = [int]$c
    if ($i -ge 97 -and $i -le 122) { return @(0, (4 + $i - 97)) }
    if ($i -ge 65 -and $i -le 90) { return @($SHIFT, (4 + $i - 65)) }
    if ($i -ge 49 -and $i -le 57) { return @(0, (0x1E + $i - 49)) }
    if ($plain.ContainsKey($c)) { return @(0, $plain[$c]) }
    if ($shifted.ContainsKey($c)) { return @($SHIFT, $shifted[$c]) }
    $null
}
$deadKey = @{ 0x0301 = 0x08; 0x0300 = 0x35; 0x0302 = 0x0C; 0x0303 = 0x11; 0x0308 = 0x18 }
function TypeChar([char]$c) {
    $k = BaseKey $c
    if ($k) { $null = Tap $k[0] $k[1]; return $true }
    if ([int]$c -eq 0xE7) { $null = Tap $ALT 0x06; return $true }
    if ([int]$c -eq 0xC7) { $null = Tap ($ALT -bor $SHIFT) 0x06; return $true }
    # acento solto (tecla morta + espaco no PC): Option+acento e depois espaco
    if ([int]$c -eq 0xB4) { $null = Tap $ALT 0x08; $null = Tap 0 0x2C; return $true }   # acento agudo solto
    if ([int]$c -eq 0xA8) { $null = Tap $ALT 0x18; $null = Tap 0 0x2C; return $true }   # trema solto
    $d = ([string]$c).Normalize([Text.NormalizationForm]::FormD)
    if ($d.Length -eq 2 -and $deadKey.ContainsKey([int]$d[1])) {
        $lk = BaseKey $d[0]
        if ($lk) { $null = Tap $ALT $deadKey[[int]$d[1]]; $null = Tap $lk[0] $lk[1]; return $true }
    }
    $false
}
function Ready { (SubCount $script:kbReport) -gt 0 -or (SubCount $script:mouseReport) -gt 0 }
function SendText([string]$s) {
    if (-not (Ready)) { return 'NAO ENVIADO: iPhone sem inscricao (inscritos = 0)' }
    $sent = 0; $skip = New-Object System.Collections.Generic.List[string]; $cancel = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [IPC]::CancelTyping = $false; [IPC]::Typing = $true
    try {
        for ($i = 0; $i -lt $s.Length; $i++) {
            if ([IPC]::CancelTyping) { $cancel = $true; break }
            $c = $s[$i]
            if ([char]::IsHighSurrogate($c) -and $i + 1 -lt $s.Length -and [char]::IsLowSurrogate($s[$i + 1])) {   # emoji etc.: nao tem tecla
                $skip.Add(('U+{0:X}' -f [char]::ConvertToUtf32($c, $s[$i + 1]))); $i++; continue
            }
            if (TypeChar $c) { $sent++ } else { $skip.Add(("'{0}' U+{1:X4}" -f $c, [int]$c)) }
        }
    } finally { [IPC]::Typing = $false; [IPC]::CancelTyping = $false }
    $msg = "ok $sent caractere(s) em $([int]$sw.ElapsedMilliseconds) ms"
    if ($sent -gt 0) { $msg += " ($([Math]::Round($sw.ElapsedMilliseconds / $sent, 1)) ms/caractere)" }
    if ($cancel) { $msg += " | CANCELADO (Esc / Ctrl+Shift+F12) com $($s.Length - $i) caractere(s) faltando" }
    if ($skip.Count) { $msg += " | sem tecla, pulados ($($skip.Count)): " + (($skip | Select-Object -Unique) -join ', ') }
    $msg
}
function PrepPaste([string]$t) {
    $t = $t -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $PasteNewlines) { $t = $t -replace "`n+", ' ' }
    $t
}
function DoPaste {
    $t = [IPC]::ClipboardText()
    if ($null -eq $t -or $t -eq '') { return "NAO ENVIADO: clipboard do PC sem texto ($([IPC]::ClipboardInfo))" }
    $info = " | origem: $([IPC]::ClipboardInfo)"
    $t = [IPC]::NormalizePaste($t)
    if ([IPC]::NormalizeInfo) { $info += " | ajustado: $([IPC]::NormalizeInfo)" }
    $t = PrepPaste $t
    if ($t.Trim() -eq '') { return "NAO ENVIADO: clipboard so tem espacos/invisiveis$info" }
    $cut = ''
    if ($t.Length -gt $PasteMax) { $cut = " | CORTADO: $($t.Length) -> $PasteMax caracteres (-PasteMax)"; $t = $t.Substring(0, $PasteMax) }
    (SendText $t) + $cut + $info
}
# so le e mostra o clipboard (diagnostico, nao digita nada)
function ClipInfo {
    $t = [IPC]::ClipboardText()
    if ($null -eq $t -or $t -eq '') { return "clipboard sem texto: $([IPC]::ClipboardInfo)" }
    $src = [IPC]::ClipboardInfo
    $n = PrepPaste ([IPC]::NormalizePaste($t))
    $prev = if ($n.Length -gt 80) { $n.Substring(0, 80) + '...' } else { $n }
    $bad = @(); for ($i = 0; $i -lt $n.Length; $i++) { if (-not (BaseKey $n[$i]) -and [int]$n[$i] -notin 0xE7, 0xC7, 0xB4, 0xA8) { $d = ([string]$n[$i]).Normalize([Text.NormalizationForm]::FormD); if (-not ($d.Length -eq 2 -and $deadKey.ContainsKey([int]$d[1]) -and (BaseKey $d[0]))) { $bad += ('U+{0:X4}' -f [int]$n[$i]) } } }
    "origem: $src | $($t.Length) -> $($n.Length) caracteres | ajustes: $(if ([IPC]::NormalizeInfo) { [IPC]::NormalizeInfo } else { 'nenhum' }) | sem tecla: $(if ($bad.Count) { ($bad | Select-Object -Unique) -join ', ' } else { 'nenhum' }) | inicio: $prev"
}
$keyNames = @{ enter = 0x28; esc = 0x29; backspace = 0x2A; tab = 0x2B; space = 0x2C; delete = 0x4C; right = 0x4F; left = 0x50; down = 0x51; up = 0x52 }
$modNames = @{ shift = 0x02; ctrl = 0x01; alt = 0x04; option = 0x04; cmd = 0x08 }
function SendKeyCombo([string]$combo, [int]$times = 1) {
    if (-not (Ready)) { return 'NAO ENVIADO: iPhone sem inscricao' }
    $mod = 0; $usage = 0
    foreach ($p in $combo.ToLower().Split('+')) {
        if ($modNames.ContainsKey($p)) { $mod = $mod -bor $modNames[$p] }
        elseif ($keyNames.ContainsKey($p)) { $usage = $keyNames[$p] }
        elseif ($p.Length -eq 1) { $k = BaseKey $p[0]; if ($k) { $mod = $mod -bor $k[0]; $usage = $k[1] } }
    }
    if ($usage -eq 0) { return "ERRO: tecla desconhecida '$combo' (use: $(($keyNames.Keys | Sort-Object) -join ', '), letra, ou cmd+v / shift+tab)" }
    for ($i = 0; $i -lt $times; $i++) { $null = Tap $mod $usage }
    'ok'
}
function ConsumerTap([int]$usage) {
    $ok = NotifyOn $script:consumerReport ([byte[]](($usage -band 0xFF), (($usage -shr 8) -band 0xFF))); Start-Sleep -Milliseconds 40
    $null = NotifyOn $script:consumerReport ([byte[]](0, 0)); Start-Sleep -Milliseconds 12
    $ok
}

# ---------- ponteiro ----------
$script:pu = 0.5; $script:pv = 0.5; $script:btn = 0
$script:relX = 0; $script:relY = 0   # modo relativo: posicao estimada em contagens HID desde o ultimo "zerar"
function Clamp01([double]$x) { [Math]::Max(0.0, [Math]::Min(1.0, $x)) }
function AbsReport([double]$u, [double]$v, [int]$btn, [int]$wheel = 0) {
    $x = [int][Math]::Round((Clamp01 $u) * 32767); $y = [int][Math]::Round((Clamp01 $v) * 32767)
    $script:pu = Clamp01 $u; $script:pv = Clamp01 $v
    NotifyOn $script:mouseReport ([byte[]]($btn, ($x -band 0xFF), ($x -shr 8), ($y -band 0xFF), ($y -shr 8), ($wheel -band 0xFF), 0))
}
function RelReport([int]$dx, [int]$dy, [int]$btn, [int]$wheel = 0) {
    NotifyOn $script:mouseReport ([byte[]]($btn, ($dx -band 0xFF), ($dy -band 0xFF), ($wheel -band 0xFF), 0))
}
function RelZero { for ($i = 0; $i -lt 40; $i++) { $null = RelReport -127 -127 $script:btn }; $script:relX = 0; $script:relY = 0 }
function RelMoveTo([double]$u, [double]$v) {
    $tx = [int][Math]::Round((Clamp01 $u) * $RelWidth); $ty = [int][Math]::Round((Clamp01 $v) * $RelHeight)
    while ($script:relX -ne $tx -or $script:relY -ne $ty) {
        $sx = [Math]::Max(-$RelStep, [Math]::Min($RelStep, $tx - $script:relX)); $sy = [Math]::Max(-$RelStep, [Math]::Min($RelStep, $ty - $script:relY))
        $null = RelReport $sx $sy $script:btn
        $script:relX += $sx; $script:relY += $sy
    }
    $script:pu = Clamp01 $u; $script:pv = Clamp01 $v
}
function RelReady { $RelWidth -gt 0 -and $RelHeight -gt 0 }
# iOS ignora X/Y num relatorio que muda o botao: primeiro posiciona, espera, depois aperta.
function PointerDown([double]$u, [double]$v) {
    if ($Relative) { if (-not (RelReady)) { return 'ERRO: modo relativo sem calibrar (-RelWidth/-RelHeight)' }; RelZero; RelMoveTo $u $v; Start-Sleep -Milliseconds 60; $script:btn = 1; $null = RelReport 0 0 1; return 'ok' }
    # posicao enviada 2x e espera maior: com o Bluetooth lento o aperto chegava antes e caia onde o ponteiro estava
    # (relato 2026-11-11: voltar abria o perfil, clique no campo comecava audio)
    $null = AbsReport $u $v 0; Start-Sleep -Milliseconds 45
    $null = AbsReport $u $v 0; Start-Sleep -Milliseconds 45
    $script:btn = 1; $null = AbsReport $u $v 1; 'ok'
}
function PointerMove([double]$u, [double]$v) {
    if ($Relative) { if (RelReady) { RelMoveTo $u $v }; return }
    $null = AbsReport $u $v $script:btn
}
function PointerUp {
    $script:btn = 0
    if ($Relative) { $null = RelReport 0 0 0 } else { $null = AbsReport $script:pu $script:pv 0 }
}
function DoTap([double]$u, [double]$v, [int]$holdMs = 60) {
    if (-not (Ready)) { return 'NAO ENVIADO: iPhone sem inscricao' }
    $r = PointerDown $u $v; if ($r -ne 'ok') { return $r }
    Start-Sleep -Milliseconds $holdMs; PointerUp; 'ok'
}
function DoSwipe([double]$u1, [double]$v1, [double]$u2, [double]$v2, [int]$ms = 300, [int]$holdMs = 0) {
    if (-not (Ready)) { return 'NAO ENVIADO: iPhone sem inscricao' }
    $r = PointerDown $u1 $v1; if ($r -ne 'ok') { return $r }
    $steps = [Math]::Max(5, [int]($ms / 16)); $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $steps; $i++) {
        $t = $i / $steps
        PointerMove ($u1 + ($u2 - $u1) * $t) ($v1 + ($v2 - $v1) * $t)
        $wait = [int]($ms * $t - $sw.ElapsedMilliseconds); if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    }
    if ($holdMs -gt 0) { Start-Sleep -Milliseconds $holdMs }   # segura parado antes de soltar (alternador de apps)
    PointerUp; 'ok'
}
# Rolagem = swipe (o iOS ignorou a roda HID no WhatsApp; swipe rolou, teste 2026-11-10).
# ticks < 0 (roda pra baixo) = dedo sobe = conteudo anda pra baixo. Distancia = |ticks| * ScrollStep, max 0.6 da altura.
function DoScrollSwipe([int]$ticks, [double]$u, [double]$v) {
    if ($ticks -eq 0) { return 'ok (0 ticks)' }
    # faixa segura: swipe perto do topo abre Central de Controle/Notificacoes, perto da base vai pra Home
    $lo = 0.2; $hi = 0.85
    $d = [Math]::Min($hi - $lo, [Math]::Abs($ticks) * $ScrollStep)
    $dir = if ($ticks -lt 0) { -1 } else { 1 }
    $u = [Math]::Max(0.1, [Math]::Min(0.9, $u))
    $v1 = [Math]::Max($lo, [Math]::Min($hi, $v))
    if ($dir -lt 0 -and $v1 - $d -lt $lo) { $v1 = $lo + $d }
    if ($dir -gt 0 -and $v1 + $d -gt $hi) { $v1 = $hi - $d }
    DoSwipe $u $v1 $u ($v1 + $dir * $d) $ScrollMs
}
# Rodinha "segurando": o dedo encosta no 1o tick, acompanha cada tick enquanto a rodinha gira e so solta
# quando ela para (~220 ms). Sem o "clica e solta" de um swipe por tick. Ao chegar na borda da faixa segura,
# para, solta e reencosta do outro lado (parado antes de soltar = sem arremesso por inercia).
function WheelDrag([int]$ticks, [double]$u) {
    if (-not (Ready)) { return 'NAO ENVIADO: iPhone sem inscricao' }
    $lo = 0.2; $hi = 0.85
    $u = [Math]::Max(0.1, [Math]::Min(0.9, $u))
    $y = if ($ticks -lt 0) { $hi } else { $lo }     # comeca na ponta oposta ao movimento = curso maximo
    $down = $false
    $pending = [double]$ticks * $ScrollStep
    $idle = [Diagnostics.Stopwatch]::StartNew(); $more = $null
    while ($true) {
        while ([Math]::Abs($pending) -gt 0.0001) {
            if (-not $down) {
                # encosta e ja sai andando >= 0.06: dedo parado depois de encostar vira toque longo (abre menu da mensagem)
                $r = PointerDown $u $y; if ($r -ne 'ok') { return $r }
                $down = $true
                if ([Math]::Abs($pending) -lt 0.06) { $pending = [Math]::Sign($pending) * 0.06 }
            }
            $stepV = [Math]::Sign($pending) * [Math]::Min(0.02, [Math]::Abs($pending))
            $ny = $y + $stepV
            if ($ny -lt $lo -or $ny -gt $hi) {
                # fim do curso: para, solta e reencosta do outro lado so quando houver movimento de novo
                Start-Sleep -Milliseconds 40; PointerUp; $down = $false
                $y = if ($stepV -lt 0) { $hi } else { $lo }
                continue
            }
            $y = $ny; $pending -= $stepV
            PointerMove $u $y; Start-Sleep -Milliseconds 8
        }
        $more = $null
        if ([IPC]::Events.TryPeek([ref]$more) -and $more.StartsWith('wheel ')) {
            $null = [IPC]::Events.TryDequeue([ref]$more); $pending += [int]($more.Split(' ')[1]) * $ScrollStep; $idle.Restart()
        } elseif ($more -and -not $more.StartsWith('wheel') ) { break }
        elseif ($idle.ElapsedMilliseconds -gt 220) { break }
        else { Start-Sleep -Milliseconds 8 }
    }
    if ($down) { PointerUp }
    'ok'
}
# Rolagem pela rodinha HID de verdade, sem botao apertado: nunca vira toque. O swipe (dedo encosta e arrasta) as vezes
# era lido como toque e abria o item embaixo do cursor (relato do Caio, 2026-11-10); a rodinha HID rolou o WhatsApp no teste.
# ticks do Windows: negativo = rodinha pra baixo = conteudo anda pra baixo -> no iPhone isso e roda HID positiva.
function HidWheel([int]$ticks, [double]$u, [double]$v) {
    if ($ticks -eq 0) { return 'ok (0 ticks)' }
    if (-not (Ready)) { return 'NAO ENVIADO: iPhone sem inscricao' }
    $s = - [Math]::Sign($ticks); $n = [Math]::Min(60, [Math]::Max(8, [Math]::Abs($ticks) * $WheelUnits))   # menos de ~8 unidades o iOS nao rola (teste: 6 nao mexeu, 10 rolou)
    $null = AbsReport $u $v 0
    for ($k = 0; $k -lt $n; $k++) { $null = AbsReport $u $v 0 $s; Start-Sleep -Milliseconds 12 }
    $null = AbsReport $u $v 0 0
    'ok'
}
function DoWheel([int]$dir, [double]$u, [double]$v) {
    if ($Relative) { $null = RelReport 0 0 $script:btn $dir } else { $null = AbsReport $u $v $script:btn $dir }
}

# ---------- navegacao: voltar, alternador de apps, abrir app pelo Spotlight ----------
# voltar = toque no "<" do canto superior esquerdo. O swipe da borda esquerda NAO voltou no WhatsApp com o ponteiro
# do AssistiveTouch (teste 2026-11-10), por isso e toque. 'voltar x y' usa outra posicao so dessa vez.
function DoBack([double]$u = $BackX, [double]$v = $BackY) {
    if (-not (Ready)) { return 'NAO ENVIADO: iPhone sem inscricao' }
    $r = DoTap $u $v
    if ($r -eq 'ok') { return ('ok toque em {0:0.000} {1:0.000} (botao "<"; se nao voltou: voltar x y, ou -BackX/-BackY)' -f $u, $v) }
    $r
}
# alternador de apps = deslizar da base ate o meio e segurar parado antes de soltar
function DoAppSwitcher { DoSwipe 0.5 0.995 0.5 0.6 300 600 }
# abrir <app>: Home primeiro (se o Spotlight nao abrir, o texto nao cai numa conversa), Cmd+Espaco, digita, Enter.
function OpenApp([string]$name) {
    if (-not (Ready)) { return 'NAO ENVIADO: iPhone sem inscricao' }
    $name = ($name -replace '[\r\n]+', ' ').Trim()
    if ($name -eq '') { return 'ERRO: use abrir <nome do app>, ex.: abrir whatsapp' }
    $null = ConsumerTap 0x0040; Start-Sleep -Milliseconds 700          # tela inicial
    $null = Tap $GUI 0x2C; Start-Sleep -Milliseconds 700              # Cmd+Espaco = Spotlight
    $r = SendText $name
    if ($r -notlike 'ok*') { return "parou antes do Enter: $r" }
    Start-Sleep -Milliseconds 900                                       # resultados do Spotlight
    $null = Tap 0 0x28                                                  # Enter abre o 1o resultado
    "ok Home + Cmd+Espaco + '$name' + Enter (se nao abriu: o Spotlight nao abriu ou o 1o resultado era outro)"
}

# ---------- respostas prontas: respostas.txt (nome = texto), uma por linha; nunca aperta Enter ----------
$respFile = Join-Path $here 'respostas.txt'
$respExample = Join-Path $here 'respostas.exemplo.txt'
function ParseRespostas([string[]]$lines) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($ln in $lines) {
        $t = ([string]$ln).Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $p = $t.IndexOf('='); if ($p -le 0) { continue }
        $nome = $t.Substring(0, $p).Trim().ToLower(); $texto = $t.Substring($p + 1).Trim()
        if ($nome -ne '' -and $texto -ne '') { $out.Add([pscustomobject]@{ Nome = $nome; Texto = $texto }) }
    }
    , $out
}
function LoadRespostas {
    # respostas.txt e seu (fica fora do git); na primeira vez copia o exemplo
    if (-not (Test-Path -LiteralPath $respFile) -and (Test-Path -LiteralPath $respExample)) { try { Copy-Item -LiteralPath $respExample -Destination $respFile } catch {} }
    if (-not (Test-Path -LiteralPath $respFile)) { return , (New-Object System.Collections.Generic.List[object]) }
    ParseRespostas @(Get-Content -LiteralPath $respFile -Encoding UTF8)
}
function ListRespostas {
    $rs = LoadRespostas
    if ($rs.Count -eq 0) { return "nenhuma resposta em $respFile (formato: nome = texto)" }
    $i = 0; ($rs | ForEach-Object { $i++; $prev = if ($_.Texto.Length -gt 30) { $_.Texto.Substring(0, 30) + '...' } else { $_.Texto }; $(if ($i -le 9) { "Ctrl+Shift+$i " } else { '' }) + "/r $($_.Nome) = $prev" }) -join ' | '
}
function SendResposta($r) {
    $t = [IPC]::NormalizePaste($r.Texto) -replace '[\r\n]+', ' '      # sem quebra de linha: nunca vira Enter
    (SendText $t) + " (resposta '$($r.Nome)', sem Enter)"
}
function ReplyByName([string]$name) {
    $name = $name.Trim().ToLower()
    if ($name -eq '') { return ListRespostas }
    $rs = LoadRespostas
    $r = $rs | Where-Object { $_.Nome -eq $name } | Select-Object -First 1
    if (-not $r) { return "ERRO: resposta '$name' nao existe em respostas.txt (/r lista)" }
    SendResposta $r
}
function ReplyByIndex([int]$n) {
    $rs = LoadRespostas
    if ($n -lt 1 -or $n -gt $rs.Count) { return "ERRO: nao ha resposta $n em respostas.txt ($($rs.Count) resposta(s))" }
    SendResposta $rs[$n - 1]
}

# ---------- sugerir.ps1: processo separado, sem travar o loop ----------
function StartSugerir {
    $p = Join-Path $here 'sugerir.ps1'
    if (-not (Test-Path -LiteralPath $p)) { return 'sugerir.ps1 nao encontrado' }
    try {
        $pr = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$p`"") -PassThru
        "ok sugerir.ps1 iniciado em segundo plano (PID $($pr.Id))"
    } catch { "ERRO ao iniciar sugerir.ps1: $($_.Exception.Message)" }
}

# ---------- proporcao do video salva (.tmp\proporcao.txt, so local) ----------
# O iPhone tem uma proporcao fixa: retrato = a, paisagem = 1/a. Guardar a confirmada evita comecar "cheia"
# e deixa a leitura com faixas pretas (que oscila 0,4617..0,4629) cair exatamente no valor salvo.
$aspectFile = Join-Path $tmpDir 'proporcao.txt'
$script:savedAspect = 0.0; $script:aspectCand = 0.0
function LoadSavedAspect {
    try { $t = (Get-Content -LiteralPath $aspectFile -ErrorAction Stop | Select-Object -First 1).Trim(); $x = N $t; if ($x -gt 0.3 -and $x -lt 0.9) { return $x } } catch {}
    0.0
}
# Pura: leitura -> proporcao retrato equivalente (0 = sem faixas / desconhecida)
function PortraitOf([double]$a) { if ($a -le 0) { 0.0 } elseif ($a -lt 1) { $a } else { 1.0 / $a } }
# Pura: se a leitura bate (5%) com a salva (retrato ou paisagem), devolve o valor salvo exato; senao a propria leitura
function SnapAspect([double]$a, [double]$saved) {
    if ($a -le 0 -or $saved -le 0) { return $a }
    $exp = if ($a -lt 1) { $saved } else { 1.0 / $saved }
    if ([Math]::Abs($a - $exp) / $exp -lt 0.05) { $exp } else { $a }
}
# Grava so quando duas leituras com faixas seguidas concordam (1%): uma tela escura sozinha nao estraga o valor salvo.
function NoteAspect([double]$a) {
    $pa = PortraitOf $a
    if ($pa -le 0.3 -or $pa -ge 0.9) { return }
    if ($script:aspectCand -gt 0 -and [Math]::Abs($pa - $script:aspectCand) / $script:aspectCand -lt 0.01) {
        if ($script:savedAspect -le 0 -or [Math]::Abs($pa - $script:savedAspect) / $script:savedAspect -gt 0.005) {
            try { New-Item -ItemType Directory -Force $tmpDir | Out-Null; Set-Content -LiteralPath $aspectFile -Value ($pa.ToString('0.0000', [Globalization.CultureInfo]::InvariantCulture)) -Encoding ASCII; $script:savedAspect = $pa; Log ("Proporcao salva: {0:0.0000} (retrato)" -f $pa) 'Cyan' } catch {}
        }
    }
    $script:aspectCand = $pa
}

# ======================================================================================================
# Comandos (console e canal local 127.0.0.1)
# ======================================================================================================
# uxplay-bluetooth-beacon disputa o radio BLE com o teclado/ponteiro: avisa no status e no inicio
function BeaconWarn { $b = @(Get-Process -Name 'uxplay-bluetooth-beacon' -ErrorAction SilentlyContinue); if ($b.Count) { " | AVISO: uxplay-bluetooth-beacon rodando ($($b.Count)x, PID $(($b | ForEach-Object { $_.Id }) -join ',')): disputa o Bluetooth, feche se o toque/teclado falhar" } else { '' } }
function N([string]$s) { [double]::Parse($s, [Globalization.CultureInfo]::InvariantCulture) }
function HandleCommand([string]$line) {
    $line = $line.Trim()
    if ($line -eq '') { return 'vazio' }
    $parts = $line -split '\s+', 2
    $cmd = $parts[0].ToLower(); $rest = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    $a = @($rest -split '\s+' | Where-Object { $_ -ne '' })
    try {
        switch ($cmd) {
            'type' { $t = $rest; if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) { $t = $t.Substring(1, $t.Length - 2) }; return (SendText $t) }
            'key' { $n = if ($a.Count -gt 1) { [int]$a[1] } else { 1 }; return (SendKeyCombo $a[0] $n) }
            'tap' { return (DoTap (N $a[0]) (N $a[1])) }
            'longpress' { $ms = if ($a.Count -gt 2) { [int]$a[2] } else { 800 }; return (DoTap (N $a[0]) (N $a[1]) $ms) }
            'swipe' { $ms = if ($a.Count -gt 4) { [int]$a[4] } else { 300 }; return (DoSwipe (N $a[0]) (N $a[1]) (N $a[2]) (N $a[3]) $ms) }
            'scroll' { $d = [int]$a[0]; $u = if ($a.Count -gt 2) { N $a[1] } else { 0.5 }; $v = if ($a.Count -gt 2) { N $a[2] } else { 0.5 }
                if (-not (Ready)) { return 'NAO ENVIADO: iPhone sem inscricao' }; return (HidWheel $d $u $v) }
            'hwheel' {   # rodinha HID de verdade (sem botao: nunca vira toque). hwheel n [x y] [ms entre relatorios]
                $d = [int]$a[0]; $u = if ($a.Count -ge 3) { N $a[1] } else { 0.5 }; $v = if ($a.Count -ge 3) { N $a[2] } else { 0.5 }
                $gap = if ($a.Count -ge 4) { [int]$a[3] } else { 25 }
                if (-not (Ready)) { return 'NAO ENVIADO: iPhone sem inscricao' }
                $null = AbsReport $u $v 0; Start-Sleep -Milliseconds 40
                $s = [Math]::Sign($d); for ($k = 0; $k -lt [Math]::Abs($d); $k++) { $null = AbsReport $u $v 0 $s; Start-Sleep -Milliseconds $gap }
                $null = AbsReport $u $v 0 0; return "ok hwheel $d" }
            'home' { if (-not (Ready)) { return 'NAO ENVIADO: iPhone sem inscricao' }; $null = ConsumerTap 0x0040; return 'ok (consumer 0x0040; se nao voltar pra tela inicial use: homeswipe)' }
            'homeswipe' { return (DoSwipe 0.5 0.995 0.5 0.55 250) }
            'voltar' { if ($a.Count -ge 2) { return (DoBack (N $a[0]) (N $a[1])) }; return (DoBack) }
            'apps' { return (DoAppSwitcher) }
            'abrir' { return (OpenApp $rest) }
            { $_ -in '/r', 'r', 'resposta' } { return (ReplyByName $rest) }
            'respostas' { return (ListRespostas) }
            'sugerir' { return (StartSugerir) }
            'paste' { return (DoPaste) }
            'zero' { if (-not $Relative) { return 'so no modo relativo' }; RelZero; return 'ok cursor no canto superior esquerdo' }
            'relmove' { if (-not $Relative) { return 'so no modo relativo' }; $dx = [int]$a[0]; $dy = [int]$a[1]
                while ($dx -ne 0 -or $dy -ne 0) { $sx = [Math]::Max(-$RelStep, [Math]::Min($RelStep, $dx)); $sy = [Math]::Max(-$RelStep, [Math]::Min($RelStep, $dy)); $null = RelReport $sx $sy 0; $dx -= $sx; $dy -= $sy }; return 'ok' }
            'screenshot' {
                # so grava dentro da pasta .tmp do app (o canal local nao escreve em caminho qualquer)
                $p = $ScreenshotPath
                if ($rest -ne '') {
                    $base = [IO.Path]::GetFullPath($tmpDir).TrimEnd('\') + '\'
                    $p = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($rest)) { $rest } else { Join-Path $tmpDir $rest }))
                    if (-not $p.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($p) -ne '.png') { return "ERRO: screenshot so grava .png dentro de $base" }
                }
                return ([IPC]::Screenshot($p)) }
            'clip' { return (ClipInfo) }
            'calibrate' { return ([IPC]::DetectAspect() + ' | ' + [IPC]::Describe()) }
            'fit' {
                if ($a.Count -and $a[0] -eq 'on') { [IPC]::AutoFit = $true; [IPC]::FitReason = 'religado'; [IPC]::FitRequest = $true; [IPC]::FitStatus = 'ligado'; return 'afixar ligado' }
                if ($a.Count -and $a[0] -eq 'off') { [IPC]::AutoFit = $false; [IPC]::FitStatus = 'desligado'; return 'afixar desligado' }
                if ($a.Count -and $a[0] -eq 'plan') { return ([IPC]::FitNow($false)) }
                return ([IPC]::FitNow($true)) }
            'topo' {
                if ($a.Count -and $a[0] -eq 'on') { [IPC]::MirrorTopmost = $true } elseif ($a.Count -and $a[0] -eq 'off') { [IPC]::MirrorTopmost = $false } else { [IPC]::MirrorTopmost = -not [IPC]::MirrorTopmost }
                [IPC]::ApplyTopmost(); return "espelho sempre no topo $(if ([IPC]::MirrorTopmost) { 'ligado' } else { 'desligado' })" }
            'estado' {
                # resumo curto para o painel (chave=valor separados por espaco)
                $d = [IPC]::Describe(); $win = if ($d -like 'janela*nao encontrada') { 0 } else { 1 }
                return "ponteiro=$(SubCount $script:mouseReport) teclado=$(SubCount $script:kbReport) janela=$win captura=$(if ([IPC]::Enabled) { 1 } else { 0 }) topo=$(if ([IPC]::MirrorTopmost) { 1 } else { 0 }) anuncio=$($script:provider.AdvertisementStatus) pid=$PID" }
            { $_ -in 'quit', 'sair' } { $script:quitRequested = $true; return 'ok saindo' }
            'on' { [IPC]::Enabled = $true; return 'captura ligada' }
            'off' { [IPC]::Enabled = $false; return 'captura desligada' }
            'status' { return "modo=$(if ($Relative) { 'relativo' } else { 'absoluto' }) captura=$(if ([IPC]::Enabled) { 'on' } else { 'off' }) $($script:lastSubs) | $([IPC]::Describe()) | hooks: $([IPC]::HookStatus) | anuncio: $($script:provider.AdvertisementStatus) | $(NotifyStats) | KeyDelayMs=$KeyDelayMs | topo=$(if ([IPC]::MirrorTopmost) { 'on' } else { 'off' }) | afixar=$(if ([IPC]::AutoFit) { 'on' } else { 'off' }) ($([IPC]::FitStatus)) | indicador: $([IPC]::OverlayStatus) | proporcao salva: $(if ($script:savedAspect -gt 0) { '{0:0.0000}' -f $script:savedAspect } else { 'nenhuma' }) | voltar em $BackX $BackY$(BeaconWarn)" }
            'help' { return 'type <texto> | key enter|backspace|tab|esc|space|delete|up|down|left|right|cmd+a [n] | tap x y | longpress x y [ms] | swipe x1 y1 x2 y2 [ms] | scroll n [x y] | home | homeswipe | voltar [x y] | apps | abrir <app> | /r [nome] (resposta pronta, sem Enter) | respostas | sugerir | paste (clipboard do PC; Esc cancela) | clip (mostra o clipboard sem digitar) | screenshot [nome.png em .tmp] | calibrate | fit [on|off|plan] | topo [on|off] | on | off | status | estado | quit   (x,y de 0 a 1 na area de video)' }
        }
    } catch { return "ERRO: $($_.Exception.Message)" }
    "ERRO: comando desconhecido '$cmd' (help)"
}

# Eventos vindos dos hooks (clique/arraste/teclas na janela do espelho)
$script:lastWarn = [DateTime]::MinValue
function ProcessHookEvents {
    $list = New-Object System.Collections.Generic.List[string]
    $ev = $null
    while ([IPC]::Events.TryDequeue([ref]$ev)) { $list.Add($ev) }
    if ($list.Count -eq 0) { return $false }
    for ($i = 0; $i -lt $list.Count; $i++) {
        $e = $list[$i]
        if ($e.StartsWith('move ') -and $i + 1 -lt $list.Count -and $list[$i + 1].StartsWith('move ')) { continue }   # junta movimentos
        if ($e.StartsWith('hover ') -and $i + 1 -lt $list.Count -and $list[$i + 1].StartsWith('hover ')) { continue } # so a posicao mais nova
        $p = $e.Split(' ')
        if ($p[0] -eq 'toggle') { Log "Captura: $($p[1]) (Ctrl+Shift+F12)" 'Cyan'; continue }
        if ($p[0] -eq 'topmost') { Log "Espelho sempre no topo: $($p[1]) (Ctrl+Shift+F11)" 'Cyan'; continue }
        if ($p[0] -eq 'fit') { Log "Afixar na altura da tela: $($p[1]) (Ctrl+Shift+F10)" 'Cyan'; continue }
        if ($p[0] -eq 'fitlog') { Log $e.Substring(7) 'Cyan'; continue }
        if ($p[0] -eq 'wheeldiag') { Log $e.Substring(10) $(if ($e -like '*IGNORADA*') { 'Yellow' } else { 'DarkGray' }); continue }
        if ($p[0] -eq 'stuck') { Log "Dedo preso solto: $($e.Substring(6))" 'Yellow'; continue }
        if ($p[0] -eq 'suggest') { Log "Ctrl+Shift+S -> $(StartSugerir)" 'Cyan'; continue }
        if (-not (Ready)) {
            if (((Get-Date) - $script:lastWarn).TotalSeconds -gt 3) { $script:lastWarn = Get-Date; Log 'Evento ignorado: iPhone sem inscricao (pareado e conectado?)' 'Yellow' }
            continue
        }
        switch ($p[0]) {
            'down' { $r = PointerDown (N $p[1]) (N $p[2]); if ($r -ne 'ok') { Log $r 'Yellow' } }
            'move' { PointerMove (N $p[1]) (N $p[2]) }
            'hover' { if ($script:btn -eq 0) { $null = AbsReport (N $p[1]) (N $p[2]) 0 } }
            'up' { if ($p.Count -ge 3) { PointerMove (N $p[1]) (N $p[2]) }; PointerUp }
            'wheel' {
                # junta os ticks seguidos (deste lote + os que chegarem em 80 ms) num swipe so.
                # E o comportamento da 1a versao, que funcionava; o WheelDrag (dedo segurando) nao rolou (teste 2026-11-10).
                $ticks = [int]$p[1]; $wu = N $p[2]; $wv = N $p[3]
                while ($i + 1 -lt $list.Count -and $list[$i + 1].StartsWith('wheel ')) { $i++; $ticks += [int]($list[$i].Split(' ')[1]) }
                if ($i + 1 -ge $list.Count) {
                    $sw = [Diagnostics.Stopwatch]::StartNew(); $more = $null
                    while ($sw.ElapsedMilliseconds -lt 80) {
                        if ([IPC]::Events.TryPeek([ref]$more) -and $more.StartsWith('wheel ')) { $null = [IPC]::Events.TryDequeue([ref]$more); $ticks += [int]($more.Split(' ')[1]); $sw.Restart() }
                        elseif ($more -and -not $more.StartsWith('wheel')) { break }
                        else { Start-Sleep -Milliseconds 5 }
                        $more = $null
                    }
                }
                $null = HidWheel $ticks $wu $wv
            }
            'key' { $null = Tap ([byte][int]$p[2]) ([byte][int]$p[1]) }
            'text' { foreach ($c in $e.Substring(5).ToCharArray()) { if (-not (TypeChar $c)) { Log "Sem mapa para '$c'" 'Yellow' } } }
            'paste' { $r = DoPaste; Log "Ctrl+V -> $r" $(if ($r -like 'ok*') { 'Gray' } else { 'Yellow' }) }
            'back' { $r = DoBack; Log "Esc -> voltar: $r" $(if ($r -like 'ok*') { 'Gray' } else { 'Yellow' }) }
            'reply' { $r = ReplyByIndex ([int]$p[1]); Log "Ctrl+Shift+$($p[1]) -> $r" $(if ($r -like 'ok*') { 'Gray' } else { 'Yellow' }) }
        }
    }
    $true
}

# Proporcao do video: tenta detectar faixas pretas quando a janela aparece ou muda de tamanho,
# e confere a cada ciclo se o video girou (retrato <-> paisagem) dentro da mesma janela.
$script:aspectKey = ''; $script:aspectDone = $false; $script:flipCount = 0
function CheckWindow {
    $d = [IPC]::Describe()
    $key = ($d -split ';')[0]
    if ($key -ne $script:aspectKey) { $script:aspectKey = $key; $script:aspectDone = $false; $script:flipCount = 0; Log "Janela: $d" 'Cyan' }
    if ($VideoAspect -gt 0 -or $d -notlike 'cliente*') { return }
    if (-not $script:aspectDone) {
        $r = [IPC]::DetectAspect()
        if ($r -like 'ok*') {
            $raw = [IPC]::VideoAspect; NoteAspect $raw; [IPC]::VideoAspect = SnapAspect $raw $script:savedAspect
            $script:aspectDone = $true; Log "Area de video: $r | $([IPC]::Describe())" 'Cyan'; [IPC]::AspectChanged()
        }
        return
    }
    $na = 0.0; $info = ''
    $peek = [IPC]::PeekAspect([ref]$na, [ref]$info)
    if ($peek -and $na -gt 0) { NoteAspect $na }
    if ($peek -and (([IPC]::EffectiveAspect($na) -lt 1) -ne ([IPC]::EffectiveAspect([IPC]::VideoAspect) -lt 1))) {
        $script:flipCount++                                    # 2 leituras seguidas antes de aceitar (tela escura engana)
        if ($script:flipCount -ge 2) { [IPC]::VideoAspect = SnapAspect $na $script:savedAspect; $script:flipCount = 0; Log "Video girou: $info | $([IPC]::Describe())" 'Cyan'; [IPC]::AspectChanged() }
    } else { $script:flipCount = 0 }
}

# ======================================================================================================
# SelfTest: valida o que da sem iPhone
# ======================================================================================================
if ($SelfTest -or $SelfTestAdvertise) {
    $fail = 0
    function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Log "PASS $name $detail" 'Green' } else { Log "FAIL $name $detail" 'Red'; $script:fail++ } }

    # 1. descritor
    $pm = ParseReportMap $reportMap
    Check 'Report Map: colecoes fechadas' ($pm.Depth -eq 0 -and $pm.End -eq $reportMap.Length) "($($reportMap.Length) bytes)"
    Check 'Report Map: ID 1 teclado = 8 bytes' ($pm.InBits[1] -eq 64) "($($pm.InBits[1]) bits)"
    Check "Report Map: ID 2 ponteiro = $mouseLen bytes" ($pm.InBits[2] -eq 8 * $mouseLen) "($($pm.InBits[2]) bits)"
    Check 'Report Map: ID 3 consumer = 2 bytes' ($pm.InBits[3] -eq 16) "($($pm.InBits[3]) bits)"
    $kbRef = Join-Path $here 'ble-keyboard-test\ble-keyboard.ps1'   # mesmo descritor de teclado
    try {
        $v2 = Get-Content $kbRef -Raw -ErrorAction Stop
        $v2map = if ($v2 -match '(?s)\$reportMap = @\((.*?)\)') { @([regex]::Matches($Matches[1], '0x[0-9A-Fa-f]{2}') | ForEach-Object { [Convert]::ToInt32($_.Value, 16) }) } else { @() }
        Check 'Teclado identico ao ble-keyboard.ps1' (($v2map -join ',') -eq ($kbMap -join ',')) "($($kbMap.Count) bytes; referencia = $($v2map.Count))"
    } catch { Log "Teclado: referencia $kbRef nao encontrada, comparacao pulada." 'Yellow' }

    # 1b. clipboard: leitura (texto e so-HTML) e normalizacao, sem iPhone
    $C = { param([int]$x) [string][char]$x }   # o .ps1 e lido como ANSI no PS 5.1: caracteres especiais por codigo
    $nz = [IPC]::NormalizePaste("a$(& $C 0xA0)b`t$(& $C 0x201C)c$(& $C 0x201D) $(& $C 0x2018)d$(& $C 0x2019) e$(& $C 0x2014)f$(& $C 0x2013)g$(& $C 0x200B)h$(& $C 0x2026)")
    Check 'Normaliza colar (NBSP, tab, aspas, travessao, invisivel, reticencias)' ($nz -ceq "a b `"c`" 'd' e-f-gh...") "('$nz' | $([IPC]::NormalizeInfo))"
    $hb = [Text.Encoding]::UTF8.GetBytes("Version:0.9`r`nStartHTML:-1`r`nEndHTML:-1`r`nStartFragment:0000000000`r`nEndFragment:0000000000`r`n<html><body><!--StartFragment--><p>Ol&aacute; <b>mundo</b>&nbsp;&amp; cia</p><!--EndFragment--></body></html>")
    $ht = [IPC]::HtmlToText($hb)
    Check 'HTML Format -> texto' ($ht -ceq "Ol$(& $C 0xE1) mundo$(& $C 0xA0)& cia") "('$ht')"

    # 1c. respostas prontas e proporcao salva (funcoes puras)
    $rs = ParseRespostas @('# comentario', '', 'ok = Combinado, ja te retorno', 'Endereco=Rua Exemplo, 123 = fundos', 'sem igual', '=sem nome', 'vazio =')
    Check 'Respostas: le nome = texto (ignora comentario, vazio, sem nome)' ($rs.Count -eq 2 -and $rs[0].Nome -eq 'ok' -and $rs[0].Texto -eq 'Combinado, ja te retorno' -and $rs[1].Nome -eq 'endereco' -and $rs[1].Texto -eq 'Rua Exemplo, 123 = fundos') "($($rs.Count) respostas)"
    if (Test-Path -LiteralPath $respExample) { $ex = ParseRespostas @(Get-Content -LiteralPath $respExample -Encoding UTF8); Check 'respostas.exemplo.txt le sem erro' ($ex.Count -ge 1) "($($ex.Count) respostas)" }
    Check 'Proporcao: leitura perto da salva vira a salva (retrato e paisagem)' ((SnapAspect 0.4629 0.4617) -eq 0.4617 -and [Math]::Abs((SnapAspect 2.17 0.4617) - 1 / 0.4617) -lt 1e-9) "($(SnapAspect 0.4629 0.4617), $(SnapAspect 2.17 0.4617))"
    Check 'Proporcao: leitura longe da salva fica como veio' ((SnapAspect 0.75 0.4617) -eq 0.75 -and (SnapAspect 0 0.4617) -eq 0 -and (PortraitOf 2.0) -eq 0.5) ''

    # 2. conta da area de video
    $q = [IPC]::ComputeVideoRect(489, 990, 0.4618)
    Check 'Letterbox horizontal' ($q[1] -eq 0 -and $q[3] -eq 990 -and [Math]::Abs($q[2] - 457) -le 1 -and [Math]::Abs($q[0] - 16) -le 1) "($($q -join ','))"
    $q = [IPC]::ComputeVideoRect(800, 400, 1.0)
    Check 'Letterbox lateral' ($q[0] -eq 200 -and $q[2] -eq 400) "($($q -join ','))"
    $q = [IPC]::ComputeVideoRect(300, 900, 0.5)
    Check 'Letterbox vertical' ($q[1] -eq 150 -and $q[3] -eq 600) "($($q -join ','))"

    # 2b. afixar na altura da tela (conta pura): area util 2560x1528, barra de titulo+bordas 2x31, margem 12
    $q = [IPC]::ComputeFit(0, 0, 2560, 1528, 2, 31, 0.4618, 12, 2400)
    Check 'Afixar retrato: altura util - margem, largura pela proporcao, dentro da tela' ($q[1] -eq 0 -and $q[3] -eq 1516 -and $q[2] -eq ([Math]::Round(1485 * 0.4618) + 2) -and $q[0] + $q[2] -le 2560 -and $q[0] -lt 2400) "($($q -join ','))"
    $q = [IPC]::ComputeFit(0, 0, 2560, 1528, 2, 31, 2.1655, 12, 300)
    Check 'Afixar paisagem: limita pela largura' ($q[2] -eq 2536 -and $q[3] -le 1516 -and $q[0] -eq 24) "($($q -join ','))"
    $q = [IPC]::ComputeFit(-1920, 40, 0, 1080, 2, 31, 0.4618, 8, -900)
    Check 'Afixar em monitor a esquerda (coordenada negativa)' ($q[0] -eq -900 -and $q[1] -eq 40 -and $q[3] -eq 1032) "($($q -join ','))"
    $bmp = New-Object System.Drawing.Bitmap 200, 400
    $gfx = [System.Drawing.Graphics]::FromImage($bmp); $gfx.Clear([System.Drawing.Color]::Black); $gfx.FillRectangle([System.Drawing.Brushes]::White, 20, 0, 160, 400); $gfx.Dispose()
    $asp = 0.0; $info = ''
    $okBars = [IPC]::DetectBars($bmp, [ref]$asp, [ref]$info)
    Check 'Detecta faixas pretas' ($okBars -and [Math]::Abs($asp - 0.4) -lt 0.01) "($info -> $asp)"
    $bmp.Dispose()

    # 3. teclado do PC -> caractere (layout atual do console)
    $hkl = [IPC]::LayoutOf([IPC]::ConsoleWindow())
    $upA = [IPC]::Translate(0x41, 0x1E, $true, $false, $hkl); $lowA = [IPC]::Translate(0x41, 0x1E, $false, $false, $hkl)
    Check 'Traducao de tecla (A/a)' ($upA -ceq 'A' -and $lowA -ceq 'a') "(layout 0x$('{0:X}' -f $hkl.ToInt64()), shift='$upA' sem='$lowA')"

    # 4. janela e screenshot
    $d = [IPC]::Describe(); Log "Janela '$WindowTitle': $d"
    if ($d -like 'cliente*') {
        Log "Deteccao de proporcao: $([IPC]::DetectAspect())"
        Log "Afixar (so o plano, nao mexe na janela): $([IPC]::FitNow($false))"
        $r = [IPC]::Screenshot($ScreenshotPath); Check 'Screenshot da janela do espelho' ($r -like 'ok*') $r
    } else {
        Log 'Janela do espelho nao aberta: testo a captura na janela deste console.' 'Yellow'
        $saved = [IPC]::Title; $con = [IPC]::ConsoleWindow()
        $sb = New-Object Text.StringBuilder 512
        Add-Type -Namespace W32 -Name T -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);'
        $null = [W32.T]::GetWindowText($con, $sb, 512)
        if ($sb.Length -gt 0) {
            [IPC]::Title = $sb.ToString()
            $r = [IPC]::Screenshot((Join-Path $tmpDir 'selftest-console.png')); Check 'Screenshot (janela do console)' ($r -like 'ok*') $r
            [IPC]::Title = $saved
        } else { Log 'Sem janela de console visivel: captura nao testada.' 'Yellow' }
    }

    # 5. hooks (captura desligada: nada e segurado)
    [IPC]::Enabled = $false
    [IPC]::StartHooks(); $hs = [IPC]::HookStatus
    Check 'Hooks low-level instalam' ($hs -eq 'mouse ok, teclado ok') "($hs)"
    [IPC]::StopHooks()

    # 6. canal local
    try {
        [IPC]::StartServer($Port)
        $tests = @(
            @{ n = 'HTTP com header -> 200'; t = [IPC]::TestClient($Port, 'help', $true, $null, "127.0.0.1:$Port"); want = '200' },
            @{ n = 'HTTP sem header -> 403'; t = [IPC]::TestClient($Port, 'help', $false, $null, "127.0.0.1:$Port"); want = '403' },
            @{ n = 'HTTP com Origin -> 403'; t = [IPC]::TestClient($Port, 'help', $true, 'http://evil.example', "127.0.0.1:$Port"); want = '403' },
            @{ n = 'HTTP Host estranho -> 403'; t = [IPC]::TestClient($Port, 'help', $true, $null, "evil.example:$Port"); want = '403' })
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ((@($tests | Where-Object { -not $_.t.IsCompleted })).Count -gt 0 -and $sw.ElapsedMilliseconds -lt 10000) {
            $req = $null; if ([IPC]::Requests.TryTake([ref]$req)) { $req.Resp = HandleCommand $req.Cmd; $req.Done.Set() } else { Start-Sleep -Milliseconds 10 }
        }
        foreach ($t in $tests) { $res = if ($t.t.IsCompleted) { $t.t.Result } else { 'timeout' }; Check $t.n ($res -like "HTTP/1.1 $($t.want)*") "($res)" }
        $ext = (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalAddress) -join ','
        Check 'Porta so em 127.0.0.1' ($ext -eq '127.0.0.1') "(escutando em: $ext)"
        [IPC]::StopServer()
    } catch { Check 'Canal local' $false $_.Exception.Message }

    # 7. GATT (cria o servico; so anuncia com -SelfTestAdvertise)
    try {
        PublishGatt
        Check 'GATT composto publicado (3 Input Reports 0x2A4D)' $true
        if ($SelfTestAdvertise) {
            $ok = StartAdv; Check 'Anuncio BLE' $ok
            Start-Sleep -Seconds 5; PollState
            $script:provider.StopAdvertising(); Log 'Anuncio parado.'
        }
    } catch { Check 'GATT composto' $false $_.Exception.Message }

    Log "SelfTest terminou: $fail falha(s)." $(if ($fail) { 'Red' } else { 'Green' })
    exit $(if ($fail) { 1 } else { 0 })
}

# ======================================================================================================
# Execucao normal
# ======================================================================================================
try {
    PublishGatt
    if (-not (StartAdv)) { Log 'Anuncio NAO iniciou (outro script anunciando o teclado? feche ele).' 'Red'; exit 2 }
} catch { Log "BLOQUEADO ao publicar/anunciar: $($_.Exception.Message)" 'Red'; exit 2 }
try { [IPC]::StartServer($Port); Log "Canal local: http://127.0.0.1:$Port/ (so localhost, header X-iPhone-Control obrigatorio)" 'Cyan' }
catch { Log "Canal local NAO abriu na porta ${Port}: $($_.Exception.Message)" 'Yellow' }
[IPC]::StartHooks(); Log "Hooks: $([IPC]::HookStatus)"
[IPC]::FastTimer($true)
[IPC]::StartOverlay(); Log "Indicador de captura: $([IPC]::OverlayStatus) | Ctrl+Shift+F11 = espelho sempre no topo | afixar na altura da tela: $(if ([IPC]::AutoFit) { 'ligado' } else { 'desligado' }) (Ctrl+Shift+F10)"
$bw = BeaconWarn; if ($bw) { Log $bw.TrimStart(' |') 'Yellow' }
$script:titleOn = $null
function UpdateTitle { $on = [IPC]::Enabled; if ($on -ne $script:titleOn) { $script:titleOn = $on; try { $Host.UI.RawUI.WindowTitle = "iPhone: controle $(if ($on) { 'ON' } else { 'OFF' })" } catch {} } }

function ShowPrompt {
    $st = if ($script:lastSubs -match 'ponteiro=[1-9]') { 'CONECTADO' } else { 'esperando o iPhone' }
    $cap = if ([IPC]::Enabled) { '' } else { ' captura OFF' }
    [Console]::Write("[$st$cap] > " + $script:buffer)
}
Write-Host ""
if ($Headless) { Log "Modo sem console (-Headless): comandos so pelo canal local; 'quit' encerra." 'Cyan' }
Write-Host "=== Pronto. iPhone: Ajustes > Bluetooth > $env:COMPUTERNAME | AssistiveTouch ligado ===" -ForegroundColor Cyan
Write-Host "Clique na janela '$WindowTitle' = toque | janela em foco = teclado vai pro iPhone | Ctrl+Shift+F12 liga/desliga"
Write-Host "Ctrl+Shift+F11 = espelho sempre no topo | Ctrl+Shift+F10 = afixar na altura da tela | Esc cancela um colar longo | console: 'clip' mostra o clipboard sem digitar"
Write-Host "Esc = voltar | Ctrl+Shift+1..9 = resposta pronta (respostas.txt, sem Enter) | Ctrl+Shift+S = sugerir | console: abrir <app>, /r <nome>, apps"
Write-Host "Console: texto solto = digitar | help = comandos | q = sair"
$script:savedAspect = LoadSavedAspect
if ($VideoAspect -le 0 -and $script:savedAspect -gt 0) { [IPC]::VideoAspect = $script:savedAspect; Log ("Proporcao salva carregada: {0:0.0000} (a deteccao confere quando a janela aparecer)" -f $script:savedAspect) 'Cyan' }
$script:btnSince = $null
PollState; CheckWindow
$script:promptShown = -not $Headless; if (-not $Headless) { ShowPrompt }
$lastPoll = Get-Date
try {
    while ($true) {
        $busy = $false
        if (-not $Headless -and [Console]::KeyAvailable) {
            $busy = $true
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Enter') {
                $line = $script:buffer; $script:buffer = ''
                [Console]::WriteLine(); $script:promptShown = $false
                if ($line -eq 'q') { break }
                if ($line -ne '') {
                    $first = ($line -split '\s+')[0].ToLower()
                    if (@('type', 'key', 'tap', 'longpress', 'swipe', 'scroll', 'home', 'homeswipe', 'voltar', 'apps', 'abrir', '/r', 'respostas', 'sugerir', 'paste', 'clip', 'zero', 'relmove', 'screenshot', 'calibrate', 'fit', 'topo', 'estado', 'quit', 'sair', 'on', 'off', 'status', 'help') -contains $first) { $r = HandleCommand $line }
                    elseif ($line -eq '/enter') { $r = SendKeyCombo 'enter' }
                    elseif ($line -match '^/apaga\s*(\d*)$') { $r = SendKeyCombo 'backspace' $(if ($Matches[1]) { [int]$Matches[1] } else { 1 }) }
                    else { $r = SendText $line }
                    Log "$line -> $r" $(if ($r -like 'ok*') { 'Gray' } else { 'Yellow' })
                }
                if ($script:quitRequested) { break }
                $script:promptShown = $true; ShowPrompt
            } elseif ($k.Key -eq 'Backspace') {
                if ($script:buffer.Length -gt 0) { $script:buffer = $script:buffer.Substring(0, $script:buffer.Length - 1); [Console]::Write("`b `b") }
            } elseif ([int]$k.KeyChar -ge 32) { $script:buffer += $k.KeyChar; [Console]::Write($k.KeyChar) }
        }
        if (ProcessHookEvents) { $busy = $true }
        UpdateTitle
        $req = $null
        if ([IPC]::Requests.TryTake([ref]$req)) {
            $busy = $true
            $req.Resp = HandleCommand $req.Cmd; $req.Done.Set()
            Log "[canal] $($req.Cmd) -> $($req.Resp)" 'DarkGray'
            if ($script:quitRequested) { Start-Sleep -Milliseconds 150; break }   # da tempo da resposta sair antes de fechar o canal
        }
        if (((Get-Date) - $lastPoll).TotalSeconds -ge 2) {
            $lastPoll = Get-Date; PollState; CheckWindow
            # lado PowerShell do "dedo preso": botao apertado no iPhone, sem arraste no hook e sem evento na fila (2 polls seguidos)
            if ($script:btn -eq 1 -and -not [IPC]::Dragging -and [IPC]::Events.IsEmpty) {
                if ($null -eq $script:btnSince) { $script:btnSince = Get-Date }
                elseif (Ready) { PointerUp; $script:btnSince = $null; Log 'Dedo preso solto: botao ficou apertado sem arraste no PC' 'Yellow' }
            } else { $script:btnSince = $null }
        }
        if (-not $busy) { $null = [IPC]::Wake.WaitOne(5) }   # acorda na hora com clique/tecla/canal
    }
} finally {
    [IPC]::StopHooks(); [IPC]::StopServer(); [IPC]::StopOverlay(); [IPC]::FastTimer($false)
    if ($script:provider) { $script:provider.StopAdvertising() }
    Log 'Anuncio parado, hooks removidos.'
}

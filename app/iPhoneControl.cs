// iPhoneControl.exe - painel do iphone-control (WinForms, .NET Framework 4, compilado pelo instalar.ps1 com o csc do Windows).
// Ao abrir: liga o espelho (iniciar.ps1 -SoEspelho -DesligarBeacon) e roda o iphone-control.ps1 -Headless como processo
// filho oculto. Comandos e status pelo canal local 127.0.0.1. Fechar (X) esconde na bandeja; "Sair" encerra o controle.
// Tudo relativo a pasta do repositorio (a pasta acima de bin\ onde fica o .exe).
//
// Opcoes: --sair (fecha o painel aberto e o controle, como bandeja > Sair)
// Para teste: --port N (padrao 47380) | --sem-espelho (nao mexe no uxplay) | --sem-filho (nao inicia o controle)
//                      --captura arquivo.png (abre fora da tela, salva a janela em PNG depois de 3 s e fecha) | --tema claro|escuro | --fora-da-tela | --espera ms (antes da captura)
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace IPhoneControlApp {

static class Program {
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    static int crashes;
    public static string LogDir() {
        string bin = Path.GetDirectoryName(Application.ExecutablePath);
        string root = Path.GetFullPath(Path.Combine(bin, ".."));
        if (!File.Exists(Path.Combine(root, "iphone-control.ps1"))) root = bin;
        return Path.Combine(root, "logs");
    }
    static void Crash(Exception ex, bool fatal) {
        string file = "";
        try {
            string d = LogDir(); Directory.CreateDirectory(d);
            file = Path.Combine(d, "painel-erro-" + DateTime.Now.ToString("yyyyMMdd") + ".log");
            File.AppendAllText(file, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + (fatal ? " FATAL " : " ") + (ex == null ? "erro desconhecido" : ex.ToString()) + Environment.NewLine, Encoding.UTF8);
        } catch (Exception) { }
        // mensagem amigavel so uma vez por execucao (um erro repetido no desenho nao vira uma enxurrada de janelas)
        if (Interlocked.Increment(ref crashes) == 1)
            try { MessageBox.Show("O painel encontrou um erro e continua funcionando." + (fatal ? " Ele vai fechar; abra de novo pelo ícone." : "") + "\n\nDetalhes em: " + file, "iPhone Control", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch (Exception) { }
    }

    [STAThread]
    static void Main(string[] args) {
        int port = 47380; bool noMirror = false, noChild = false, quit = false; string shot = null;
        for (int i = 0; i < args.Length; i++) {
            string a = args[i].ToLowerInvariant();
            if (a == "--port" && i + 1 < args.Length) int.TryParse(args[++i], out port);
            else if (a == "--sem-espelho") noMirror = true;
            else if (a == "--sem-filho") noChild = true;
            else if (a == "--sair") quit = true;
            else if (a == "--espera" && i + 1 < args.Length) int.TryParse(args[++i], out MainForm.ShotDelayMs);
            else if (a == "--captura" && i + 1 < args.Length) shot = args[++i];
            else if (a == "--fora-da-tela") MainForm.OffScreen = true;
            else if (a == "--tema" && i + 1 < args.Length) Theme.Force = args[++i].ToLowerInvariant();
        }
        string name = "Local\\iPhoneControlPanel-" + port;
        bool created;
        using (Mutex mx = new Mutex(true, name, out created)) {
            if (!created) {
                // ja aberto: pede para a outra instancia aparecer
                try { EventWaitHandle.OpenExisting(name + (quit ? "-quit" : "-show")).Set(); } catch (Exception) { }
                return;
            }
            if (quit) return;   // --sair sem painel aberto: nada a fazer
            EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset, name + "-show");
            MainForm.QuitEvt = new EventWaitHandle(false, EventResetMode.AutoReset, name + "-quit");
            try { SetProcessDPIAware(); } catch (Exception) { }
            // erro inesperado: grava em logs\painel-erro-*.log e mostra uma mensagem curta, nunca o dialogo padrao do .NET
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += delegate(object o, ThreadExceptionEventArgs e) { Crash(e.Exception, false); };
            AppDomain.CurrentDomain.UnhandledException += delegate(object o, UnhandledExceptionEventArgs e) { Crash(e.ExceptionObject as Exception, true); };
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm(port, noMirror, noChild, shot, show));
            GC.KeepAlive(mx);
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Tema (claro / escuro seguindo o Windows)
// ---------------------------------------------------------------------------------------------------------------
class Theme {
    public bool Dark;
    public Color Bg, Surface, SurfaceHover, SurfacePressed, Border, Text, SubText, Accent, AccentText, Track;
    public Color OkBg, OkFg, IdleBg, IdleFg, BadBg, BadFg, WarnBg, WarnFg;

    public static string Force;   // --tema claro|escuro (teste); sem isso segue o Windows
    public static bool SystemDark() {
        if (Force == "escuro") return true;
        if (Force == "claro") return false;
        try {
            object v = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1);
            return v is int && (int)v == 0;
        } catch (Exception) { return false; }
    }
    public static Theme Make(bool dark) {
        Theme t = new Theme(); t.Dark = dark;
        if (!dark) {
            t.Bg = C(0xF3F3F3); t.Surface = C(0xFFFFFF); t.SurfaceHover = C(0xF7F7F7); t.SurfacePressed = C(0xEDEDED);
            t.Border = C(0xE3E3E3); t.Text = C(0x1B1B1B); t.SubText = C(0x606060); t.Accent = C(0x005FB8); t.AccentText = C(0xFFFFFF);
            t.Track = C(0xC9C9C9);
            t.OkBg = C(0xDFF6DD); t.OkFg = C(0x0E700E); t.IdleBg = C(0xE9E9E9); t.IdleFg = C(0x5B5B5B);
            t.BadBg = C(0xFDE7E9); t.BadFg = C(0xC42B1C); t.WarnBg = C(0xFFF4CE); t.WarnFg = C(0x8A5300);
        } else {
            t.Bg = C(0x202020); t.Surface = C(0x2D2D2D); t.SurfaceHover = C(0x353535); t.SurfacePressed = C(0x292929);
            t.Border = C(0x3B3B3B); t.Text = C(0xFFFFFF); t.SubText = C(0xA8A8A8); t.Accent = C(0x60CDFF); t.AccentText = C(0x003450);
            t.Track = C(0x5A5A5A);
            t.OkBg = C(0x1F3B1E); t.OkFg = C(0x6CCB5F); t.IdleBg = C(0x383838); t.IdleFg = C(0xC5C5C5);
            t.BadBg = C(0x442726); t.BadFg = C(0xFF99A4); t.WarnBg = C(0x433519); t.WarnFg = C(0xFCE100);
        }
        return t;
    }
    static Color C(int rgb) { return Color.FromArgb(255, (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }
    public static Color Mix(Color a, Color b, double k) {
        k = Math.Max(0, Math.Min(1, k));
        return Color.FromArgb((int)(a.A + (b.A - a.A) * k), (int)(a.R + (b.R - a.R) * k), (int)(a.G + (b.G - a.G) * k), (int)(a.B + (b.B - a.B) * k));
    }
}

static class Gfx {
    public static GraphicsPath Round(RectangleF r, float rad) {
        GraphicsPath p = new GraphicsPath();
        float d = Math.Min(rad * 2, Math.Min(r.Width, r.Height));
        if (d <= 0.5f) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    public static void Prep(Graphics g) {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
    }
    static string iconFamily;
    public static string IconFamily() {
        if (iconFamily != null) return iconFamily;
        iconFamily = "Segoe MDL2 Assets";
        using (InstalledFontCollection fc = new InstalledFontCollection())
            foreach (FontFamily f in fc.Families) if (f.Name == "Segoe Fluent Icons") { iconFamily = f.Name; break; }
        return iconFamily;
    }
    public static void Center(Graphics g, string s, Font f, Color c, RectangleF r) {
        TextRenderer.DrawText(g, s, f, Rectangle.Round(r), c, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
    }
    public static void Left(Graphics g, string s, Font f, Color c, RectangleF r) {
        TextRenderer.DrawText(g, s, f, Rectangle.Round(r), c, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Controles desenhados: botao (bloco), interruptor, campo de texto
// ---------------------------------------------------------------------------------------------------------------
class Tile : Control {
    public string Glyph, Label; public bool Vertical, Primary, Chevron;
    public Theme T; public float S = 1;
    public Font IconFont, LabelFont;
    double hover, press, flash; bool over, down; int flashSince;
    bool flashOk = true;
    System.Windows.Forms.Timer anim = new System.Windows.Forms.Timer();

    public Tile() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        Cursor = Cursors.Hand;
        anim.Interval = 15; anim.Tick += delegate { Step(); };
    }
    public void Flash(bool ok) { flashOk = ok; flash = 1; flashSince = Environment.TickCount; anim.Start(); }
    void Step() {
        bool busy = false;
        double th = over ? 1 : 0, tp = down ? 1 : 0;
        hover += (th - hover) * 0.35; if (Math.Abs(th - hover) > 0.01) busy = true; else hover = th;
        press += (tp - press) * 0.5; if (Math.Abs(tp - press) > 0.01) busy = true; else press = tp;
        if (flash > 0) {
            int age = Environment.TickCount - flashSince;
            flash = age < 700 ? 1 : Math.Max(0, 1 - (age - 700) / 350.0);
            busy = true;
        }
        Invalidate();
        if (!busy) anim.Stop();
    }
    protected override void OnMouseEnter(EventArgs e) { over = true; anim.Start(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { over = false; down = false; anim.Start(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; anim.Start(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; anim.Start(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

    protected override void OnPaint(PaintEventArgs e) {
        if (T == null) return;
        Graphics g = e.Graphics; Gfx.Prep(g);
        g.Clear(BackColor);
        // pressionado = encolhe 2% (microinteracao), hover = clareia
        float shrink = (float)(press * Math.Min(Width, Height) * 0.03);
        RectangleF r = new RectangleF(0.5f + shrink, 0.5f + shrink, Width - 1.5f - 2 * shrink, Height - 1.5f - 2 * shrink);
        Color fill, fg, border;
        if (Primary) {
            fill = Theme.Mix(T.Accent, T.Dark ? Color.White : Color.Black, hover * 0.08 + press * 0.08);
            fg = T.AccentText; border = fill;
        } else {
            fill = Theme.Mix(Theme.Mix(T.Surface, T.SurfaceHover, hover), T.SurfacePressed, press);
            fg = T.Text; border = Theme.Mix(T.Border, T.Accent, hover * 0.25);
        }
        Color flashFg = flashOk ? T.OkFg : T.BadFg, flashBg = flashOk ? T.OkBg : T.BadBg;
        if (flash > 0 && !Primary) { fill = Theme.Mix(fill, flashBg, flash); border = Theme.Mix(border, flashFg, flash * 0.5); }
        if (!Enabled) fg = Theme.Mix(fg, fill, 0.55);
        using (GraphicsPath p = Gfx.Round(r, 8 * S)) {
            using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, p);
            using (Pen pen = new Pen(border, 1)) g.DrawPath(pen, p);
        }
        string glyph = (flash > 0.5) ? (flashOk ? "" : "") : Glyph;   // check / erro durante o feedback
        Color gc = (flash > 0.5 && !Primary) ? flashFg : (Primary ? fg : Theme.Mix(T.Accent, T.Text, T.Dark ? 0.1 : 0.0));
        if (!Enabled) gc = Theme.Mix(gc, fill, 0.55);
        if (Vertical) {
            float ih = Height * 0.46f;
            Gfx.Center(g, glyph, IconFont, gc, new RectangleF(0, Height * 0.12f, Width, ih));
            Gfx.Center(g, Label, LabelFont, fg, new RectangleF(0, Height * 0.56f, Width, Height * 0.32f));
        } else {
            float pad = 14 * S, iw = 20 * S;
            if (string.IsNullOrEmpty(Label)) { Gfx.Center(g, glyph, IconFont, gc, new RectangleF(0, 0, Width, Height)); return; }
            Size ts = TextRenderer.MeasureText(g, Label, LabelFont, Size.Empty, TextFormatFlags.NoPadding);
            float gap = 6 * S, total = iw + gap + ts.Width;
            float x = Chevron ? pad : Math.Max(4 * S, (Width - total) / 2);
            if (glyph != null) Gfx.Center(g, glyph, IconFont, gc, new RectangleF(x, 0, iw, Height));
            float lw = Chevron ? Width - x - iw - gap - 28 * S : ts.Width + 4 * S;
            Gfx.Left(g, Label, LabelFont, fg, new RectangleF(x + iw + gap, 0, lw, Height));
            if (Chevron) Gfx.Center(g, "", new Font(IconFont.FontFamily, IconFont.Size * 0.6f), T.SubText, new RectangleF(Width - 30 * S, 0, 20 * S, Height));
        }
    }
}

class Toggle : Control {
    public string Label, Glyph; public Theme T; public float S = 1;
    public Font LabelFont, IconFont;
    bool on; double knob, hover; bool over;
    System.Windows.Forms.Timer anim = new System.Windows.Forms.Timer();
    public event EventHandler Toggled;
    public Toggle() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        Cursor = Cursors.Hand;
        anim.Interval = 15; anim.Tick += delegate {
            double tk = on ? 1 : 0, th = over ? 1 : 0;
            knob += (tk - knob) * 0.3; hover += (th - hover) * 0.35;
            if (Math.Abs(tk - knob) < 0.01 && Math.Abs(th - hover) < 0.01) { knob = tk; hover = th; anim.Stop(); }
            Invalidate();
        };
    }
    public bool On { get { return on; } set { if (value != on) { on = value; anim.Start(); } } }
    protected override void OnMouseEnter(EventArgs e) { over = true; anim.Start(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { over = false; anim.Start(); base.OnMouseLeave(e); }
    protected override void OnClick(EventArgs e) { On = !On; if (Toggled != null) Toggled(this, e); base.OnClick(e); }
    protected override void OnPaint(PaintEventArgs e) {
        if (T == null) return;
        Graphics g = e.Graphics; Gfx.Prep(g); g.Clear(BackColor);
        RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using (GraphicsPath p = Gfx.Round(r, 8 * S)) {
            using (SolidBrush b = new SolidBrush(Theme.Mix(T.Surface, T.SurfaceHover, hover))) g.FillPath(b, p);
            using (Pen pen = new Pen(T.Border, 1)) g.DrawPath(pen, p);
        }
        float pad = 14 * S;
        Gfx.Center(g, Glyph, IconFont, Theme.Mix(T.SubText, T.Accent, knob), new RectangleF(pad, 0, 20 * S, Height));
        Gfx.Left(g, Label, LabelFont, T.Text, new RectangleF(pad + 28 * S, 0, Width - pad - 28 * S - 60 * S, Height));
        // interruptor estilo Windows 11
        float tw = 40 * S, th = 20 * S, tx = Width - pad - tw, ty = (Height - th) / 2;
        RectangleF tr = new RectangleF(tx, ty, tw, th);
        Color trackFill = Theme.Mix(T.Surface, T.Accent, knob);
        Color trackBorder = Theme.Mix(T.SubText, T.Accent, knob);
        using (GraphicsPath p = Gfx.Round(tr, th / 2)) {
            using (SolidBrush b = new SolidBrush(trackFill)) g.FillPath(b, p);
            using (Pen pen = new Pen(trackBorder, 1)) g.DrawPath(pen, p);
        }
        float kd = (float)(th - 8 * S + hover * 2 * S);
        float kx = (float)(tx + 4 * S + knob * (tw - 8 * S - kd)) , ky = ty + (th - kd) / 2;
        using (SolidBrush b = new SolidBrush(Theme.Mix(T.SubText, T.AccentText, knob))) g.FillEllipse(b, kx, ky, kd, kd);
    }
}

class Field : Panel {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);
    public TextBox Box = new TextBox(); public Theme T; public float S = 1; public string Hint = "";
    public Field() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        Box.BorderStyle = BorderStyle.None;
        Controls.Add(Box);
        Box.GotFocus += delegate { Invalidate(); }; Box.LostFocus += delegate { Invalidate(); };
        Box.TextChanged += delegate { Invalidate(); };
        Box.HandleCreated += delegate { SendMessage(Box.Handle, 0x1501, new IntPtr(1), Hint); };   // EM_SETCUEBANNER: texto de dica
        Click += delegate { Box.Focus(); };
        Cursor = Cursors.IBeam;
    }
    public void Apply() {
        Box.BackColor = T.Surface; Box.ForeColor = T.Text;
        int pad = (int)(12 * S);
        Box.Location = new Point(pad, (Height - Box.Height) / 2);
        Box.Width = Width - 2 * pad;
        Invalidate();
    }
    protected override void OnResize(EventArgs e) { base.OnResize(e); if (T != null) Apply(); }
    protected override void OnPaint(PaintEventArgs e) {
        if (T == null) return;
        Graphics g = e.Graphics; Gfx.Prep(g); g.Clear(BackColor);
        RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        bool f = Box.Focused;
        using (GraphicsPath p = Gfx.Round(r, 8 * S)) {
            using (SolidBrush b = new SolidBrush(T.Surface)) g.FillPath(b, p);
            using (Pen pen = new Pen(f ? T.Accent : T.Border, 1)) g.DrawPath(pen, p);
        }
        // sublinhado de foco (2 px) no estilo dos campos do Windows 11
        if (f) using (Pen pen = new Pen(T.Accent, 2 * S)) g.DrawLine(pen, 8 * S, Height - 1.5f, Width - 8 * S, Height - 1.5f);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Janela principal
// ---------------------------------------------------------------------------------------------------------------
class MainForm : Form {
    public static EventWaitHandle QuitEvt;   // iPhoneControl.exe --sair = mesmo que bandeja > Sair
    public static bool OffScreen; public static int ShotDelayMs = 3000;   // --fora-da-tela (teste automatizado sem atrapalhar a tela)
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);

    readonly int port; readonly bool noMirror, noChild; readonly string shotPath; readonly EventWaitHandle showEvt;
    readonly string root, binDir, logDir;
    Theme T; float S;
    Font fTitle, fSub, fSection, fLabel, fIcon, fIconBig, fChip, fFoot;
    Tile bBack, bHome, bApps, bOpen, bSugerir, bResp, bLogs;
    Toggle tCap, tTop;
    Field fApp;
    ContextMenuStrip respMenu, trayMenu;
    Tile[] respTiles = new Tile[4];
    int respTop;
    NotifyIcon tray;
    System.Windows.Forms.Timer poll = new System.Windows.Forms.Timer(), toastTimer = new System.Windows.Forms.Timer();
    Icon appIcon;
    Rectangle iconRect, chipArea, subRect, footRect;

    // estado
    enum St { Starting, Connected, NoPhone, NoMirror, Stopped }
    St state = St.Starting; string detail = "Ligando o controle…"; bool attached;
    volatile bool polling; int ignoreTogglesUntil = Environment.TickCount;
    Process child; readonly List<DateTime> restarts = new List<DateTime>(); bool quitting, gaveUp;
    string toast = ""; bool toastOk = true; double toastAlpha; int toastSince;
    double chipPulse; int startTick = Environment.TickCount;

    public MainForm(int port, bool noMirror, bool noChild, string shot, EventWaitHandle show) {
        this.port = port; this.noMirror = noMirror; this.noChild = noChild; this.shotPath = shot; this.showEvt = show;
        binDir = Path.GetDirectoryName(Application.ExecutablePath);
        root = Path.GetFullPath(Path.Combine(binDir, ".."));
        if (!File.Exists(Path.Combine(root, "iphone-control.ps1")) && File.Exists(Path.Combine(binDir, "iphone-control.ps1"))) root = binDir;
        logDir = Program.LogDir();

        Text = "iPhone Control";
        FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        if (shot != null || OffScreen) { StartPosition = FormStartPosition.Manual; Location = new Point(-4000, -4000); ShowInTaskbar = false; }   // teste: fora da tela
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
        KeyPreview = true;
        try {
            string ico = Path.Combine(binDir, "iPhoneControl.ico");
            appIcon = File.Exists(ico) ? new Icon(ico) : Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            Icon = appIcon;
        } catch (Exception) { }

        using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) S = g.DpiX / 96f;   // DPI do sistema, sem criar o handle da janela cedo
        fTitle = new Font("Segoe UI Semibold", 12f); fSub = new Font("Segoe UI", 9f); fSection = new Font("Segoe UI Semibold", 8.25f);
        fLabel = new Font("Segoe UI", 9.5f); fIcon = new Font(Gfx.IconFamily(), 12f); fIconBig = new Font(Gfx.IconFamily(), 15f);
        fChip = new Font("Segoe UI Semibold", 8.75f); fFoot = new Font("Segoe UI", 9f);

        BuildUi();
        ApplyTheme();
        SystemEvents.UserPreferenceChanged += OnPrefChanged;

        tray = new NotifyIcon(); tray.Text = "iPhone Control"; tray.Icon = appIcon != null ? new Icon(appIcon, SystemInformation.SmallIconSize) : SystemIcons.Application;
        trayMenu = new ContextMenuStrip();
        trayMenu.Items.Add("Abrir", null, delegate { ShowPanel(); });
        trayMenu.Items.Add("Sugerir resposta", null, delegate { Send("sugerir", null); });
        trayMenu.Items.Add(new ToolStripSeparator());
        trayMenu.Items.Add("Sair", null, delegate { Quit(); });
        ((ToolStripMenuItem)trayMenu.Items[0]).Font = new Font(trayMenu.Font, FontStyle.Bold);
        tray.ContextMenuStrip = trayMenu;
        tray.MouseClick += delegate(object o, MouseEventArgs e) { if (e.Button == MouseButtons.Left) ShowPanel(); };
        tray.Visible = true;

        poll.Interval = 1500; poll.Tick += delegate { Poll(); };
        toastTimer.Interval = 30; toastTimer.Tick += delegate { ToastStep(); };

        Thread w = new Thread(delegate() {
            WaitHandle[] hs = new WaitHandle[] { showEvt, QuitEvt };
            while (true) {
                int i = WaitHandle.WaitAny(hs);
                try { if (i == 0) BeginInvoke((MethodInvoker)ShowPanel); else { BeginInvoke((MethodInvoker)Quit); return; } } catch (Exception) { return; }
            }
        });
        w.IsBackground = true; w.Start();
    }

    int P(float v) { return (int)Math.Round(v * S); }

    void BuildUi() {
        int W = 344, m = 16;
        ClientSize = new Size(P(W), P(470));
        iconRect = new Rectangle(P(m), P(16), P(36), P(36));
        subRect = new Rectangle(P(m + 48), P(37), P(W - m - 48 - m), P(34));   // ate 2 linhas (erro ou passo a passo)
        int y = 84;
        int tw = (W - 2 * m - 2 * 8) / 3;
        bBack = MkTile("", "Voltar", true, P(m), P(y + 22), P(tw), P(74), "voltar");
        bHome = MkTile("", "Home", true, P(m + tw + 8), P(y + 22), P(tw), P(74), "home");
        bApps = MkTile("", "Apps", true, P(m + 2 * (tw + 8)), P(y + 22), P(W - 2 * m - 2 * (tw + 8)), P(74), "apps");
        y += 22 + 74 + 18;   // 186
        fApp = new Field(); fApp.Location = new Point(P(m), P(y + 22)); fApp.Size = new Size(P(W - 2 * m - 8 - 84), P(38));
        fApp.Box.Font = fLabel; fApp.S = S;
        fApp.Box.KeyDown += delegate(object o, KeyEventArgs e) { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; OpenApp(); } };
        Controls.Add(fApp);
        bOpen = MkTile("", "Abrir", false, P(W - m - 84), P(y + 22), P(84), P(38), null);
        fApp.Hint = "Nome do app, ex.: WhatsApp";
        bOpen.Primary = true; bOpen.Click += delegate { OpenApp(); };
        y += 22 + 38 + 18;   // 264
        int hw = (W - 2 * m - 8) / 2;
        bSugerir = MkTile("", "Sugerir resposta", false, P(m), P(y + 22), P(W - 2 * m), P(42), "sugerir");
        y += 22 + 42 + 18;
        // RESPOSTAS: as 4 primeiras do respostas.txt expostas, o resto em "Outros"
        respTop = y;
        for (int k = 0; k < 4; k++) {
            int cx = m + (k % 2) * (hw + 8), cy = y + 22 + (k / 2) * (40 + 8);
            int idx = k;
            Tile rt = MkTile("", "", false, P(cx), P(cy), P(k % 2 == 0 ? hw : W - 2 * m - hw - 8), P(40), null);
            rt.Click += delegate { SendRespostaAt(idx, rt); };
            respTiles[k] = rt;
        }
        y += 22 + 2 * 40 + 8 + 8;
        bResp = MkTile("", "Outras respostas", false, P(m), P(y), P(W - 2 * m), P(40), null);
        bResp.Chevron = true; bResp.Click += delegate { ShowRespostas(); };
        RefreshRespTiles();
        y += 40 + 18;
        tCap = MkToggle("", "Captura do mouse e teclado", P(m), P(y), P(W - 2 * m), P(44));
        tCap.Toggled += delegate { ignoreTogglesUntil = Environment.TickCount + 2500; Send(tCap.On ? "on" : "off", null); };
        y += 44 + 6;
        tTop = MkToggle("", "Espelho sempre no topo", P(m), P(y), P(W - 2 * m), P(44));
        tTop.Toggled += delegate { ignoreTogglesUntil = Environment.TickCount + 2500; Send(tTop.On ? "topo on" : "topo off", null); };
        y += 44 + 14;        // 438
        bLogs = MkTile("", "Pasta de logs", false, P(m), P(y), P(140), P(32), null);
        bLogs.Click += delegate { OpenLogs(); };
        footRect = new Rectangle(P(m + 148), P(y), P(W - 2 * m - 148), P(32));
        ClientSize = new Size(P(W), P(y + 32 + 16));
        respMenu = new ContextMenuStrip();
    }

    Tile MkTile(string glyph, string label, bool vertical, int x, int y, int w, int h, string cmd) {
        Tile t = new Tile(); t.Glyph = glyph; t.Label = label; t.Vertical = vertical; t.S = S; t.Text = label; t.AccessibleName = label;
        t.IconFont = vertical ? fIconBig : fIcon; t.LabelFont = fLabel;
        t.Location = new Point(x, y); t.Size = new Size(w, h);
        if (cmd != null) { string c = cmd; t.Click += delegate { Send(c, t); }; }
        Controls.Add(t); return t;
    }
    Toggle MkToggle(string glyph, string label, int x, int y, int w, int h) {
        Toggle t = new Toggle(); t.Glyph = glyph; t.Label = label; t.S = S; t.Text = label; t.AccessibleName = label; t.LabelFont = fLabel; t.IconFont = fIcon;
        t.Location = new Point(x, y); t.Size = new Size(w, h); Controls.Add(t); return t;
    }

    void OnPrefChanged(object o, UserPreferenceChangedEventArgs e) {
        if (e.Category == UserPreferenceCategory.General || e.Category == UserPreferenceCategory.Color || e.Category == UserPreferenceCategory.VisualStyle)
            try { BeginInvoke((MethodInvoker)ApplyTheme); } catch (Exception) { }
    }
    void ApplyTheme() {
        T = Theme.Make(Theme.SystemDark());
        BackColor = T.Bg;
        foreach (Control c in Controls) {
            c.BackColor = T.Bg;
            Tile t = c as Tile; if (t != null) t.T = T;
            Toggle g = c as Toggle; if (g != null) g.T = T;
            Field f = c as Field; if (f != null) { f.T = T; f.Apply(); }
        }
        if (IsHandleCreated) ApplyDwm();
        Invalidate(true);
    }
    void ApplyDwm() {
        if (T == null) return;   // CreateGraphics no construtor cria o handle antes do tema existir
        int dark = T.Dark ? 1 : 0; DwmSetWindowAttribute(Handle, 20, ref dark, 4);   // barra de titulo escura
        int round = 2; DwmSetWindowAttribute(Handle, 33, ref round, 4);               // cantos arredondados (Windows 11)
        int backdrop = 2; DwmSetWindowAttribute(Handle, 38, ref backdrop, 4);         // Mica na barra de titulo (Windows 11 22H2+)
    }
    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); ApplyDwm(); }

    protected override void OnShown(EventArgs e) {
        base.OnShown(e);
        Thread th = new Thread(Startup); th.IsBackground = true; th.Start();
        poll.Start();
        if (shotPath != null) {
            System.Windows.Forms.Timer st = new System.Windows.Forms.Timer(); st.Interval = Math.Max(500, ShotDelayMs);
            st.Tick += delegate { st.Stop(); SaveShot(shotPath); quitting = true; tray.Visible = false; Application.Exit(); };
            st.Start();
        }
    }

    // ---------------- inicio: espelho + controle ----------------
    void Startup() {
        if (!noMirror) {
            string ini = Path.Combine(root, "iniciar.ps1");
            if (File.Exists(ini)) {
                try {
                    Process p = Process.Start(Ps("-File \"" + ini + "\" -SoEspelho -DesligarBeacon"));
                    if (p != null) p.WaitForExit(20000);
                } catch (Exception) { }
            }
        }
        string r = Request("estado", 1500);
        if (r != null && r.StartsWith("ponteiro=")) { attached = true; UiDetail("Usando o controle que já estava aberto"); return; }
        if (noChild) { attached = true; return; }
        StartChild();
    }
    ProcessStartInfo Ps(string args) {
        ProcessStartInfo si = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " + args);
        si.UseShellExecute = false; si.CreateNoWindow = true; si.WorkingDirectory = root;
        return si;
    }
    void StartChild() {
        string ctl = Path.Combine(root, "iphone-control.ps1");
        if (!File.Exists(ctl)) { SetStopped("Não achei o iphone-control.ps1 na pasta do app"); return; }
        try {
            Process p = new Process();
            p.StartInfo = Ps("-File \"" + ctl + "\" -Headless -Port " + port);
            p.EnableRaisingEvents = true;
            p.Exited += OnChildExit;
            p.Start();
            child = p;
        } catch (Exception ex) { SetStopped("Não consegui iniciar o controle: " + ex.Message); }
    }
    void OnChildExit(object o, EventArgs e) {
        if (quitting) return;
        int code = -1; try { code = ((Process)o).ExitCode; } catch (Exception) { }
        DateTime now = DateTime.Now;
        restarts.RemoveAll(delegate(DateTime d) { return (now - d).TotalSeconds > 60; });
        if (restarts.Count >= 3) {
            gaveUp = true;
            SetStopped("O controle parou 3 vezes em 1 minuto (código " + code + "). " + LastLogLine());
            try { BeginInvoke((MethodInvoker)delegate { tray.ShowBalloonTip(5000, "iPhone Control", "O controle parou. Abra o painel para tentar de novo.", ToolTipIcon.Warning); }); } catch (Exception) { }
            return;
        }
        restarts.Add(now);
        UiToast("O controle fechou (código " + code + "), reiniciando…", false);
        Thread.Sleep(1500);
        if (!quitting) StartChild();
    }
    void Retry() {
        if (!gaveUp || quitting) return;
        gaveUp = false; restarts.Clear(); state = St.Starting; detail = "Ligando o controle…"; Invalidate();
        Thread th = new Thread(StartChild); th.IsBackground = true; th.Start();
    }
    string LastLogLine() {
        try {
            DirectoryInfo d = new DirectoryInfo(logDir); FileInfo best = null;
            foreach (FileInfo f in d.GetFiles("control-*.log")) if (best == null || f.LastWriteTime > best.LastWriteTime) best = f;
            if (best == null) return "";
            string last = "";
            using (FileStream fs = new FileStream(best.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (StreamReader rd = new StreamReader(fs, Encoding.UTF8)) { string l; while ((l = rd.ReadLine()) != null) if (l.Trim() != "") last = l; }
            int p = last.IndexOf("] "); if (p > 0) last = last.Substring(p + 2);
            return last.Length > 140 ? last.Substring(0, 140) + "…" : last;
        } catch (Exception) { return ""; }
    }

    // ---------------- canal local ----------------
    string Request(string cmd, int timeoutMs) {
        try {
            HttpWebRequest rq = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + port + "/");
            rq.Method = "POST"; rq.Proxy = null; rq.Timeout = timeoutMs; rq.ReadWriteTimeout = timeoutMs; rq.KeepAlive = false;
            rq.Headers.Add("X-iPhone-Control", "1"); rq.ContentType = "text/plain; charset=utf-8";
            byte[] b = Encoding.UTF8.GetBytes(cmd); rq.ContentLength = b.Length;
            using (Stream s = rq.GetRequestStream()) s.Write(b, 0, b.Length);
            using (HttpWebResponse rs = (HttpWebResponse)rq.GetResponse())
            using (StreamReader rd = new StreamReader(rs.GetResponseStream(), Encoding.UTF8)) return rd.ReadToEnd().Trim();
        } catch (WebException ex) {
            if (ex.Response != null) try { using (StreamReader rd = new StreamReader(ex.Response.GetResponseStream(), Encoding.UTF8)) return "ERRO: " + rd.ReadToEnd().Trim(); } catch (Exception) { }
            return null;
        } catch (Exception) { return null; }
    }
    void Send(string cmd, Tile from) {
        ThreadPool.QueueUserWorkItem(delegate {
            string r = Request(cmd, 130000);
            bool ok = r != null && !(r.StartsWith("ERRO") || r.StartsWith("NAO") || r.StartsWith("parou"));
            string msg;
            if (r == null) msg = "Controle não respondeu";
            else if (r.StartsWith("NAO ENVIADO")) msg = "iPhone não conectado";
            else if (!ok) msg = Short(r);
            else if (cmd == "sugerir") msg = "Sugestão a caminho…";
            else msg = "Enviado";
            try { BeginInvoke((MethodInvoker)delegate { if (from != null) from.Flash(ok); Toast(msg, ok); Poll(); }); } catch (Exception) { }
        });
    }
    static string Short(string r) { r = r.Replace("\r", " ").Replace("\n", " "); return r.Length > 70 ? r.Substring(0, 70) + "…" : r; }

    void Poll() {
        if (polling) return; polling = true;
        ThreadPool.QueueUserWorkItem(delegate {
            string r = Request("estado", 2500);
            polling = false;
            try { BeginInvoke((MethodInvoker)delegate { ApplyState(r); }); } catch (Exception) { }
        });
    }
    void ApplyState(string r) {
        if (r == null || !r.StartsWith("ponteiro=")) {
            if (state != St.Stopped) {
                bool booting = Environment.TickCount - startTick < 30000 || (child != null && !child.HasExited);
                if (booting && !attached) { state = St.Starting; detail = "Ligando o controle…"; }
                else { state = St.Stopped; detail = attached ? "O controle foi fechado em outra janela" : "Controle sem resposta"; }
            }
            Invalidate(); return;
        }
        Dictionary<string, string> kv = new Dictionary<string, string>();
        foreach (string part in r.Split(' ')) { int p = part.IndexOf('='); if (p > 0) kv[part.Substring(0, p)] = part.Substring(p + 1); }
        int ptr = 0; string v;
        if (kv.TryGetValue("ponteiro", out v)) int.TryParse(v, out ptr);
        bool win = kv.TryGetValue("janela", out v) && v == "1";
        if (ptr <= 0) { state = St.NoPhone; detail = "No iPhone: Ajustes > Bluetooth > " + Environment.MachineName; }
        else if (!win) { state = St.NoMirror; detail = "No iPhone: Central de Controle > Espelhar Tela"; }
        else { state = St.Connected; detail = "Clique no espelho para tocar no iPhone"; }
        if (attached && !noChild && state == St.Connected) detail = "Usando o controle aberto no terminal";
        if (unchecked(Environment.TickCount - ignoreTogglesUntil) > 0) {   // TickCount pode ser negativo (PC ligado > 24 dias)
            if (kv.TryGetValue("captura", out v)) tCap.On = v == "1";
            if (kv.TryGetValue("topo", out v)) tTop.On = v == "1";
        }
        Invalidate();
    }

    void SetStopped(string why) {
        try { BeginInvoke((MethodInvoker)delegate { state = St.Stopped; detail = why; Invalidate(); }); } catch (Exception) { }
    }
    void UiDetail(string d) { try { BeginInvoke((MethodInvoker)delegate { detail = d; Invalidate(); }); } catch (Exception) { } }
    void UiToast(string m, bool ok) { try { BeginInvoke((MethodInvoker)delegate { Toast(m, ok); }); } catch (Exception) { } }

    // ---------------- acoes ----------------
    void OpenApp() {
        string n = fApp.Box.Text.Trim();
        if (n == "") { Toast("Digite o nome do app", false); fApp.Box.Focus(); return; }
        Send("abrir " + n, bOpen);
        fApp.Box.SelectAll();
    }
    List<KeyValuePair<string, string>> LoadResp() {
        List<KeyValuePair<string, string>> r = new List<KeyValuePair<string, string>>();
        string f = Path.Combine(root, "respostas.txt");
        if (!File.Exists(f)) f = Path.Combine(root, "respostas.exemplo.txt");
        try {
            foreach (string raw in File.ReadAllLines(f, Encoding.UTF8)) {
                string t = raw.Trim(); if (t == "" || t.StartsWith("#")) continue;
                int p = t.IndexOf('='); if (p <= 0) continue;
                string nome = t.Substring(0, p).Trim().ToLowerInvariant(), texto = t.Substring(p + 1).Trim();
                if (nome != "" && texto != "") r.Add(new KeyValuePair<string, string>(nome, texto));
            }
        } catch (Exception) { }
        return r;
    }
    static string Rotulo(string nome) { return nome.Length == 0 ? nome : char.ToUpper(nome[0]) + nome.Substring(1); }
    void RefreshRespTiles() {
        List<KeyValuePair<string, string>> rs = LoadResp();
        for (int k = 0; k < 4; k++) {
            Tile t = respTiles[k]; if (t == null) continue;
            bool has = k < rs.Count;
            string lbl = has ? Rotulo(rs[k].Key) : "(vazio)";
            if (lbl.Length > 15) lbl = lbl.Substring(0, 14).TrimEnd() + "…";
            t.Label = lbl; t.Text = lbl; t.AccessibleName = lbl; t.Enabled = has; t.Invalidate();
        }
    }
    void SendRespostaAt(int k, Tile t) {
        List<KeyValuePair<string, string>> rs = LoadResp();
        RefreshRespTiles();
        if (k < rs.Count) Send("/r " + rs[k].Key, t);
    }
    void ShowRespostas() {
        respMenu.Items.Clear();
        List<KeyValuePair<string, string>> rs = LoadResp();
        RefreshRespTiles();
        int n = 0;
        for (int i = 4; i < rs.Count; i++) {
            string texto = rs[i].Value, prev = texto.Length > 42 ? texto.Substring(0, 42) + "\u2026" : texto;
            string cmd = "/r " + rs[i].Key;
            ToolStripMenuItem it = new ToolStripMenuItem(Rotulo(rs[i].Key) + "   \u00b7   " + prev);
            if (i < 9) it.ShortcutKeyDisplayString = "Ctrl+Shift+" + (i + 1);
            it.Click += delegate { Send(cmd, bResp); };
            respMenu.Items.Add(it); n++;
        }
        if (n == 0) { ToolStripMenuItem none = new ToolStripMenuItem("Nenhuma outra resposta em respostas.txt"); none.Enabled = false; respMenu.Items.Add(none); }
        respMenu.Items.Add(new ToolStripSeparator());
        respMenu.Items.Add("Editar respostas\u2026", null, delegate { EditRespostas(); });
        respMenu.Show(bResp, new Point(0, bResp.Height + P(4)));
    }
    void EditRespostas() {
        string f = Path.Combine(root, "respostas.txt"), ex = Path.Combine(root, "respostas.exemplo.txt");
        try { if (!File.Exists(f) && File.Exists(ex)) File.Copy(ex, f); Process.Start("notepad.exe", "\"" + f + "\""); } catch (Exception e) { Toast(Short(e.Message), false); }
    }
    void OpenLogs() {
        try { Directory.CreateDirectory(logDir); Process.Start("explorer.exe", "\"" + logDir + "\""); bLogs.Flash(true); } catch (Exception e) { Toast(Short(e.Message), false); }
    }
    void ShowPanel() {
        Show(); if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate(); BringToFront();
        if (gaveUp) Retry();
        Poll();
    }

    void Toast(string m, bool ok) { toast = m; toastOk = ok; toastSince = Environment.TickCount; toastAlpha = 0; toastTimer.Start(); }
    void ToastStep() {
        int age = Environment.TickCount - toastSince;
        int hold = toastOk ? 1800 : 4500;
        if (age < 150) toastAlpha = age / 150.0;
        else if (age < hold) toastAlpha = 1;
        else if (age < hold + 400) toastAlpha = 1 - (age - hold) / 400.0;
        else { toastAlpha = 0; toast = ""; toastTimer.Stop(); }
        chipPulse = Math.Max(0, 1 - age / 600.0);
        Invalidate(footRect);
    }

    // ---------------- desenho do cabecalho, titulos e rodape ----------------
    protected override void OnPaint(PaintEventArgs e) {
        if (T == null || bBack == null) return;
        Graphics g = e.Graphics; Gfx.Prep(g); g.Clear(T.Bg);
        // icone do app
        if (appIcon != null) using (Icon big = new Icon(appIcon, iconRect.Size)) g.DrawIcon(big, iconRect);
        Gfx.Left(g, "iPhone Control", fTitle, T.Text, new RectangleF(P(64), P(12), P(160), P(24)));
        TextRenderer.DrawText(g, detail, fSub, subRect, state == St.Stopped ? T.BadFg : T.SubText, TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
        // chip de status
        string label; Color bg, fg;
        switch (state) {
            case St.Connected: label = "Conectado"; bg = T.OkBg; fg = T.OkFg; break;
            case St.NoPhone: label = "Sem iPhone"; bg = T.IdleBg; fg = T.IdleFg; break;
            case St.NoMirror: label = "Espelho fechado"; bg = T.BadBg; fg = T.BadFg; break;
            case St.Stopped: label = gaveUp ? "Parado · tentar de novo" : "Parado"; bg = T.BadBg; fg = T.BadFg; break;
            default: label = "Iniciando"; bg = T.WarnBg; fg = T.WarnFg; break;
        }
        Size ts = TextRenderer.MeasureText(g, label, fChip, Size.Empty, TextFormatFlags.NoPadding);
        int cw = ts.Width + P(30), ch = P(24);
        chipArea = new Rectangle(ClientSize.Width - P(16) - cw, P(14), cw, ch);
        using (GraphicsPath p = Gfx.Round(chipArea, ch / 2f)) using (SolidBrush b = new SolidBrush(bg)) g.FillPath(b, p);
        using (SolidBrush b = new SolidBrush(fg)) g.FillEllipse(b, chipArea.X + P(10), chipArea.Y + (ch - P(8)) / 2f, P(8), P(8));
        Gfx.Left(g, label, fChip, fg, new RectangleF(chipArea.X + P(22), chipArea.Y, ts.Width + P(4), ch));
        // titulos das secoes
        Section(g, "NAVEGAÇÃO", bBack.Top - P(20));
        Section(g, "ABRIR APP", fApp.Top - P(20));
        Section(g, "FERRAMENTAS", bSugerir.Top - P(20));
        Section(g, "RESPOSTAS", respTiles[0].Top - P(20));
        // rodape: feedback breve
        if (toast != "" && toastAlpha > 0) {
            Color c = Theme.Mix(T.Bg, toastOk ? T.OkFg : T.BadFg, toastAlpha);
            string glyph = toastOk ? "" : "";
            Size ms = TextRenderer.MeasureText(g, toast, fFoot, Size.Empty, TextFormatFlags.NoPadding);
            int tx = Math.Max(footRect.X + P(22), footRect.Right - ms.Width);
            Gfx.Center(g, glyph, fIcon, c, new RectangleF(tx - P(22), footRect.Y, P(18), footRect.Height));
            Gfx.Left(g, toast, fFoot, c, new RectangleF(tx, footRect.Y, footRect.Right - tx, footRect.Height));
        }
    }
    void Section(Graphics g, string s, int y) { Gfx.Left(g, s, fSection, T.SubText, new RectangleF(P(18), y, P(300), P(18))); }

    protected override void OnMouseClick(MouseEventArgs e) {
        base.OnMouseClick(e);
        if (chipArea.Contains(e.Location)) { if (gaveUp) Retry(); else Poll(); }
    }
    protected override void OnMouseMove(MouseEventArgs e) { base.OnMouseMove(e); Cursor = chipArea.Contains(e.Location) ? Cursors.Hand : Cursors.Default; }

    // ---------------- fechar = bandeja; Sair = encerra o controle ----------------
    protected override void OnFormClosing(FormClosingEventArgs e) {
        if (!quitting && e.CloseReason == CloseReason.UserClosing) {
            e.Cancel = true; Hide();
            if (!hintShown) { hintShown = true; tray.ShowBalloonTip(3000, "iPhone Control", "Continua rodando aqui. Clique no ícone para abrir; botão direito > Sair encerra.", ToolTipIcon.Info); }
            return;
        }
        if (!quitting) StopChild();
        base.OnFormClosing(e);
    }
    bool hintShown;
    void Quit() { StopChild(); tray.Visible = false; Application.Exit(); }
    void StopChild() {
        quitting = true; poll.Stop();
        Process p = child;
        if (p == null || attached) return;
        try {
            if (!p.HasExited) {
                Request("quit", 3000);
                if (!p.WaitForExit(5000)) { p.Kill(); p.WaitForExit(2000); }
            }
        } catch (Exception) { }
    }
    protected override void Dispose(bool disposing) {
        SystemEvents.UserPreferenceChanged -= OnPrefChanged;
        if (disposing && tray != null) { tray.Visible = false; tray.Dispose(); }
        base.Dispose(disposing);
    }

    // ---------------- --captura: PNG da janela (para conferir o visual) ----------------
    void SaveShot(string path) {
        try {
            using (Bitmap bmp = new Bitmap(Width, Height)) {
                using (Graphics g = Graphics.FromImage(bmp)) { IntPtr hdc = g.GetHdc(); PrintWindow(Handle, hdc, 2); g.ReleaseHdc(hdc); }
                bmp.Save(path, ImageFormat.Png);
            }
        } catch (Exception) { }
    }
}
}

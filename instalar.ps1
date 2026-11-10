# instalar.ps1 - gera o painel iPhoneControl.exe a partir de app\iPhoneControl.cs e cria os atalhos.
# Duplo clique: instalar.bat. Nao instala nada: usa o compilador C# que ja vem no Windows (.NET Framework 4).
#
#   bin\iPhoneControl.exe   painel (fica fora do git; rode este script de novo depois de atualizar o repositorio)
#   bin\iPhoneControl.ico   icone (gerado aqui mesmo)
#   Atalhos "iPhone Control" na Area de Trabalho e no Menu Iniciar. NAO coloca para iniciar com o Windows.
#
# Opcoes: -SemAtalhos (so compila)
param([switch]$SemAtalhos)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $here 'app\iPhoneControl.cs'
$bin = Join-Path $here 'bin'
$exe = Join-Path $bin 'iPhoneControl.exe'
$ico = Join-Path $bin 'iPhoneControl.ico'
New-Item -ItemType Directory -Force $bin | Out-Null

# 1. Compilador do .NET Framework 4 (vem com o Windows)
$csc = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { Write-Host 'Nao achei o csc.exe do .NET Framework 4 em %WINDIR%\Microsoft.NET.' -ForegroundColor Red; exit 1 }

# 2. Painel aberto trava o .exe: fecha ele (e o controle) do jeito limpo, como bandeja > Sair
$open = @(Get-Process -Name 'iPhoneControl' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
if ($open.Count) {
    Write-Host 'Fechando o painel aberto para atualizar...' -ForegroundColor Yellow
    Start-Process -FilePath $exe -ArgumentList '--sair' -Wait
    foreach ($p in $open) { if (-not $p.WaitForExit(15000)) { Write-Host 'O painel nao fechou. Feche pela bandeja (botao direito > Sair) e rode de novo.' -ForegroundColor Red; exit 1 } }
}

# 3. Icone: quadrado arredondado azul com um iPhone branco (PNG dentro do .ico, varios tamanhos)
Add-Type -AssemblyName System.Drawing
function New-IconPng([int]$n) {
    $bmp = New-Object System.Drawing.Bitmap $n, $n
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([System.Drawing.Color]::Transparent)
    function RR([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath; $d = 2 * $r
        $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
        $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90); $p.CloseFigure(); $p
    }
    $m = [single]($n * 0.04)
    $bg = RR $m $m ($n - 2 * $m) ($n - 2 * $m) ([single]($n * 0.22))
    $rect = New-Object System.Drawing.RectangleF 0, 0, $n, $n
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, ([System.Drawing.Color]::FromArgb(255, 10, 132, 255)), ([System.Drawing.Color]::FromArgb(255, 94, 92, 230)), 60
    $g.FillPath($grad, $bg)
    # iPhone: contorno branco, ilha no topo, barrinha embaixo
    $pw = [single]($n * 0.36); $ph = [single]($n * 0.62); $px = [single](($n - $pw) / 2); $py = [single](($n - $ph) / 2)
    $stroke = [single][Math]::Max(1.2, $n * 0.055)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), $stroke
    $g.DrawPath($pen, (RR $px $py $pw $ph ([single]($n * 0.08))))
    $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    if ($n -ge 24) {
        $iw = [single]($pw * 0.36); $ih = [single][Math]::Max(1.5, $n * 0.035)
        $g.FillPath($white, (RR ([single](($n - $iw) / 2)) ([single]($py + $ph * 0.1)) $iw $ih ([single]($ih / 2))))
        $g.FillPath($white, (RR ([single](($n - $iw) / 2)) ([single]($py + $ph * 0.86)) $iw $ih ([single]($ih / 2))))
    }
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    , $ms.ToArray()
}
$sizes = @(16, 20, 24, 32, 40, 48, 64, 256)
$pngs = @(); foreach ($s in $sizes) { $pngs += , (New-IconPng $s) }
$fs = [System.IO.File]::Create($ico); $w = New-Object System.IO.BinaryWriter $fs
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $b = if ($s -ge 256) { 0 } else { $s }
    $w.Write([byte]$b); $w.Write([byte]$b); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write([byte[]]$p) }
$w.Close()
Write-Host "Icone: $ico" -ForegroundColor DarkGray

# 4. Compila
$cscArgs = @('/nologo', '/target:winexe', '/optimize+', '/codepage:65001', "/out:$exe", "/win32icon:$ico",
    '/reference:System.dll', '/reference:System.Drawing.dll', '/reference:System.Windows.Forms.dll', $src)
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { Write-Host 'A compilacao falhou (mensagens acima).' -ForegroundColor Red; exit 1 }
Write-Host "Painel: $exe" -ForegroundColor Green

# 5. Atalhos (Area de Trabalho + Menu Iniciar)
if (-not $SemAtalhos) {
    $sh = New-Object -ComObject WScript.Shell
    $places = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))
    foreach ($dir in $places) {
        if (-not $dir) { continue }
        $lnk = $sh.CreateShortcut((Join-Path $dir 'iPhone Control.lnk'))
        $lnk.TargetPath = $exe
        $lnk.WorkingDirectory = $here
        $lnk.IconLocation = "$ico,0"
        $lnk.Description = 'Espelhar e controlar o iPhone pelo PC'
        $lnk.Save()
        Write-Host "Atalho: $(Join-Path $dir 'iPhone Control.lnk')" -ForegroundColor DarkGray
    }
}
Write-Host ''
Write-Host 'Pronto. Abra pelo icone "iPhone Control" (Area de Trabalho ou Menu Iniciar).' -ForegroundColor Cyan

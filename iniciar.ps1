# iniciar.ps1 - liga o espelho (uxplay-windows) com as opcoes recomendadas e abre o controle (iphone-control.ps1).
# Duplo clique: iniciar.bat
#
# O uxplay-windows NAO aceita argumentos na linha de comando: ele le
#   %APPDATA%\leapbtw\uxplay-windows\arguments.txt  (uma linha, ex.: -n uxplay-windows -nh)
# e reaplica esse arquivo a cada sessao nova (parar e espelhar de novo no iPhone ja pega as opcoes novas).
# Este script so reescreve esse arquivo (com backup) e inicia o app se ele nao estiver aberto. Nunca fecha o uxplay.
#
# Opcoes:
#   -Sink auto|d3d11|d3d12  renderer de video (padrao auto). d3d11 = contorno do README do UxPlay para problemas no d3d12.
#                           Atencao: com "Force Fullscreen" ligado na bandeja, escolher d3d11/d3d12 abre em tela cheia (Alt+Enter sai).
#   -HardwareDecode         volta a decodificar na GPU (padrao aqui = software, -avdec)
#   -Fps N                  limite de quadros (padrao do UxPlay = 30)
#   -ComSom                 mantem a sincronia audio/video do UxPlay (padrao aqui = -vsync no, menos atraso)
#   -SoEspelho              nao abre o iphone-control.ps1
#   -DesligarBeacon         desliga 'Enable Bluetooth Discovery' do uxplay-windows (ble_enabled=false no registro; vale no proximo inicio do app)
#   -Extra "..."            opcoes a mais do UxPlay, coladas no fim
#   Qualquer outro argumento e repassado ao iphone-control.ps1 (ex.: -Relative)
param(
    [ValidateSet('auto','d3d11','d3d12')][string]$Sink = 'auto',
    [switch]$HardwareDecode,
    [int]$Fps = 0,
    [switch]$ComSom,
    [switch]$SoEspelho,
    [switch]$DesligarBeacon,
    [string]$Extra = '',
    [Parameter(ValueFromRemainingArguments = $true)] $Resto
)

$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe    = 'C:\Program Files\uxplay-windows\uxplay-windows.exe'
$cfgDir = Join-Path $env:APPDATA 'leapbtw\uxplay-windows'
$cfg    = Join-Path $cfgDir 'arguments.txt'
$reg    = 'HKCU:\Software\leapbtw\uxplay-windows'

if (-not (Test-Path $exe)) { Write-Host "uxplay-windows nao encontrado em $exe" -ForegroundColor Red; exit 1 }

# 1. Monta as opcoes do UxPlay
$opts = @('-n', 'uxplay-windows', '-nh')     # mesmo nome de hoje: o iPhone continua achando o mesmo receptor
if (-not $HardwareDecode) { $opts += '-avdec' }          # decodificacao H.264 por software (libav), fora do decodificador DXVA da Intel
if (-not $ComSom)         { $opts += @('-vsync', 'no') } # sem sincronia com o audio: nenhum quadro e descartado, menos atraso
$opts += '-nohold'                                       # reconectar derruba a sessao velha em vez de recusar a nova
if ($Sink -ne 'auto')     { $opts += @('-vs', "${Sink}videosink") }
if ($Fps -gt 0)           { $opts += @('-fps', "$Fps") }
$line = (($opts -join ' ') + ' ' + $Extra).Trim()

# 2. Grava arguments.txt (sem BOM; backup do original uma vez)
New-Item -ItemType Directory -Force $cfgDir | Out-Null
$old = if (Test-Path $cfg) { (Get-Content $cfg -Raw).Trim() } else { '' }
$bak = "$cfg.original"
if ((Test-Path $cfg) -and -not (Test-Path $bak)) { Copy-Item $cfg $bak }
if ($old -ne $line) {
    [IO.File]::WriteAllText($cfg, $line, (New-Object Text.UTF8Encoding($false)))
    Write-Host "arguments.txt: $line" -ForegroundColor Cyan
    Write-Host "  (antes: $old | backup: $bak)" -ForegroundColor DarkGray
} else {
    Write-Host "arguments.txt ja esta certo: $line" -ForegroundColor DarkGray
}

# 3. Avisos sobre configuracoes da bandeja (so leitura)
$s = Get-ItemProperty $reg -ErrorAction SilentlyContinue
if ($DesligarBeacon -and $s -and "$($s.ble_enabled)" -ne 'false') {
    Set-ItemProperty -Path $reg -Name 'ble_enabled' -Value 'false' -Type String
    Write-Host "ble_enabled=false (Bluetooth Discovery do uxplay desligado; vale no proximo inicio do uxplay-windows)" -ForegroundColor Cyan
    $s = Get-ItemProperty $reg -ErrorAction SilentlyContinue
}
if ($s -and "$($s.ble_enabled)" -eq 'true') {
    Write-Host "AVISO: 'Enable Bluetooth Discovery' esta ligado no uxplay-windows. Ele roda o uxplay-bluetooth-beacon.exe," -ForegroundColor Yellow
    Write-Host "       que anuncia no MESMO Bluetooth do teclado/mouse do iphone-control. O Bonjour ja faz a descoberta;" -ForegroundColor Yellow
    Write-Host "       recomendo desligar: bandeja > botao direito > desmarcar 'Enable Bluetooth Discovery' > reiniciar o app." -ForegroundColor Yellow
}
if ($s -and "$($s.force_fs_enabled)" -eq 'true' -and $Sink -ne 'auto') {
    Write-Host "AVISO: 'Force Fullscreen' ligado + renderer escolhido = o espelho pode abrir em tela cheia (Alt+Enter sai)." -ForegroundColor Yellow
}

# 4. Inicia o uxplay-windows se nao estiver aberto (nunca fecha o que ja esta rodando)
$running = Get-Process -Name 'uxplay-windows' -ErrorAction SilentlyContinue
if ($running) {
    if ($old -ne $line) {
        Write-Host "uxplay-windows ja estava aberto: as opcoes novas valem na proxima sessao." -ForegroundColor Yellow
        Write-Host "  No iPhone: Central de Controle > Espelhar Tela > parar, e espelhar de novo." -ForegroundColor Yellow
    } else {
        Write-Host "uxplay-windows ja esta aberto." -ForegroundColor DarkGray
    }
} else {
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe)
    Write-Host "uxplay-windows iniciado. No iPhone: Central de Controle > Espelhar Tela > uxplay-windows" -ForegroundColor Green
}

# 5. Controle (BLE HID) nesta mesma janela
if ($SoEspelho) { exit 0 }
$ctl = Join-Path $here 'iphone-control.ps1'
if (-not (Test-Path $ctl)) { Write-Host "Nao achei $ctl" -ForegroundColor Red; exit 1 }
Write-Host ""
$fwd = @(); if ($Resto) { $fwd = @($Resto) }
& $ctl @fwd

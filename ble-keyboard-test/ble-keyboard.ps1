# Teclado BLE HID (servico 0x1812) para o iPhone - Windows PowerShell 5.1, sem instalar nada.
# A parte Bluetooth (servico, caracteristicas, anuncio) e IDENTICA a da v1 que funcionou: ble-keyboard.v1-ok.ps1
# O que mudou: texto livre, mapa de teclas maior, contador de inscritos, log de conexao (tela + logs\*.log).
#
# Uso (a partir da raiz do workspace):
#   powershell -ExecutionPolicy Bypass -File .\ble-keyboard-test\ble-keyboard.ps1
#   ... -SelfTest   so publica/anuncia, mostra status e sai
# No console:
#   texto + Enter   -> digita no iPhone
#   /enter          -> tecla Enter         /apaga 3 -> Backspace 3x (sem numero = 1x)
#   /forcar texto   -> envia mesmo com contador 0 (caso o contador falhe)
#   q               -> sair
param([switch]$SelfTest, [int]$SelfTestSeconds = 5)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force (Join-Path $here 'logs') | Out-Null
$logFile = Join-Path $here ("logs\ble-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceProvider, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Devices.Bluetooth.BluetoothAdapter, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]

$asTaskOp = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [Type]$t) {
    $task = $asTaskOp.MakeGenericMethod($t).Invoke($null, @($op)); $task.Wait(-1) | Out-Null; $task.Result
}

# ---------- log ----------
$script:promptShown = $false
$script:buffer = ''
function Log([string]$msg, [string]$color = 'Gray') {
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $msg
    if ($script:promptShown) { [Console]::Write("`r" + (' ' * ([Console]::WindowWidth - 1)) + "`r") }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch {}
    if ($script:promptShown) { ShowPrompt }
}

# ---------- GATT (igual a v1) ----------
$G = 'Windows.Devices.Bluetooth.GenericAttributeProfile'
function U16([int]$x) { [guid]('0000{0:x4}-0000-1000-8000-00805f9b34fb' -f $x) }
function Buf([byte[]]$b) { [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsBuffer($b) }

[byte[]]$reportMap = @(
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01,
    0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
    0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
    0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xC0)

$Read = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicProperties]::Read
$WriteNR = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicProperties]::WriteWithoutResponse
$Notify = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicProperties]::Notify
$EncReq = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattProtectionLevel]::EncryptionRequired

function Step($name, $r) {
    if ($r.Error -ne 'Success') { throw "FALHOU em '$name': BluetoothError=$($r.Error)" }
    Log "  ok  $name"
}
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

Log "Log salvo em: $logFile"
try {
    $adapter = Await ([Windows.Devices.Bluetooth.BluetoothAdapter]::GetDefaultAsync()) ([Windows.Devices.Bluetooth.BluetoothAdapter])
    Log "Adaptador: LE=$($adapter.IsLowEnergySupported) Peripheral=$($adapter.IsPeripheralRoleSupported)"
    $res = Await ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceProvider]::CreateAsync((U16 0x1812))) ([Type]"$G.GattServiceProviderResult")
    Step 'GattServiceProvider.CreateAsync(0x1812)' $res
    $provider = $res.ServiceProvider
    $svc = $provider.Service
    $null = AddChar $svc 0x2A4A $Read ([byte[]](0x11, 0x01, 0x00, 0x02)) 'HID Information 0x2A4A'
    $null = AddChar $svc 0x2A4B $Read $reportMap 'Report Map 0x2A4B'
    $null = AddChar $svc 0x2A4C $WriteNR $null 'HID Control Point 0x2A4C'
    $null = AddChar $svc 0x2A4E ($Read -bor $WriteNR) ([byte[]](0x01)) 'Protocol Mode 0x2A4E'
    $inputReport = AddChar $svc 0x2A4D ($Read -bor $Notify) ([byte[]](0, 0, 0, 0, 0, 0, 0, 0)) 'Input Report 0x2A4D'
    $dp = New-Object "$G.GattLocalDescriptorParameters"
    $dp.ReadProtectionLevel = $EncReq
    $dp.StaticValue = (Buf ([byte[]](0x01, 0x01)))
    Step 'Report Reference 0x2908' (Await ($inputReport.CreateDescriptorAsync((U16 0x2908), $dp)) ([Type]"$G.GattLocalDescriptorResult"))

    $ap = New-Object "$G.GattServiceProviderAdvertisingParameters"
    $ap.IsConnectable = $true
    $ap.IsDiscoverable = $true
    $provider.StartAdvertising($ap)
    Start-Sleep -Milliseconds 1500
} catch {
    Log "BLOQUEADO ao publicar/anunciar: $($_.Exception.Message)" 'Red'; exit 2
}
Log "Status do anuncio: $($provider.AdvertisementStatus)"
if ($provider.AdvertisementStatus -ne 'Started') { Log "Anuncio NAO iniciou." 'Red'; $provider.StopAdvertising(); exit 2 }

# ---------- estado: inscritos e conexoes ----------
# No PS 5.1 a lista WinRT nao expoe .Count (vinha vazio na v1); contar enumerando funciona.
function SubscribedIds {
    $ids = @()
    try { foreach ($cl in $inputReport.SubscribedClients) { $ids += [string]$cl.Session.DeviceId.Id } } catch {}
    , $ids
}
function ConnectedLE {
    try {
        $sel = [Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelectorFromConnectionStatus('Connected')
        $devs = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($sel)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
        $names = @(); foreach ($d in $devs) { $names += "'$($d.Name)'" }
        if ($names.Count -eq 0) { 'nenhum' } else { ($names | Sort-Object) -join ', ' }
    } catch { "erro ao listar ($($_.Exception.Message))" }
}
$script:lastSubs = -1; $script:lastConn = $null; $script:lastAdv = [string]$provider.AdvertisementStatus
function PollState {
    $ids = SubscribedIds
    if ($ids.Count -ne $script:lastSubs) {
        $script:lastSubs = $ids.Count
        if ($ids.Count -gt 0) { Log "TECLADO ATIVO: $($ids.Count) dispositivo(s) inscrito(s) -> $($ids -join ', ')" 'Green' }
        else { Log "Teclado sem inscritos (o iPhone ainda nao ativou o teclado ou desconectou)." 'Yellow' }
    }
    $conn = ConnectedLE
    if ($conn -ne $script:lastConn) { $script:lastConn = $conn; Log "Conectados via BLE neste PC: $conn" 'Cyan' }
    $adv = [string]$provider.AdvertisementStatus
    if ($adv -ne $script:lastAdv) { $script:lastAdv = $adv; Log "Status do anuncio mudou: $adv" 'Yellow' }
}

# ---------- teclas ----------
$SHIFT = 0x02; $ALT = 0x04   # ALT = Option no iPhone
function Notify-Report([byte]$mod, [byte]$key) {
    $results = Await ($inputReport.NotifyValueAsync((Buf ([byte[]]($mod, 0, $key, 0, 0, 0, 0, 0))))) ([Type]"System.Collections.Generic.IReadOnlyList``1[[$G.GattClientNotificationResult, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]]")
    $ok = 0
    foreach ($r in $results) { if ([string]$r.Status -eq 'Success') { $ok++ } else { Log "  envio falhou: $($r.Status) (ATT $($r.ProtocolError))" 'Red' } }
    $ok
}
function Tap([byte]$mod, [byte]$key) {
    $ok = Notify-Report $mod $key; Start-Sleep -Milliseconds 12
    $null = Notify-Report 0 0; Start-Sleep -Milliseconds 12
    $ok
}

# Layout US (teclado externo do iPhone em ingles)
$plain = @{ [char]'0' = 0x27; [char]"`n" = 0x28; [char]"`t" = 0x2B; [char]' ' = 0x2C; [char]'-' = 0x2D; [char]'=' = 0x2E; [char]'[' = 0x2F; [char]']' = 0x30;
    [char]'\' = 0x31; [char]';' = 0x33; [char]"'" = 0x34; [char]'`' = 0x35; [char]',' = 0x36; [char]'.' = 0x37; [char]'/' = 0x38 }
$shifted = @{ [char]')' = 0x27; [char]'!' = 0x1E; [char]'@' = 0x1F; [char]'#' = 0x20; [char]'$' = 0x21; [char]'%' = 0x22; [char]'^' = 0x23; [char]'&' = 0x24;
    [char]'*' = 0x25; [char]'(' = 0x26; [char]'_' = 0x2D; [char]'+' = 0x2E; [char]'{' = 0x2F; [char]'}' = 0x30; [char]'|' = 0x31; [char]':' = 0x33;
    [char]'"' = 0x34; [char]'~' = 0x35; [char]'<' = 0x36; [char]'>' = 0x37; [char]'?' = 0x38 }
function BaseKey([char]$c) {
    $i = [int]$c
    if ($i -ge 97 -and $i -le 122) { return @(0, (4 + $i - 97)) }          # a-z
    if ($i -ge 65 -and $i -le 90) { return @($SHIFT, (4 + $i - 65)) }      # A-Z
    if ($i -ge 49 -and $i -le 57) { return @(0, (0x1E + $i - 49)) }        # 1-9
    if ($plain.ContainsKey($c)) { return @(0, $plain[$c]) }
    if ($shifted.ContainsKey($c)) { return @($SHIFT, $shifted[$c]) }
    $null
}
# Acentos PT via teclas mortas Option do layout US da Apple:
# Option+e = agudo, Option+` = grave, Option+i = circunflexo, Option+n = til, Option+u = trema, Option+c = cedilha
$deadKey = @{ 0x0301 = 0x08; 0x0300 = 0x35; 0x0302 = 0x0C; 0x0303 = 0x11; 0x0308 = 0x18 }
function TypeChar([char]$c) {
    $k = BaseKey $c
    if ($k) { $null = Tap $k[0] $k[1]; return $true }
    if ([int]$c -eq 0xE7) { $null = Tap $ALT 0x06; return $true }                 # c cedilha
    if ([int]$c -eq 0xC7) { $null = Tap ($ALT -bor $SHIFT) 0x06; return $true }   # C cedilha
    $d = ([string]$c).Normalize([Text.NormalizationForm]::FormD)
    if ($d.Length -eq 2 -and $deadKey.ContainsKey([int]$d[1])) {
        $lk = BaseKey $d[0]
        if ($lk) { $null = Tap $ALT $deadKey[[int]$d[1]]; $null = Tap $lk[0] $lk[1]; return $true }
    }
    $false
}
function SendText([string]$s, [switch]$Force) {
    $n = (SubscribedIds).Count
    if ($n -eq 0 -and -not $Force) { return "NAO ENVIADO: nenhum dispositivo com o teclado ativo (inscritos = 0). Se o iPhone mostra Conectado e mesmo assim nao vai, use /forcar $s" }
    $sent = 0; $skip = @()
    foreach ($c in $s.ToCharArray()) { if (TypeChar $c) { $sent++ } else { $skip += $c } }
    $msg = "$sent caractere(s) enviados (inscritos: $n)"
    if ($skip.Count) { $msg += " | sem mapa, ignorados: " + (($skip | Select-Object -Unique) -join '') }
    $msg
}
function SendKey([byte]$key, [int]$times) {
    if ((SubscribedIds).Count -eq 0) { return "NAO ENVIADO: nenhum dispositivo com o teclado ativo." }
    for ($i = 0; $i -lt $times; $i++) { $null = Tap 0 $key }
    'ok'
}

# ---------- self-test ----------
if ($SelfTest) {
    PollState
    Start-Sleep -Seconds $SelfTestSeconds
    PollState
    Log "SelfTest: anuncio = $($provider.AdvertisementStatus); inscritos = $((SubscribedIds).Count)"
    Log "SelfTest: envio de teste -> $(SendText 'teste')"
    $provider.StopAdvertising(); Log "Anuncio parado."; exit 0
}

# ---------- loop: leitor de linha proprio, para atualizar o estado enquanto espera ----------
function ShowPrompt {
    $st = if ($script:lastSubs -gt 0) { 'TECLADO ATIVO' } else { 'esperando o iPhone' }
    [Console]::Write("[$st] > " + $script:buffer)
}
function HandleLine([string]$line) {
    if ($line -eq '') { return }
    if ($line -eq '/enter') { Log "Enter: $(SendKey 0x28 1)"; return }
    if ($line -match '^/apaga\s*(\d*)$') { $t = if ($Matches[1]) { [int]$Matches[1] } else { 1 }; Log "Apagar ${t}x: $(SendKey 0x2A $t)"; return }
    if ($line -match '^/forcar\s+(.+)$') { Log "Enviar (forcado) '$($Matches[1])': $(SendText $Matches[1] -Force)"; return }
    $r = SendText $line
    $color = 'Gray'; if ($r -like 'NAO*') { $color = 'Yellow' }
    Log "Enviar '$line': $r" $color
}

Write-Host ""
Write-Host "=== Pronto. No iPhone: Ajustes > Bluetooth > $env:COMPUTERNAME ===" -ForegroundColor Cyan
Write-Host "Digite o texto + Enter para mandar | /enter = Enter | /apaga 3 = apagar 3 | q = sair"
PollState
$script:promptShown = $true; ShowPrompt
$lastPoll = Get-Date
while ($true) {
    if ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') {
            $line = $script:buffer; $script:buffer = ''
            [Console]::WriteLine()
            $script:promptShown = $false
            if ($line -eq 'q') { break }
            HandleLine $line
            $script:promptShown = $true; ShowPrompt
        } elseif ($k.Key -eq 'Backspace') {
            if ($script:buffer.Length -gt 0) { $script:buffer = $script:buffer.Substring(0, $script:buffer.Length - 1); [Console]::Write("`b `b") }
        } elseif ([int]$k.KeyChar -ge 32) {
            $script:buffer += $k.KeyChar; [Console]::Write($k.KeyChar)
        }
    } else {
        Start-Sleep -Milliseconds 50
        if (((Get-Date) - $lastPoll).TotalSeconds -ge 2) { $lastPoll = Get-Date; PollState }
    }
}
$provider.StopAdvertising()
Log "Anuncio parado."

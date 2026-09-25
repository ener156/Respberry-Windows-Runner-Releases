param(
    [string]$TargetStarterExe = '',
    [int]$StarterProcessId = 0
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$ManifestUrl = 'https://raw.githubusercontent.com/ener156/Respberry-Windows-Runner-Releases/main/latest.json'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$LocalRoot = Join-Path $env:LOCALAPPDATA 'RespberryStarterUIPrototype'
$UpdateRoot = Join-Path $LocalRoot 'Updates'
$BackupRoot = Join-Path $UpdateRoot ('Backups\' + $Stamp)
$ReportRoot = Join-Path $UpdateRoot 'Reports'
$MainReport = Join-Path $ReportRoot ('windows-self-update-' + $Stamp + '.txt')
$HelperReport = Join-Path $ReportRoot ('windows-self-update-helper-' + $Stamp + '.txt')

function Write-UpdateLine {
    param([string]$Text = '')
    [Console]::WriteLine($Text)
    [IO.File]::AppendAllText(
        $MainReport,
        $Text + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false)))
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    (Get-FileHash -Algorithm SHA256 -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
}

function Escape-SingleQuotedLiteral {
    param([string]$Value)
    ($Value -replace "'", "''")
}

function Resolve-StarterTarget {
    if (-not [string]::IsNullOrWhiteSpace($TargetStarterExe)) {
        $resolved = [IO.Path]::GetFullPath($TargetStarterExe)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw 'Übergebene Windows-Runner-EXE wurde nicht gefunden.'
        }
        return $resolved
    }

    $selfInfo = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID)
    if ($null -eq $selfInfo -or [int]$selfInfo.ParentProcessId -le 0) {
        throw 'Windows-Runner-Elternprozess konnte nicht ermittelt werden.'
    }

    $parent = Get-Process -Id ([int]$selfInfo.ParentProcessId) -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($parent.Path)) {
        throw 'Pfad der Windows-Runner-EXE konnte nicht ermittelt werden.'
    }

    if ($StarterProcessId -le 0) {
        $script:StarterProcessId = [int]$parent.Id
    }

    return [IO.Path]::GetFullPath($parent.Path)
}

try {
    [IO.Directory]::CreateDirectory($ReportRoot) | Out-Null
    [IO.Directory]::CreateDirectory($BackupRoot) | Out-Null
    [IO.File]::WriteAllText($MainReport, '', (New-Object Text.UTF8Encoding($false)))

    Write-UpdateLine '=== Respberry Windows Runner Self-Update ==='

    $TargetStarterExe = Resolve-StarterTarget
    if ($StarterProcessId -le 0) {
        $targetProcess = Get-Process | Where-Object {
            try { $_.Path -eq $TargetStarterExe } catch { $false }
        } | Select-Object -First 1

        if ($null -ne $targetProcess) {
            $StarterProcessId = [int]$targetProcess.Id
        }
    }

    $StarterDirectory = Split-Path -Parent $TargetStarterExe
    $StarterFileName = Split-Path -Leaf $TargetStarterExe
    $InstalledVersionText = [Diagnostics.FileVersionInfo]::GetVersionInfo($TargetStarterExe).FileVersion
    $InstalledVersion = New-Object Version($InstalledVersionText)

    Write-UpdateLine ('[PRÜFUNG] Installierte Version: ' + $InstalledVersionText)
    Write-UpdateLine ('[PRÜFUNG] Manifest: ' + $ManifestUrl)

    $manifestResponse = Invoke-WebRequest -UseBasicParsing -Uri $ManifestUrl -TimeoutSec 30
    if ($manifestResponse.StatusCode -ne 200) {
        throw ('Update-Manifest konnte nicht geladen werden. HTTP=' + $manifestResponse.StatusCode)
    }

    $manifest = $manifestResponse.Content | ConvertFrom-Json
    $latestVersionText = [string]$manifest.version
    $downloadUrl = [string]$manifest.downloadUrl
    $expectedSha = ([string]$manifest.sha256).Trim().ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($latestVersionText)) {
        throw 'Update-Manifest enthält keine Version.'
    }
    if ([string]::IsNullOrWhiteSpace($downloadUrl) -or $downloadUrl -notmatch '^https://') {
        throw 'Update-Manifest enthält keine gültige HTTPS-Download-URL.'
    }
    if ($expectedSha -notmatch '^[0-9a-f]{64}$') {
        throw 'Update-Manifest enthält keinen gültigen SHA-256.'
    }

    $latestVersion = New-Object Version($latestVersionText)
    Write-UpdateLine ('[PRÜFUNG] Verfügbare Version: ' + $latestVersionText)

    if ($latestVersion -le $InstalledVersion) {
        Write-UpdateLine '[OK] Kein Update erforderlich.'
        Write-UpdateLine '[RC] 0'
        exit 0
    }

    $TempExePath = Join-Path $UpdateRoot ($StarterFileName + '.download-' + $Stamp + '.exe')
    [IO.Directory]::CreateDirectory($UpdateRoot) | Out-Null

    Write-UpdateLine ('[DOWNLOAD] ' + $downloadUrl)
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $TempExePath -TimeoutSec 120

    if (-not (Test-Path -LiteralPath $TempExePath -PathType Leaf)) {
        throw 'Heruntergeladene EXE fehlt.'
    }

    $downloadSha = Get-FileSha256 $TempExePath
    if ($downloadSha -ne $expectedSha) {
        throw ('SHA-256 der heruntergeladenen EXE stimmt nicht. Erwartet=' + $expectedSha + ' Ist=' + $downloadSha)
    }

    $downloadVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($TempExePath).FileVersion
    if ($downloadVersion -ne $latestVersionText) {
        throw ('Heruntergeladene EXE meldet unerwartete Version. Erwartet=' + $latestVersionText + ' Ist=' + $downloadVersion)
    }

    Write-UpdateLine ('[PASS] Download SHA256=' + $downloadSha)
    Write-UpdateLine ('[PASS] Download-Version=' + $downloadVersion)

    $BackupStarterExe = Join-Path $BackupRoot $StarterFileName
    Copy-Item -LiteralPath $TargetStarterExe -Destination $BackupStarterExe -Force

    if ((Get-FileSha256 $TargetStarterExe) -ne (Get-FileSha256 $BackupStarterExe)) {
        throw 'EXE-Backup ist nicht bytegleich.'
    }

    Get-ChildItem -LiteralPath $StarterDirectory -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like 'RespberryStarter*.cs' -or
            $_.Name -like 'README*' -or
            $_.Name -like '*build*'
        } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $BackupRoot -Force
        }

    Write-UpdateLine ('[PASS] Backup: ' + $BackupRoot)

    $UpdaterProcessId = [int]$PID
    $CurrentPowerShellExe = (Get-Process -Id $UpdaterProcessId -ErrorAction Stop).Path
    $HelperPath = Join-Path $env:TEMP ('Respberry-Windows-Runner-exchange-' + $Stamp + '.ps1')

    $helper = @'
$ErrorActionPreference = 'Stop'
[int]$StarterProcessId = __STARTER_PID__
[int]$UpdaterProcessId = __UPDATER_PID__
$TargetStarterExe = '__TARGET__'
$TempExePath = '__TEMP_EXE__'
$BackupStarterExe = '__BACKUP__'
$ExpectedExeSha = '__EXE_SHA__'
$ExpectedVersion = '__VERSION__'
$HelperReport = '__REPORT__'

function Write-HelperLine {
    param([string]$Text = '')
    [Console]::WriteLine($Text)
    [IO.File]::AppendAllText(
        $HelperReport,
        $Text + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false)))
}

function Get-HelperFileSha256 {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    (Get-FileHash -Algorithm SHA256 -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
}

try {
    [IO.File]::WriteAllText($HelperReport, '', (New-Object Text.UTF8Encoding($false)))

    for ($i = 0; $i -lt 240; $i++) {
        if ($null -eq (Get-Process -Id $UpdaterProcessId -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 250
    }
    if ($null -ne (Get-Process -Id $UpdaterProcessId -ErrorAction SilentlyContinue)) {
        throw 'Updater-Prozess läuft noch.'
    }

    function Get-TargetRunnerProcesses {
        $target = [IO.Path]::GetFullPath($TargetStarterExe)

        @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try {
                -not [string]::IsNullOrWhiteSpace($_.Path) -and
                [string]::Equals(
                    [IO.Path]::GetFullPath($_.Path),
                    $target,
                    [StringComparison]::OrdinalIgnoreCase)
            }
            catch {
                $false
            }
        })
    }

    function Test-TargetExeUnlocked {
        try {
            $stream = [IO.File]::Open(
                $TargetStarterExe,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::None)
            $stream.Dispose()
            return $true
        }
        catch {
            return $false
        }
    }

    $runnerProcesses = Get-TargetRunnerProcesses
    foreach ($runnerProcess in $runnerProcesses) {
        try { [void]$runnerProcess.CloseMainWindow() } catch {}
    }

    for ($i = 0; $i -lt 40; $i++) {
        if ((Get-TargetRunnerProcesses).Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    }

    $runnerProcesses = Get-TargetRunnerProcesses
    foreach ($runnerProcess in $runnerProcesses) {
        Stop-Process -Id $runnerProcess.Id -Force -ErrorAction Stop
    }

    for ($i = 0; $i -lt 80; $i++) {
        if ((Get-TargetRunnerProcesses).Count -eq 0 -and (Test-TargetExeUnlocked)) {
            break
        }

        Start-Sleep -Milliseconds 250
    }

    if ((Get-TargetRunnerProcesses).Count -gt 0) {
        throw 'Mindestens ein Windows-Runner-Prozess läuft nach dem Beenden weiter.'
    }

    if (-not (Test-TargetExeUnlocked)) {
        throw 'Windows-Runner-EXE bleibt nach dem Prozessende gesperrt.'
    }

    Write-HelperLine '[PASS] Runner beendet und Ziel-EXE freigegeben.'

    if ((Get-HelperFileSha256 $TempExePath) -ne $ExpectedExeSha) {
        throw 'Temporäre EXE SHA falsch.'
    }

    try {
        Copy-Item -LiteralPath $TempExePath -Destination $TargetStarterExe -Force
    }
    catch {
        if (-not (Test-Path -LiteralPath $TargetStarterExe -PathType Leaf)) {
            Copy-Item -LiteralPath $BackupStarterExe -Destination $TargetStarterExe -Force
        }
        throw
    }

    if ((Get-HelperFileSha256 $TargetStarterExe) -ne $ExpectedExeSha) {
        Copy-Item -LiteralPath $BackupStarterExe -Destination $TargetStarterExe -Force
        throw 'Installations-SHA falsch; Rollback ausgeführt.'
    }

    $installedVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($TargetStarterExe).FileVersion
    if ($installedVersion -ne $ExpectedVersion) {
        Copy-Item -LiteralPath $BackupStarterExe -Destination $TargetStarterExe -Force
        throw ('Installierte Dateiversion falsch; Rollback ausgeführt. Ist=' + $installedVersion)
    }

    Remove-Item -LiteralPath $TempExePath -Force -ErrorAction SilentlyContinue

    Write-HelperLine ('[OK] EXE ersetzt. Dateiversion=' + $ExpectedVersion)
    Write-HelperLine ('[OK] Installations-SHA=' + $ExpectedExeSha)
    Start-Process -FilePath $TargetStarterExe
    Write-HelperLine '[RC] 0'
    exit 0
}
catch {
    try {
        Write-HelperLine ('[FEHLER] ' + $_.Exception.Message)
        Write-HelperLine '[RC] 41'
    }
    catch {}
    exit 41
}
'@

    $replacements = @{
        '__STARTER_PID__' = [string]$StarterProcessId
        '__UPDATER_PID__' = [string]$UpdaterProcessId
        '__TARGET__' = (Escape-SingleQuotedLiteral $TargetStarterExe)
        '__TEMP_EXE__' = (Escape-SingleQuotedLiteral $TempExePath)
        '__BACKUP__' = (Escape-SingleQuotedLiteral $BackupStarterExe)
        '__EXE_SHA__' = $expectedSha
        '__VERSION__' = (Escape-SingleQuotedLiteral $latestVersionText)
        '__REPORT__' = (Escape-SingleQuotedLiteral $HelperReport)
    }

    foreach ($pair in $replacements.GetEnumerator()) {
        $helper = $helper.Replace($pair.Key, $pair.Value)
    }

    [IO.File]::WriteAllText($HelperPath, $helper, (New-Object Text.UTF8Encoding($true)))

    $helperProcess = Start-Process -FilePath $CurrentPowerShellExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $HelperPath) -PassThru

    Write-UpdateLine ('[HELPER] PID: ' + $helperProcess.Id)
    Write-UpdateLine ('[UPDATE] ' + $InstalledVersionText + ' -> ' + $latestVersionText)
    Write-UpdateLine '[RC] 0'
    exit 0
}
catch {
    try {
        Write-UpdateLine ('[FEHLER] ' + $_.Exception.Message)
        Write-UpdateLine '[RC] 40'
    }
    catch {}
    exit 40
}

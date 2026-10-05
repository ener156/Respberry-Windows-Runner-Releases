param(
    [string]$TargetStarterExe = '',
    [int]$StarterProcessId = 0,
    [string]$ReadyFile = '',
    [string]$ProgressFile = '',
    [string]$ExpectedVersion = '',
    [int]$ExpectedVersionCode = 0,
    [string]$ExpectedDownloadUrl = '',
    [string]$ExpectedExeSha = ''
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

function Write-ProgressState {
    param(
        [string]$Phase,
        [long]$Done = 0,
        [long]$Total = 0,
        [int]$Percent = -1,
        [string]$Detail = ''
    )

    if ([string]::IsNullOrWhiteSpace($ProgressFile)) { return }
    $directory = Split-Path -Parent $ProgressFile
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    $safeDetail = (($Detail -replace '[\r\n\|]+', ' ').Trim())
    $text =
        $Phase + '|' + $Done + '|' + $Total + '|' + $Percent + '|' + $safeDetail
    [IO.File]::WriteAllText($ProgressFile, $text, (New-Object Text.UTF8Encoding($false)))
}

function Add-CacheBustUri {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Token
    )

    $separator = if ($Url.Contains('?')) { '&' } else { '?' }
    return $Url + $separator + 'respberry_cb=' + [Uri]::EscapeDataString($Token)
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    (Get-FileHash -Algorithm SHA256 -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
}

function Get-RunnerVersionCodeFromExe {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    try {
        $productVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($LiteralPath).ProductVersion
        if ([string]::IsNullOrWhiteSpace($productVersion)) { return 0 }

        $match = [regex]::Match(
            $productVersion,
            'RespberryVersionCode=(?<code>[0-9]+)',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if (-not $match.Success) { return 0 }

        $value = 0
        if ([int]::TryParse($match.Groups['code'].Value, [ref]$value)) {
            return $value
        }
    }
    catch {}

    return 0
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
    $InstalledVersionCode = Get-RunnerVersionCodeFromExe $TargetStarterExe

    Write-UpdateLine ('[PRÜFUNG] Installierte Version: ' + $InstalledVersionText + ' (Build ' + $InstalledVersionCode + ')')

    $snapshotProvided =
        -not [string]::IsNullOrWhiteSpace($ExpectedVersion) -or
        $ExpectedVersionCode -gt 0 -or
        -not [string]::IsNullOrWhiteSpace($ExpectedDownloadUrl) -or
        -not [string]::IsNullOrWhiteSpace($ExpectedExeSha)

    if ($snapshotProvided) {
        if ([string]::IsNullOrWhiteSpace($ExpectedVersion) -or
            [string]::IsNullOrWhiteSpace($ExpectedDownloadUrl) -or
            [string]::IsNullOrWhiteSpace($ExpectedExeSha)) {
            throw 'Vom Starter übergebener Update-Snapshot ist unvollständig.'
        }

        $latestVersionText = $ExpectedVersion
        $latestVersionCode = $ExpectedVersionCode
        $downloadUrl = $ExpectedDownloadUrl
        $expectedSha = $ExpectedExeSha.Trim().ToLowerInvariant()
        Write-UpdateLine '[PRÜFUNG] Verbindlicher Manifest-Snapshot vom Starter übernommen.'
    }
    else {
        Write-UpdateLine ('[PRÜFUNG] Manifest: ' + $ManifestUrl)
        $manifest = $null
        $manifestError = $null

        for ($manifestAttempt = 1; $manifestAttempt -le 3; $manifestAttempt++) {
            try {
                $manifestUri = Add-CacheBustUri -Url $ManifestUrl -Token ($Stamp + '-manifest-' + $manifestAttempt)
                $manifestResponse = Invoke-WebRequest -UseBasicParsing -Uri $manifestUri -TimeoutSec 30
                if ($manifestResponse.StatusCode -ne 200) {
                    throw ('HTTP=' + $manifestResponse.StatusCode)
                }

                $manifest = $manifestResponse.Content | ConvertFrom-Json
                break
            }
            catch {
                $manifestError = $_.Exception.Message
                Write-UpdateLine (
                    '[WARN] Manifest-Abruf Versuch ' + $manifestAttempt + '/3 fehlgeschlagen: ' +
                    $manifestError)
                if ($manifestAttempt -lt 3) {
                    Start-Sleep -Milliseconds (750 * $manifestAttempt)
                }
            }
        }

        if ($null -eq $manifest) {
            throw ('Update-Manifest konnte nach 3 Versuchen nicht geladen werden: ' + $manifestError)
        }

        $latestVersionText = [string]$manifest.version
        $latestVersionCode = 0
        if ($null -ne $manifest.versionCode) {
            [void][int]::TryParse([string]$manifest.versionCode, [ref]$latestVersionCode)
        }
        $downloadUrl = [string]$manifest.downloadUrl
        $expectedSha = ([string]$manifest.sha256).Trim().ToLowerInvariant()
    }

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
    Write-UpdateLine ('[PRÜFUNG] Verfügbare Version: ' + $latestVersionText + ' (Build ' + $latestVersionCode + ')')

    $updateRequired =
        if ($latestVersionCode -gt 0 -and $InstalledVersionCode -gt 0) {
            $latestVersionCode -gt $InstalledVersionCode
        }
        else {
            $latestVersion -gt $InstalledVersion
        }

    if (-not $updateRequired) {
        Write-UpdateLine '[OK] Kein Update erforderlich.'
        Write-UpdateLine '[RC] 0'
        exit 0
    }

    $TempExePath = Join-Path $UpdateRoot ($StarterFileName + '.download-' + $Stamp + '.exe')
    [IO.Directory]::CreateDirectory($UpdateRoot) | Out-Null

    $downloadVerified = $false
    $downloadError = $null
    $downloadSha = ''
    $downloadVersion = ''
    $downloadVersionCode = 0

    for ($downloadAttempt = 1; $downloadAttempt -le 3; $downloadAttempt++) {
        try {
            Remove-Item -LiteralPath $TempExePath -Force -ErrorAction SilentlyContinue
            $requestUrl = Add-CacheBustUri -Url $downloadUrl -Token ($Stamp + '-exe-' + $downloadAttempt)

            Write-UpdateLine (
                '[DOWNLOAD] Versuch ' + $downloadAttempt + '/3: ' + $downloadUrl)
            Write-ProgressState -Phase 'download' -Done 0 -Total 0 -Percent 0

            $httpClient = [Net.Http.HttpClient]::new()
            $httpClient.Timeout = [TimeSpan]::FromSeconds(120)
            $response = $null
            $inputStream = $null
            $outputStream = $null

            try {
                $response = $httpClient.GetAsync(
                    $requestUrl,
                    [Net.Http.HttpCompletionOption]::ResponseHeadersRead
                ).GetAwaiter().GetResult()

                if (-not $response.IsSuccessStatusCode) {
                    throw ('Update-Download fehlgeschlagen. HTTP=' + [int]$response.StatusCode)
                }

                $totalBytes = 0L
                if ($null -ne $response.Content.Headers.ContentLength) {
                    $totalBytes = [long]$response.Content.Headers.ContentLength
                }

                $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $outputStream = [IO.File]::Open(
                    $TempExePath,
                    [IO.FileMode]::Create,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::None)
                $buffer = New-Object byte[] (64 * 1024)
                $doneBytes = 0L

                while ($true) {
                    $read = $inputStream.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }

                    $outputStream.Write($buffer, 0, $read)
                    $doneBytes += $read
                    $percent =
                        if ($totalBytes -gt 0) {
                            [Math]::Min(100, [int](($doneBytes * 100L) / $totalBytes))
                        }
                        else {
                            -1
                        }
                    Write-ProgressState -Phase 'download' -Done $doneBytes -Total $totalBytes -Percent $percent
                }

                $outputStream.Flush()
                Write-ProgressState -Phase 'downloaded' -Done $doneBytes -Total $totalBytes -Percent 100
            }
            finally {
                if ($null -ne $outputStream) { $outputStream.Dispose() }
                if ($null -ne $inputStream) { $inputStream.Dispose() }
                if ($null -ne $response) { $response.Dispose() }
                if ($null -ne $httpClient) { $httpClient.Dispose() }
            }

            if (-not (Test-Path -LiteralPath $TempExePath -PathType Leaf)) {
                throw 'Heruntergeladene EXE fehlt.'
            }

            $downloadSha = Get-FileSha256 $TempExePath
            if ($downloadSha -ne $expectedSha) {
                throw (
                    'SHA-256 der heruntergeladenen EXE stimmt nicht. Erwartet=' +
                    $expectedSha + ' Ist=' + $downloadSha)
            }

            $downloadVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($TempExePath).FileVersion
            if ($downloadVersion -ne $latestVersionText) {
                throw (
                    'Heruntergeladene EXE meldet unerwartete Version. Erwartet=' +
                    $latestVersionText + ' Ist=' + $downloadVersion)
            }

            $downloadVersionCode = Get-RunnerVersionCodeFromExe $TempExePath
            if ($latestVersionCode -gt 0 -and $downloadVersionCode -ne $latestVersionCode) {
                throw (
                    'Heruntergeladene EXE meldet unerwarteten Build. Erwartet=' +
                    $latestVersionCode + ' Ist=' + $downloadVersionCode)
            }

            $downloadVerified = $true
            break
        }
        catch {
            $downloadError = $_.Exception.Message
            Write-UpdateLine (
                '[WARN] EXE-Download/Validierung Versuch ' + $downloadAttempt +
                '/3 fehlgeschlagen: ' + $downloadError)
            Remove-Item -LiteralPath $TempExePath -Force -ErrorAction SilentlyContinue

            if ($downloadAttempt -lt 3) {
                Start-Sleep -Milliseconds (1000 * $downloadAttempt)
            }
        }
    }

    if (-not $downloadVerified) {
        throw ('Update-EXE konnte nach 3 Versuchen nicht sicher geladen werden: ' + $downloadError)
    }

    Write-UpdateLine ('[PASS] Download SHA256=' + $downloadSha)
    Write-UpdateLine ('[PASS] Download-Version=' + $downloadVersion)
    Write-UpdateLine ('[PASS] Download-Build=' + $downloadVersionCode)

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
[int]$ExpectedVersionCode = __VERSION_CODE__
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

function Get-HelperRunnerVersionCode {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    try {
        $productVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($LiteralPath).ProductVersion
        if ([string]::IsNullOrWhiteSpace($productVersion)) { return 0 }
        $match = [regex]::Match($productVersion, 'RespberryVersionCode=(?<code>[0-9]+)')
        if (-not $match.Success) { return 0 }
        return [int]$match.Groups['code'].Value
    }
    catch {
        return 0
    }
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

    # Der Runner wartet jetzt selbst auf die Ready-Bestätigung und schließt sich
    # anschließend geordnet. Deshalb bekommt er zuerst ausreichend Zeit für sein
    # normales Prozessende, bevor der Helper überhaupt ein Fenster schließt oder
    # einen Prozess erzwingt.
    if ($StarterProcessId -gt 0) {
        for ($i = 0; $i -lt 480; $i++) {
            if ($null -eq (Get-Process -Id $StarterProcessId -ErrorAction SilentlyContinue)) {
                break
            }

            Start-Sleep -Milliseconds 250
        }
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

    $installedVersionCode = Get-HelperRunnerVersionCode $TargetStarterExe
    if ($ExpectedVersionCode -gt 0 -and $installedVersionCode -ne $ExpectedVersionCode) {
        Copy-Item -LiteralPath $BackupStarterExe -Destination $TargetStarterExe -Force
        throw ('Installierter Build falsch; Rollback ausgeführt. Ist=' + $installedVersionCode)
    }

    Remove-Item -LiteralPath $TempExePath -Force -ErrorAction SilentlyContinue

    Write-HelperLine ('[OK] EXE ersetzt. Dateiversion=' + $ExpectedVersion)
    Write-HelperLine ('[OK] VersionCode=' + $installedVersionCode)
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
        '__VERSION_CODE__' = [string]$latestVersionCode
        '__REPORT__' = (Escape-SingleQuotedLiteral $HelperReport)
    }

    foreach ($pair in $replacements.GetEnumerator()) {
        $helper = $helper.Replace($pair.Key, $pair.Value)
    }

    [IO.File]::WriteAllText($HelperPath, $helper, (New-Object Text.UTF8Encoding($true)))

    $helperProcess = Start-Process -FilePath $CurrentPowerShellExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $HelperPath) -PassThru

    if ($null -eq $helperProcess -or $helperProcess.HasExited) {
        throw 'Austausch-Helper konnte nicht dauerhaft gestartet werden.'
    }

    Write-UpdateLine ('[HELPER] PID: ' + $helperProcess.Id)

    Write-ProgressState -Phase 'ready' -Done 0 -Total 0 -Percent 100

    if (-not [string]::IsNullOrWhiteSpace($ReadyFile)) {
        $readyDirectory = Split-Path -Parent $ReadyFile
        if (-not [string]::IsNullOrWhiteSpace($readyDirectory)) {
            [IO.Directory]::CreateDirectory($readyDirectory) | Out-Null
        }

        [IO.File]::WriteAllText(
            $ReadyFile,
            ('READY|PID=' + $helperProcess.Id + '|VERSION=' + $latestVersionText + '|VERSION_CODE=' + $latestVersionCode),
            (New-Object Text.UTF8Encoding($false)))
        Write-UpdateLine ('[HANDOFF] Austausch-Helper bereit gemeldet.')
    }

    Write-UpdateLine ('[UPDATE] ' + $InstalledVersionText + ' (Build ' + $InstalledVersionCode + ') -> ' + $latestVersionText + ' (Build ' + $latestVersionCode + ')')
    Write-UpdateLine '[RC] 0'
    exit 0
}
catch {
    try {
        Write-ProgressState -Phase 'error' -Done 0 -Total 0 -Percent -1 -Detail $_.Exception.Message
        Write-UpdateLine ('[FEHLER] ' + $_.Exception.Message)
        Write-UpdateLine '[RC] 40'
    }
    catch {}
    exit 40
}

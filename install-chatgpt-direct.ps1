# ChatGPT Direct Toolkit: Win+R -> paste one PowerShell command -> Enter.
# This public bootstrap contains NO private repository code or account credentials.
# It downloads the authenticated user's permitted private repository via GitHub.
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo = 'ZTD38F/chatgpt-state-orchestrator'
$Branch = 'main'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\ChatGPTDirect'

function Say([string]$s) { Write-Host ("[ChatGPT Direct] " + $s) -ForegroundColor Cyan }
function Find-Executable([string]$name, [string[]]$alternatives) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    foreach ($candidate in $alternatives) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}
function Require-Winget {
    $winget = Find-Executable 'winget.exe' @()
    if (-not $winget) {
        throw "Windows Package Manager (winget) is required to install missing dependencies automatically. Install App Installer from Microsoft Store or provide Python 3.10+ and GitHub CLI."
    }
    return $winget
}
function Resolve-Gh {
    $candidate = Find-Executable 'gh.exe' @(
        (Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\gh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe')
    )
    if ($candidate) { return $candidate }
    Say 'Installing GitHub CLI automatically (may request system permission)...'
    $wg = Require-Winget
    & $wg install --id GitHub.cli --exact --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget could not install GitHub CLI (exit $LASTEXITCODE)." }
    $candidate = Find-Executable 'gh.exe' @(
        (Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\gh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe')
    )
    if (-not $candidate) { throw 'GitHub CLI was installed but gh.exe could not be located.' }
    return $candidate
}
function Resolve-Python {
    $candidates = @(
        @{Path=(Find-Executable 'py.exe' @()); Args=@('-3')},
        @{Path=(Find-Executable 'python.exe' @()); Args=@()},
        @{Path=(Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'); Args=@()},
        @{Path=(Join-Path $env:ProgramFiles 'Python312\python.exe'); Args=@()}
    )
    foreach ($p in $candidates) {
        if (-not $p.Path -or -not (Test-Path -LiteralPath $p.Path -PathType Leaf)) { continue }
        try {
            $check = & $p.Path @($p.Args) -c 'import sys;print("OK" if sys.version_info >= (3,10) else "OLD")' 2>$null
            if ($LASTEXITCODE -eq 0 -and "$check".Trim() -eq 'OK') { return $p }
        } catch { }
    }
    Say 'Installing Python 3.12 automatically...'
    $wg = Require-Winget
    & $wg install --id Python.Python.3.12 --exact --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget could not install Python 3.12 (exit $LASTEXITCODE)." }
    foreach ($file in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:ProgramFiles 'Python312\python.exe')
    )) {
        if (Test-Path -LiteralPath $file -PathType Leaf) { return @{Path=$file;Args=@()} }
    }
    throw 'Python installed, but python.exe was not found. Reopen Windows Run and retry.'
}

if ($DryRun) {
    Say "Dry run: would use private repo $Repo, branch $Branch, and install into $InstallRoot."
    Say 'Production run installs missing Python/GitHub CLI, authorizes the owner, and installs locally.'
    exit 0
}
$Gh = Resolve-Gh
$Python = Resolve-Python
Say 'Prerequisites available.'

& $Gh auth status --hostname github.com 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Say 'Private source requires access. GitHub will request your sign-in in the browser.'
    & $Gh auth login --hostname github.com --git-protocol https --web --scopes repo
    if ($LASTEXITCODE -ne 0) { throw 'GitHub login was not completed.' }
}
& $Gh api ("repos/" + $Repo) --jq .private 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Your GitHub account cannot read the private repository $Repo. Ask the owner to grant access or refresh GitHub's repo scope."
}
# Token lives only in this local PowerShell process. It is never stored in
# the repository, command line, installer log, URL, or download filename.
$Token = (& $Gh auth token).Trim()
if (-not $Token) { throw 'GitHub authentication token is missing.' }

$Temp = Join-Path $env:TEMP ('ChatGPTDirectSetup-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Temp | Out-Null
$Archive = Join-Path $Temp 'private-source.zip'
$Extract = Join-Path $Temp 'unpacked'
$Client = $null
try {
    Say 'Obtaining private source from your authorized GitHub account...'
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $Client = [System.Net.Http.HttpClient]::new($handler)
    $Client.DefaultRequestHeaders.UserAgent.ParseAdd('ChatGPTDirectBootstrap/1.0')
    $Client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$Token)
    $Url = 'https://api.github.com/repos/' + $Repo + '/zipball/' + $Branch
    $Response = $Client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $Response.IsSuccessStatusCode) {
        throw "GitHub access denied or download failed: HTTP $([int]$Response.StatusCode). Confirm that your GitHub account has private repository access."
    }
    $Stream = $Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $OutStream = [IO.File]::Open($Archive,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
    try { $Stream.CopyTo($OutStream) } finally { $OutStream.Dispose(); $Stream.Dispose() }
    $Response.Dispose()
    $Client.Dispose()
    $Client = $null
    $Token = $null

    Expand-Archive -LiteralPath $Archive -DestinationPath $Extract -Force
    $Root = Get-ChildItem -LiteralPath $Extract -Directory | Select-Object -First 1
    if (-not $Root) { throw 'GitHub returned an empty archive.' }
    $Module = Join-Path $Root.FullName 'integrations\chatgpt-direct'
    if (-not (Test-Path -LiteralPath (Join-Path $Module 'pyproject.toml'))) {
        throw 'Expected integration module not present in private release.'
    }
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    $Venv = Join-Path $InstallRoot 'venv'
    $PythonExe = Join-Path $Venv 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $PythonExe)) {
        Say 'Creating isolated Python environment...'
        if ($Python.Args.Count -gt 0) {
            & $Python.Path -3 -m venv $Venv
        } else {
            & $Python.Path -m venv $Venv
        }
        if ($LASTEXITCODE -ne 0) { throw 'Python environment creation failed.' }
    }
    Say 'Installing or updating ChatGPT Direct...'
    & $PythonExe -m pip install --disable-pip-version-check --upgrade --force-reinstall $Module
    if ($LASTEXITCODE -ne 0) { throw 'Python package installation failed.' }
    & $PythonExe -m playwright install chromium
    if ($LASTEXITCODE -ne 0) { throw 'Chromium installation failed.' }
    Say "Installed successfully: $InstallRoot"
    Say 'Launching ChatGPT login. If not already signed in, authenticate in your own browser.'
    & $PythonExe -m chatgpt_direct.cli login
    if ($LASTEXITCODE -ne 0) { throw 'ChatGPT sign-in was not confirmed.' }
    Say 'Ready. You can relaunch this same one-liner later to update the installation.'
    Say "CLI: $PythonExe -m chatgpt_direct.cli"
} finally {
    if ($Client) { $Client.Dispose() }
    $Token = $null
    if (Test-Path -LiteralPath $Temp) { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
}

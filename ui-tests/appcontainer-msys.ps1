param(
    [Parameter(Mandatory)]
    [string] $RuntimeRoot,

    [Parameter(Mandatory)]
    [string] $ExpectedSha256,

    [Parameter(Mandatory)]
    [string] $HelperPath,

    [Parameter(Mandatory)]
    [string] $ResultPath,

    [switch] $RequireAppContainer,

    [int] $TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

$runtime = @{
    Bash = Join-Path $RuntimeRoot 'usr\bin\bash.exe'
    Vim = Join-Path $RuntimeRoot 'usr\bin\vim.exe'
    Git = Join-Path $RuntimeRoot 'cmd\git.exe'
    Dll = Join-Path $RuntimeRoot 'usr\bin\msys-2.0.dll'
}

foreach ($entry in $runtime.GetEnumerator())
{
    if (!(Test-Path -LiteralPath $entry.Value))
    {
        throw "Missing $($entry.Key): $($entry.Value)"
    }
}

if (!(Test-Path -LiteralPath $HelperPath))
{
    throw "Missing helper: $HelperPath"
}

$actualHash = (Get-FileHash -LiteralPath $runtime.Dll -Algorithm SHA256).Hash
if ($actualHash -ne $ExpectedSha256)
{
    throw "Runtime hash mismatch: expected $ExpectedSha256, actual $actualHash"
}

$resultDirectory = Split-Path -Parent $ResultPath
New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
$workRoot = Join-Path $resultDirectory 'appcontainer-msys-work'
if (Test-Path -LiteralPath $workRoot)
{
    Remove-Item -LiteralPath $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $workRoot | Out-Null

function Invoke-CapturedProcess
{
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $FileName,

        [string[]] $Arguments = @(),

        [string] $WorkingDirectory = $workRoot,

        [int[]] $AllowedExitCodes = @(0)
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $Arguments)
    {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process)
    {
        return [pscustomobject]@{
            Name = $Name
            FileName = $FileName
            Arguments = $Arguments
            Exited = $false
            ExitCode = $null
            StdOut = ''
            StdErr = 'Process.Start returned null'
            Passed = $false
        }
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $exited = $process.WaitForExit($TimeoutSeconds * 1000)
    if (!$exited)
    {
        $process.Kill($true)
        $process.WaitForExit()
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $passed = $exited -and $process.ExitCode -in $AllowedExitCodes

    [pscustomobject]@{
        Name = $Name
        FileName = $FileName
        Arguments = $Arguments
        Exited = $exited
        ExitCode = $process.ExitCode
        StdOut = $stdout
        StdErr = $stderr
        Passed = $passed
    }
}

$tests = [Collections.Generic.List[object]]::new()
$tests.Add((Invoke-CapturedProcess -Name 'NamespaceHelper' -FileName $HelperPath))
$tests.Add((Invoke-CapturedProcess -Name 'VimVersion' -FileName $runtime.Vim `
    -Arguments @('--version')))
$tests.Add((Invoke-CapturedProcess -Name 'BashVersion' -FileName $runtime.Bash `
    -Arguments @('--version')))
$tests.Add((Invoke-CapturedProcess -Name 'BashEcho' -FileName $runtime.Bash `
    -Arguments @('-lc', 'echo MSYS_APPCONTAINER_OK')))
$tests.Add((Invoke-CapturedProcess -Name 'BashPipelineFork' -FileName $runtime.Bash `
    -Arguments @('-lc', 'printf alpha | tr a-z A-Z; (printf child) & wait')))
$tests.Add((Invoke-CapturedProcess -Name 'GitVersion' -FileName $runtime.Git `
    -Arguments @('--version')))

$sourceRepo = Join-Path $workRoot 'source'
$bareRepo = Join-Path $workRoot 'source.git'
$cloneRepo = Join-Path $workRoot 'clone'
New-Item -ItemType Directory -Path $sourceRepo | Out-Null

$tests.Add((Invoke-CapturedProcess -Name 'GitInit' -FileName $runtime.Git `
    -Arguments @('init', $sourceRepo)))
$tests.Add((Invoke-CapturedProcess -Name 'GitConfigName' -FileName $runtime.Git `
    -Arguments @('-C', $sourceRepo, 'config', 'user.name', 'MXC Test')))
$tests.Add((Invoke-CapturedProcess -Name 'GitConfigEmail' -FileName $runtime.Git `
    -Arguments @('-C', $sourceRepo, 'config', 'user.email',
        'mxc-test@example.invalid')))

Set-Content -LiteralPath (Join-Path $sourceRepo 'payload.txt') -Value 'payload'
$tests.Add((Invoke-CapturedProcess -Name 'GitAdd' -FileName $runtime.Git `
    -Arguments @('-C', $sourceRepo, 'add', 'payload.txt')))
$tests.Add((Invoke-CapturedProcess -Name 'GitCommit' -FileName $runtime.Git `
    -Arguments @('-C', $sourceRepo, 'commit', '-m', 'initial')))
$tests.Add((Invoke-CapturedProcess -Name 'GitCloneBare' -FileName $runtime.Git `
    -Arguments @('clone', '--bare', $sourceRepo, $bareRepo)))

$fileUri = 'file:///' + ($bareRepo -replace '\\', '/')
$tests.Add((Invoke-CapturedProcess -Name 'GitCloneFileProtocol' `
    -FileName $runtime.Git -Arguments @('clone', $fileUri, $cloneRepo)))
$tests.Add((Invoke-CapturedProcess -Name 'GitShellAlias' -FileName $runtime.Git `
    -Arguments @('-C', $sourceRepo, '-c',
        'alias.msys=!sh -c "printf GIT_SHELL_OK"', 'msys')))

$helperOutput = ($tests | Where-Object Name -eq 'NamespaceHelper').StdOut
$helperIsAppContainer = $helperOutput -match '(?m)^IS_APPCONTAINER=1\r?$'
$helperSkipped = $helperOutput -match '(?m)^SKIP=not-appcontainer\r?$'
$helperModePassed = if ($RequireAppContainer)
{
    $helperIsAppContainer -and !$helperSkipped
}
else
{
    $helperSkipped -or $helperIsAppContainer
}

$passed = $helperModePassed -and
    !($tests | Where-Object { !$_.Passed })

$report = [pscustomobject]@{
    CapturedAt = [DateTimeOffset]::Now.ToString('o')
    Identity = "$env:USERDOMAIN\$env:USERNAME"
    SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    RuntimeRoot = $RuntimeRoot
    RuntimeSha256 = $actualHash
    RequireAppContainer = [bool] $RequireAppContainer
    HelperIsAppContainer = $helperIsAppContainer
    HelperModePassed = $helperModePassed
    Passed = $passed
    Tests = $tests
}

$report | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $ResultPath -Encoding utf8
$report | ConvertTo-Json -Depth 8

if (!$passed)
{
    throw "MSYS AppContainer validation failed; see $ResultPath"
}

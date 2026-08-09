[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Docker', 'Native')]
    [string]$Backend = 'Auto',

    [string]$QuartusSh = $env:QUARTUS_SH,

    [string]$Python = $env:PYTHON,

    [string]$OutputDirectory = 'dist',

    [switch]$SkipPackage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDirectory = Split-Path -Parent $ScriptDirectory
$RawBitstream = Join-Path $ProjectDirectory 'src\fpga\build\output_files\ap_core.rbf'
$PocketBitstream = Join-Path $ProjectDirectory 'pkg\Cores\K3V.GBA\bitstream.rbf_r'
$BuildOutput = Join-Path $ProjectDirectory 'build_output'
$BuildLog = Join-Path $BuildOutput 'quartus-build.log'
$FreshnessLog = Join-Path $BuildOutput 'prebuild-freshness.txt'
$QuartusImage = 'raetro/quartus@sha256:817a783727492269d33aa98c903e8efc216e95d785ee76bfc8f426eddee98d0b'

function Resolve-PythonCommand {
    if ($Python) {
        return [pscustomobject]@{ Executable = $Python; Prefix = @() }
    }

    foreach ($Name in @('python3', 'python')) {
        $Command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue
        if ($Command) {
            return [pscustomobject]@{ Executable = $Command.Source; Prefix = @() }
        }
    }

    $Launcher = Get-Command 'py' -CommandType Application -ErrorAction SilentlyContinue
    if ($Launcher) {
        return [pscustomobject]@{ Executable = $Launcher.Source; Prefix = @('-3') }
    }

    if ($env:USERPROFILE) {
        $CodexPython = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
        if (Test-Path -LiteralPath $CodexPython -PathType Leaf) {
            return [pscustomobject]@{ Executable = $CodexPython; Prefix = @() }
        }
    }

    throw 'Python 3 is required. Set -Python or the PYTHON environment variable.'
}

function Invoke-Python {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Command,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $AllArguments = @($Command.Prefix) + $Arguments
    & $Command.Executable $AllArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed with exit code $LASTEXITCODE"
    }
}

function Resolve-QuartusCommand {
    if ($QuartusSh) {
        if (Test-Path -LiteralPath $QuartusSh -PathType Leaf) {
            return (Resolve-Path -LiteralPath $QuartusSh).Path
        }
        $ExplicitCommand = Get-Command $QuartusSh -CommandType Application -ErrorAction SilentlyContinue
        if ($ExplicitCommand) {
            return $ExplicitCommand.Source
        }
        throw "Quartus executable not found: $QuartusSh"
    }

    foreach ($Name in @('quartus_sh.exe', 'quartus_sh')) {
        $Command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue
        if ($Command) {
            return $Command.Source
        }
    }

    $Candidates = @()
    if ($env:QUARTUS_ROOTDIR) {
        $Candidates += Join-Path $env:QUARTUS_ROOTDIR 'bin64\quartus_sh.exe'
        $Candidates += Join-Path $env:QUARTUS_ROOTDIR 'bin\quartus_sh.exe'
    }
    $Candidates += 'C:\intelFPGA_lite\21.1\quartus\bin64\quartus_sh.exe'

    foreach ($Candidate in $Candidates) {
        if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
    }

    return $null
}

$PythonCommand = Resolve-PythonCommand
$NativeQuartus = $null
if ($Backend -ne 'Docker') {
    $NativeQuartus = Resolve-QuartusCommand
}
if ($Backend -eq 'Auto') {
    if ($NativeQuartus) {
        $Backend = 'Native'
    }
    elseif (Get-Command 'docker' -CommandType Application -ErrorAction SilentlyContinue) {
        $Backend = 'Docker'
    }
    else {
        throw 'Neither Quartus 21.1.1 nor Docker is available. Use -QuartusSh or install a build backend.'
    }
}

New-Item -ItemType Directory -Path $BuildOutput -Force | Out-Null
Push-Location $ProjectDirectory
try {
    $BuildStartedUtc = [DateTime]::UtcNow

    # A failed compile must never leave an older image looking like the result
    # of this invocation. These are the only two generated bitstream targets.
    Remove-Item -LiteralPath $RawBitstream -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $PocketBitstream -Force -ErrorAction SilentlyContinue

    $FreshnessSources = @(
        'generate.tcl',
        'src\fpga\apf\apf_constraints.sdc',
        'src\fpga\apf\apf_top.v',
        'src\fpga\apf\io_bridge_peripheral.v',
        'src\fpga\apf\mf_datatable.v',
        'src\fpga\build\ap_core.qsf',
        'src\fpga\core\core_top.sv',
        'src\fpga\core\rtc_persistence.sv',
        'src\fpga\gba\gba_gpioRTCSolarGyro.vhd',
        'src\fpga\gba\gba_memorymux.vhd',
        'src\fpga\gba\gba_rtc_clock.vhd',
        'src\fpga\gba\gba_top.vhd',
        'src\fpga\pocket\data_loader.sv',
        'src\fpga\pocket\data_unloader.sv',
        'src\fpga\pocket\psram.sv'
    )
    $FreshnessLines = @(
        "build_started_utc=$($BuildStartedUtc.ToString('o'))",
        "source_commit=$(git rev-parse HEAD)",
        "raw_bitstream_absent_before_compile=$(-not (Test-Path -LiteralPath $RawBitstream))",
        "pocket_bitstream_absent_before_compile=$(-not (Test-Path -LiteralPath $PocketBitstream))"
    )
    $FreshnessHashes = @{}
    foreach ($RelativeSource in $FreshnessSources) {
        $SourcePath = Join-Path $ProjectDirectory $RelativeSource
        $SourceItem = Get-Item -LiteralPath $SourcePath
        $SourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $FreshnessHashes[$RelativeSource] = $SourceHash
        $FreshnessLines += "source_sha256=$SourceHash  $($RelativeSource.Replace('\', '/'))"
        $FreshnessLines += "source_mtime_utc=$($SourceItem.LastWriteTimeUtc.ToString('o'))  $($RelativeSource.Replace('\', '/'))"
    }
    [System.IO.File]::WriteAllLines(
        $FreshnessLog,
        [string[]]$FreshnessLines,
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Host "=== Starting Quartus build ($Backend) ==="
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if ($Backend -eq 'Native') {
            if (-not $NativeQuartus) {
                throw 'Native Quartus was requested but quartus_sh could not be found.'
            }

            $OriginalPath = $env:PATH
            $OriginalProjectRoot = $env:K3V_PROJECT_ROOT
            $OriginalQuartusRoot = $env:QUARTUS_ROOTDIR
            $OriginalTclLibrary = $env:TCL_LIBRARY
            $QuartusBin = Split-Path -Parent $NativeQuartus
            $QuartusRoot = Split-Path -Parent $QuartusBin
            $QuartusEnvironmentRoot = $QuartusRoot
            $QuartusTclLibrary = Join-Path $QuartusBin 'tcl8.6'
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                # Quartus 21.1's embedded Tcl loader cannot initialize from
                # some Windows paths containing spaces. Use the filesystem's
                # existing 8.3 aliases for environment paths when available.
                $FileSystem = New-Object -ComObject Scripting.FileSystemObject
                $QuartusEnvironmentRoot = $FileSystem.GetFolder($QuartusRoot).ShortPath
                $QuartusTclLibrary = $FileSystem.GetFolder($QuartusTclLibrary).ShortPath
            }
            $env:PATH = "$QuartusBin;$OriginalPath"
            $env:K3V_PROJECT_ROOT = $ProjectDirectory
            $env:QUARTUS_ROOTDIR = $QuartusEnvironmentRoot
            $env:TCL_LIBRARY = $QuartusTclLibrary
            try {
                $QuartusVersionOutput = (& $NativeQuartus --version 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -ne 0 -or $QuartusVersionOutput -notmatch 'Version 21\.1\.1 Build 850') {
                    throw "This release requires Quartus 21.1.1 Build 850; found:`n$QuartusVersionOutput"
                }
                Write-Host $QuartusVersionOutput

                & $NativeQuartus -t generate.tcl 2>&1 | Tee-Object -FilePath $BuildLog
                $CompileExitCode = $LASTEXITCODE
            }
            finally {
                $env:PATH = $OriginalPath
                $env:K3V_PROJECT_ROOT = $OriginalProjectRoot
                $env:QUARTUS_ROOTDIR = $OriginalQuartusRoot
                $env:TCL_LIBRARY = $OriginalTclLibrary
            }
        }
        else {
            $Docker = Get-Command 'docker' -CommandType Application -ErrorAction Stop
            $Mount = "type=bind,src=$ProjectDirectory,dst=/build"
            & $Docker.Source run --rm --platform linux/amd64 `
                --mount $Mount -w /build $QuartusImage `
                quartus_sh -t generate.tcl 2>&1 | Tee-Object -FilePath $BuildLog
            $CompileExitCode = $LASTEXITCODE
        }
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }

    if ($CompileExitCode -ne 0) {
        throw "Quartus build failed with exit code $CompileExitCode. See $BuildLog"
    }
    if (-not (Test-Path -LiteralPath $RawBitstream -PathType Leaf)) {
        throw "Quartus completed without producing $RawBitstream"
    }
    if ((Get-Item -LiteralPath $RawBitstream).Length -eq 0) {
        throw "Quartus produced an empty bitstream: $RawBitstream"
    }
    if ((Get-Item -LiteralPath $RawBitstream).LastWriteTimeUtc -lt $BuildStartedUtc.AddSeconds(-2)) {
        throw "Quartus bitstream predates this build invocation: $RawBitstream"
    }

    $StaSummary = Join-Path $ProjectDirectory 'src\fpga\build\output_files\ap_core.sta.summary'
    if (-not (Test-Path -LiteralPath $StaSummary -PathType Leaf)) {
        Remove-Item -LiteralPath $RawBitstream -Force -ErrorAction SilentlyContinue
        throw "Quartus completed without producing the STA summary: $StaSummary"
    }
    if ((Get-Item -LiteralPath $StaSummary).LastWriteTimeUtc -lt $BuildStartedUtc.AddSeconds(-2)) {
        Remove-Item -LiteralPath $RawBitstream -Force -ErrorAction SilentlyContinue
        throw "Quartus STA summary predates this build invocation: $StaSummary"
    }

    $RequiredReports = @(
        'src\fpga\build\output_files\ap_core.fit.summary',
        'src\fpga\build\output_files\ap_core.flow.rpt',
        'src\fpga\build\output_files\ap_core.sta.summary',
        'build_output\reports\ap_core.sta.paths_setup.rpt',
        'build_output\reports\ap_core.sta.paths_setup_current_0c.rpt',
        'build_output\reports\ap_core.sta.paths_hold.rpt',
        'build_output\reports\ap_core.sta.clock_summary.rpt',
        'build_output\reports\ap_core.sta.sdram_write.rpt',
        'build_output\reports\ap_core.sta.sdram_read.rpt',
        'build_output\reports\ap_core.sta.cram0_output_setup.rpt',
        'build_output\reports\ap_core.sta.cram0_input_setup.rpt',
        'build_output\reports\ap_core.sta.cram0_output_hold.rpt',
        'build_output\reports\ap_core.sta.cram0_input_hold.rpt'
    )
    foreach ($RelativeReport in $RequiredReports) {
        $ReportPath = Join-Path $ProjectDirectory $RelativeReport
        if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf) -or
            (Get-Item -LiteralPath $ReportPath).Length -eq 0 -or
            (Get-Item -LiteralPath $ReportPath).LastWriteTimeUtc -lt $BuildStartedUtc.AddSeconds(-2)) {
            Remove-Item -LiteralPath $RawBitstream -Force -ErrorAction SilentlyContinue
            throw "Required fresh Quartus report is missing, empty, or stale: $ReportPath"
        }
    }

    Write-Host '=== Quartus STA summary ==='
    Get-Content -LiteralPath $StaSummary
    $NegativeSlack = Select-String -LiteralPath $StaSummary -Pattern '^\s*Slack\s*:\s*-'
    if ($NegativeSlack) {
        # A syntactically successful compile with negative slack is not a
        # releasable hardware image.  Remove both generated targets so a later
        # packaging command cannot mistake the failed build for a valid one.
        Remove-Item -LiteralPath $RawBitstream -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $PocketBitstream -Force -ErrorAction SilentlyContinue
        throw "Quartus STA reports negative slack; refusing to create a release bitstream."
    }
    $CriticalWarnings = Select-String -LiteralPath $BuildLog -Pattern '^\s*Critical Warning'
    if ($CriticalWarnings) {
        Remove-Item -LiteralPath $RawBitstream -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $PocketBitstream -Force -ErrorAction SilentlyContinue
        $CriticalWarningText = ($CriticalWarnings | ForEach-Object { $_.Line }) -join "`n"
        throw "Quartus reported critical warnings; refusing to create a release bitstream:`n$CriticalWarningText"
    }

    # A long fitter run must describe the same source snapshot that was hashed
    # before compilation. Refuse the artifact if any synthesis input changed
    # while Quartus was running.
    $PostBuildLines = @("source_verification_utc=$([DateTime]::UtcNow.ToString('o'))")
    $ChangedSources = @()
    foreach ($RelativeSource in $FreshnessSources) {
        $SourcePath = Join-Path $ProjectDirectory $RelativeSource
        $CurrentHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $Unchanged = $CurrentHash -eq $FreshnessHashes[$RelativeSource]
        $PostBuildLines += "source_post_sha256=$CurrentHash  $($RelativeSource.Replace('\', '/'))"
        $PostBuildLines += "source_unchanged=$($Unchanged.ToString().ToLowerInvariant())  $($RelativeSource.Replace('\', '/'))"
        if (-not $Unchanged) {
            $ChangedSources += $RelativeSource
        }
    }
    [System.IO.File]::AppendAllLines(
        $FreshnessLog,
        [string[]]$PostBuildLines,
        [System.Text.UTF8Encoding]::new($false)
    )
    if ($ChangedSources.Count -ne 0) {
        Remove-Item -LiteralPath $RawBitstream -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $PocketBitstream -Force -ErrorAction SilentlyContinue
        throw "Synthesis source changed during Quartus compilation: $($ChangedSources -join ', ')"
    }

    Write-Host '=== Reversing bitstream for Analogue Pocket ==='
    Invoke-Python -Command $PythonCommand -Arguments @(
        (Join-Path $ScriptDirectory 'reverse_bitstream.py'),
        $RawBitstream,
        $PocketBitstream
    )

    $RawLength = (Get-Item -LiteralPath $RawBitstream).Length
    $PocketLength = (Get-Item -LiteralPath $PocketBitstream).Length
    if ($RawLength -ne $PocketLength) {
        throw "Bit reversal changed the file length ($RawLength to $PocketLength bytes)."
    }

    $BuildCompletedUtc = [DateTime]::UtcNow
    $ArtifactLines = @(
        "build_completed_utc=$($BuildCompletedUtc.ToString('o'))",
        "raw_bitstream_sha256=$((Get-FileHash -LiteralPath $RawBitstream -Algorithm SHA256).Hash.ToLowerInvariant())",
        "raw_bitstream_mtime_utc=$((Get-Item -LiteralPath $RawBitstream).LastWriteTimeUtc.ToString('o'))",
        "pocket_bitstream_sha256=$((Get-FileHash -LiteralPath $PocketBitstream -Algorithm SHA256).Hash.ToLowerInvariant())",
        "pocket_bitstream_mtime_utc=$((Get-Item -LiteralPath $PocketBitstream).LastWriteTimeUtc.ToString('o'))",
        "sta_summary_sha256=$((Get-FileHash -LiteralPath $StaSummary -Algorithm SHA256).Hash.ToLowerInvariant())",
        "sta_summary_mtime_utc=$((Get-Item -LiteralPath $StaSummary).LastWriteTimeUtc.ToString('o'))"
    )
    [System.IO.File]::AppendAllLines(
        $FreshnessLog,
        [string[]]$ArtifactLines,
        [System.Text.UTF8Encoding]::new($false)
    )

    if (-not $SkipPackage) {
        Write-Host '=== Creating deterministic release package ==='
        Invoke-Python -Command $PythonCommand -Arguments @(
            (Join-Path $ScriptDirectory 'package_release.py'),
            '--output-dir',
            $OutputDirectory,
            '--evidence',
            $BuildLog
        )
    }

    Write-Host '=== Done ==='
    Write-Host "Bitstream: $PocketBitstream"
    Write-Host "Build log: $BuildLog"
}
finally {
    Pop-Location
}

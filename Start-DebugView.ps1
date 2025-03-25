<#
.SYNOPSIS
    Manages DebugView64: install, uninstall, or start with log tailing and filtering.
.DESCRIPTION
    This script can install or uninstall DebugView64, or start it with log tailing and optional filtering.
    Use -Install to install or -Uninstall to uninstall; these are mutually exclusive and cannot be combined with other parameters.
    Omit both to start DebugView with filtering options.
.PARAMETER Install
    Installs DebugView64 if not already installed. Cannot be used with other parameters.
.PARAMETER Uninstall
    Uninstalls DebugView64 if installed. Cannot be used with other parameters.
.PARAMETER Filter
    Filters log lines containing this string (e.g., "error"). Cannot be used with -Install or -Uninstall.
.PARAMETER ProcessName
    Filters logs from these process names (e.g., "w3wp"). Cannot be used with -Install or -Uninstall.
.PARAMETER FilterProfile
    Filters logs using a predefined profile (e.g., "IIS" for w3wp). Cannot be used with -Install or -Uninstall.
.EXAMPLE
    .\Start-DebugView.ps1 -Install
    Installs DebugView64.
.EXAMPLE
    .\Start-DebugView.ps1 -Uninstall
    Uninstalls DebugView64.
.EXAMPLE
    .\Start-DebugView.ps1 -Filter "error"
    Starts DebugView and shows only log lines containing "error".
.EXAMPLE
    .\Start-DebugView.ps1 -FilterProfile "IIS"
    Starts DebugView and shows logs from IIS processes (w3wp).
#>

param (
    [switch]$Install,
    [switch]$Uninstall,
    [string]$Filter = "",
    [string[]]$ProcessName = @(),
    [ValidateSet("IIS")][string]$FilterProfile = ""
)

## Global Constants ##
$global:ProfileTargets = @{
    "IIS" = @("w3wp")
}
$LogFileName = "debugview64.log"
$LogFilePath = Join-Path $PSScriptRoot $LogFileName
$InstallDir = "$env:APPDATA\DebugView"
$DebugView64Exe = "$InstallDir\dbgview64.exe"
$DebugView64Args = "/accepteula /t /g /o /f /l $LogFilePath"

## Functions ##
function Install-DebugView {
    param (
        [string]$installDir
    )
    if (Test-Path "$installDir\dbgview64.exe") {
        Write-Host "DebugView 64-bit is already installed at $installDir."
        exit 0
    }
    if (-not (Test-Path $installDir)) {
        New-Item -Path $installDir -ItemType Directory | Out-Null
    }
    $ZipUrl = "https://download.sysinternals.com/files/DebugView.zip"
    $ZipPath = "$env:TEMP\DebugView.zip"
    Write-Host "Downloading DebugView..."
    Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath
    Write-Host "Extracting DebugView to $installDir..."
    Expand-Archive -Path $ZipPath -DestinationPath $installDir -Force
    Remove-Item $ZipPath
    $envPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
    if ($envPath -notlike "*$installDir*") {
        Write-Host "Adding $installDir to the user's PATH..."
        $newPath = if ($envPath) { "$envPath;$installDir" } else { $installDir }
        [Environment]::SetEnvironmentVariable("Path", $newPath, [EnvironmentVariableTarget]::User)
    }
    Write-Host "DebugView 64-bit installed successfully to $installDir."
}

function Uninstall-DebugView {
    param(
        [string]$installDir
    )

    if (-not (Test-Path $installDir)) {
        Write-Host "DebugView is not installed at $installDir."
        exit 0
    }

    Write-Host "Removing DebugView from $installDir..."
    Remove-Item -Path $installDir -Recurse -Force

    $envPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
    if ($envPath -like "*$installDir*") {
        Write-Host "Removing $installDir from the user's PATH..."
        $newPath = ($envPath -split ';' | Where-Object { $_ -ne $installDir }) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $newPath, [EnvironmentVariableTarget]::User)
    }

    Remove-ResidualItems

    Write-Host "DebugView uninstalled successfully."
}

function Assert-IsAdmin {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
    if (-not $isAdmin) {
        Write-Warning "Please run this script as an administrator."
        exit 1
    }
}

function Assert-IsInstalled {
    if (-not (Test-Path $DebugView64Exe)) {
        Write-Warning "DebugView is not installed at '$DebugView64Exe'. Please install it first using -Install."
        exit 1
    }
}

function Stop-ExistingProcesses {
    $existing = Get-Process -Name "dbgview64" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Stopping existing DebugView instances."
        $existing | Stop-Process -Force
        Start-Sleep -Milliseconds 500
    }
}

function Remove-LogFiles {
    if (Test-Path $LogFilePath) {
        Write-Host "Removing log file."
        Remove-Item -Path $LogFilePath -Force
    }
}

function Remove-RegistrySettings {
    $regPath = "HKCU:\Software\Sysinternals\DbgView"
    if (Test-Path $regPath) {
        Write-Host "Clearing DebugView registry settings."
        Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-ResidualItems {
    Stop-ExistingProcesses
    Remove-LogFiles
    Remove-RegistrySettings
}

function Get-PidRegex {
    param (
        [string[]]$processNames
    )
    if (-not $processNames) { return "" }
    $pids = @()
    foreach ($name in $processNames) {
        $pids += (Get-Process -Name $name -ErrorAction SilentlyContinue).Id
    }
    if ($pids) {
        return ($pids | ForEach-Object { "\[$_\]" }) -join "|"
    }
    Write-Warning "No processes found for names: $($processNames -join ', '). PID filter will be ignored."
    return ""
}

function Start-DebugViewAndTail {
    # Write-Host "Starting DebugView in the background..."
    $debugProcess = Start-Process -FilePath $DebugView64Exe -ArgumentList $DebugView64Args -PassThru -NoNewWindow
    Start-Sleep -Milliseconds 500

    if (-not (Test-Path $LogFilePath)) {
        Write-Error "DebugView failed to create log file at '$LogFilePath'."
        if (-not $debugProcess.HasExited) { $debugProcess.Kill() }
        exit 1
    }

    # Write-Host "Starting detached log tailing..."

    $processNamesToFilter = @()
    if ($FilterProfile -and $global:ProfileTargets.ContainsKey($FilterProfile)) {
        $processNamesToFilter += $global:ProfileTargets[$FilterProfile]
    }
    if ($ProcessName) {
        $processNamesToFilter += $ProcessName
    }

    $pidRegex = Get-PidRegex -processNames $processNamesToFilter

    $tailCommand = "Get-Content -Path '$LogFilePath' -Wait"
    $filterConditions = @()
    if ($pidRegex) {
        $filterConditions += "`$_ -match '$pidRegex'"
    }
    if ($Filter) {
        $filterConditions += "`$_ -match '$Filter'"
    }
    if ($filterConditions) {
        $filterExpression = $filterConditions -join " -and "
        $tailCommand += " | Where-Object { $filterExpression }"
        Write-Host "Filtering log output:"
        if ($pidRegex) { Write-Host " - Process names: $($processNamesToFilter -join ', ')" }
        if ($Filter) { Write-Host " - String filter: $Filter" }
    }
    else {
        Write-Host "Displaying all log output..."
    }

    $tailProcess = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -Command `"$tailCommand`"" -PassThru -NoNewWindow

    try {
        $tailProcess.WaitForExit()
    }
    finally {
        Write-Host "Shutting down..."
        if (-not $tailProcess.HasExited) { $tailProcess.Kill(); Start-Sleep -Milliseconds 500 }
        if (-not $debugProcess.HasExited) { $debugProcess.Kill(); Start-Sleep -Milliseconds 500 }
        Remove-ResidualItems
    }
}

## Main Script ##
## Parameter Validations ##
if ($Install -and $Uninstall) {
    Write-Error "Cannot specify both -Install and -Uninstall."
    exit 1
}

$otherParamsUsed = ($Filter -ne "") -or ($ProcessName.Count -gt 0) -or ($FilterProfile -ne "")
if (($Install -or $Uninstall) -and $otherParamsUsed) {
    Write-Error "The -Install and -Uninstall cannot be used with other parameters."
    exit 1
}

if ($Install) {
    Install-DebugView -installDir $InstallDir
    exit 0
}
elseif ($Uninstall) {
    Uninstall-DebugView -installDir $InstallDir
    exit 0
}

Assert-IsAdmin
Assert-IsInstalled
Remove-ResidualItems
Start-DebugViewAndTail
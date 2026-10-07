# 把当前工作区的改动保存成一次本地提交。
# 用法：
#   .\save-local.cmd
#   .\save-local.cmd "绑定账号全选"

[CmdletBinding()]
param(
    [string]$Message = "local: save work"
)

$ErrorActionPreference = "Stop"

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$GitArgs,
        [switch]$AllowFail
    )
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & git @GitArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction
    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0 -and -not $AllowFail) {
        if ($text) { Write-Host $text }
        throw ("git {0} failed, exit {1}" -f ($GitArgs -join " "), $code)
    }
    return $text.Trim()
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    throw "Git is not installed. Install Git for Windows first: https://git-scm.com/download/win"
}

$root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
Set-Location $root

$inside = Invoke-Git -GitArgs @("-C", $root, "rev-parse", "--is-inside-work-tree") -AllowFail
if ($inside -ne "true") {
    throw "This folder is not a git repo. Run .\sync-upstream.cmd -Init first."
}

$status = Invoke-Git -GitArgs @("-C", $root, "status", "--porcelain")
if (-not $status) {
    Write-Host "No local changes to save. GitHub was not changed." -ForegroundColor Green
    return
}

Write-Host "Saving these files:"
Write-Host $status
Invoke-Git -GitArgs @("-C", $root, "add", "-A") | Out-Null
Invoke-Git -GitArgs @("-C", $root, "commit", "-m", $Message) | Out-Null
$head = Invoke-Git -GitArgs @("-C", $root, "log", "-1", "--oneline")
Write-Host ""
Write-Host ("Saved locally: " + $head) -ForegroundColor Green
Write-Host "GitHub was not changed. This command never uploads."

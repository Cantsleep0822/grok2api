# 把当前二开代码推到你自己 GitHub 上的 fork。
# 默认必须手动输入 YES 才会上传，避免误传到 GitHub。
# 用法：
#   .\push-to-fork.cmd
#   .\push-to-fork.cmd -GitHubUser 你的GitHub用户名

[CmdletBinding()]
param(
    [string]$GitHubUser = "",
    [string]$OriginUrl = "",
    [switch]$Force,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

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
    $script:LastGitExitCode = $code
    if ($code -ne 0 -and -not $AllowFail) {
        if ($text) { Write-Host $text }
        throw ("git {0} failed, exit {1}" -f ($GitArgs -join " "), $code)
    }
    return $text.Trim()
}

function Get-RepoRoot {
    if ($PSScriptRoot) {
        return (Split-Path -Parent $PSScriptRoot)
    }
    return (Get-Location).Path
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    throw "Git is not installed. Install Git for Windows first: https://git-scm.com/download/win"
}

$root = Get-RepoRoot
Set-Location $root
$inside = Invoke-Git -GitArgs @("-C", $root, "rev-parse", "--is-inside-work-tree") -AllowFail
if ($inside -ne "true") {
    throw "This folder is not a git repo. Run .\sync-upstream.cmd -Init first."
}

$status = Invoke-Git -GitArgs @("-C", $root, "status", "--porcelain")
if ($status) {
    throw "You have unsaved files. Run .\save-local.cmd first, then push."
}

$remotes = Invoke-Git -GitArgs @("-C", $root, "remote") -AllowFail
$hasOrigin = $remotes -match "(^|\n)origin(\r)?$"

if (-not $hasOrigin) {
    if (-not $OriginUrl) {
        if (-not $GitHubUser) {
            $GitHubUser = Read-Host "Enter your GitHub username (this is not saved into project files)"
        }
        $GitHubUser = $GitHubUser.Trim()
        if (-not $GitHubUser) {
            throw "GitHub username is empty. Upload cancelled."
        }
        $OriginUrl = "https://github.com/$GitHubUser/grok2api.git"
    }
    if ($OriginUrl -match "github\.com[:/]+chenyme/grok2api(\.git)?$") {
        throw "origin points at the original author repo. Upload cancelled. Use your own fork URL."
    }
    Write-Step "Add origin"
    Invoke-Git -GitArgs @("-C", $root, "remote", "add", "origin", $OriginUrl) | Out-Null
    Write-Host "origin = $OriginUrl"
} else {
    $OriginUrl = Invoke-Git -GitArgs @("-C", $root, "remote", "get-url", "origin")
    Write-Host "origin = $OriginUrl"
}

if ($OriginUrl -match "github\.com[:/]+chenyme/grok2api(\.git)?$") {
    throw "origin points at the original author repo. Upload cancelled."
}

$branch = Invoke-Git -GitArgs @("-C", $root, "rev-parse", "--abbrev-ref", "HEAD")
if ($branch -eq "HEAD" -or -not $branch) {
    $branch = "main"
    Invoke-Git -GitArgs @("-C", $root, "branch", "-M", "main") | Out-Null
}

Write-Step "Confirm upload"
Write-Host "This is the ONLY command that uploads to GitHub."
Write-Host ("Target: " + $OriginUrl)
Write-Host "This must be YOUR fork. It must not be chenyme/grok2api."
if (-not $Yes) {
    $answer = Read-Host "Type YES in capital letters to upload; anything else cancels"
    if ($answer -cne "YES") {
        Write-Host "Cancelled. Nothing was uploaded." -ForegroundColor Yellow
        return
    }
}
Write-Host "If a login window appears, sign in with your GitHub account."
Write-Host "If it asks for a password, paste a GitHub Personal Access Token, not your GitHub password."

$pushArgs = @("-C", $root, "push", "-u", "origin", $branch)
if ($Force) {
    Write-Host "Force push is on. This overwrites the same branch on your fork." -ForegroundColor Yellow
    $pushArgs = @("-C", $root, "push", "--force-with-lease", "-u", "origin", $branch)
}

$pushText = Invoke-Git -GitArgs $pushArgs -AllowFail
if ($pushText) { Write-Host $pushText }

if ($script:LastGitExitCode -ne 0) {
    Write-Host ""
    Write-Host "Push failed. Common causes:" -ForegroundColor Yellow
    Write-Host "  1. The fork does not exist yet. Open https://github.com/chenyme/grok2api and click Fork."
    Write-Host "  2. origin URL is wrong. Check it with: git remote -v"
    Write-Host "  3. GitHub login failed. Sign in when the browser window appears."
    Write-Host "  4. The fork already has different commits. After you confirm it is YOUR fork, run:"
    Write-Host "       .\push-to-fork.cmd -Force"
    throw "Push did not finish."
}

Write-Host ""
Write-Host ("Uploaded. Open: " + ($OriginUrl -replace "\.git$", "")) -ForegroundColor Green

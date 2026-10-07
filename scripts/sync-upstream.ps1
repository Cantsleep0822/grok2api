# 从原作者 chenyme/grok2api 拉取更新，并尽量保留本地二开修改。
# 用法：
#   .\sync-upstream.cmd
#   .\sync-upstream.cmd -Init
#   .\sync-upstream.cmd -Status
#   .\sync-upstream.cmd -SavePatch
#   .\sync-upstream.cmd -DryRun

[CmdletBinding()]
param(
    [switch]$Init,
    [switch]$Status,
    [switch]$SavePatch,
    [switch]$DryRun,
    [string]$UpstreamUrl = "https://github.com/chenyme/grok2api.git"
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Hint([string]$Message) {
    Write-Host $Message -ForegroundColor DarkGray
}

function Assert-Git {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        throw "未找到 git。请先安装 Git for Windows：https://git-scm.com/download/win"
    }
}

function Get-RepoRoot {
    if ($PSScriptRoot) {
        return (Split-Path -Parent $PSScriptRoot)
    }
    return (Get-Location).Path
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
        throw ("git {0} 失败，退出码 {1}" -f ($GitArgs -join " "), $code)
    }
    return $text.Trim()
}

function Test-GitRepo([string]$Root) {
    $inside = Invoke-Git -GitArgs @("-C", $Root, "rev-parse", "--is-inside-work-tree") -AllowFail
    return $inside -eq "true"
}

function Get-UpstreamBranch([string]$Root) {
    $heads = Invoke-Git -GitArgs @("-C", $Root, "ls-remote", "--symref", "upstream", "HEAD") -AllowFail
    if ($heads -match "refs/heads/([^\s]+)") {
        return $Matches[1]
    }
    foreach ($name in @("main", "master")) {
        $probe = Invoke-Git -GitArgs @("-C", $Root, "rev-parse", "--verify", "upstream/$name") -AllowFail
        if ($probe) { return $name }
    }
    throw "无法识别原作者默认分支，请检查网络或 upstream 远程。"
}

function Ensure-GitIdentity([string]$Root) {
    $name = Invoke-Git -GitArgs @("-C", $Root, "config", "--get", "user.name") -AllowFail
    $email = Invoke-Git -GitArgs @("-C", $Root, "config", "--get", "user.email") -AllowFail
    if (-not $name) {
        Invoke-Git -GitArgs @("-C", $Root, "config", "user.name", "local-fork") | Out-Null
        Write-Hint "已设置本仓库 git user.name = local-fork"
    }
    if (-not $email) {
        Invoke-Git -GitArgs @("-C", $Root, "config", "user.email", "local-fork@grok2api.local") | Out-Null
        Write-Hint "已设置本仓库 git user.email = local-fork@grok2api.local"
    }
    Invoke-Git -GitArgs @("-C", $Root, "config", "core.autocrlf", "false") | Out-Null
    Invoke-Git -GitArgs @("-C", $Root, "config", "core.eol", "lf") | Out-Null
}

function Save-LocalPatch {
    param(
        [string]$Root,
        [string]$UpstreamRef,
        [string]$Reason,
        [switch]$UpdateTrackedPatch
    )
    $backupDir = Join-Path $Root ".local-fork\backups"
    $patchDir = Join-Path $Root "patches"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    New-Item -ItemType Directory -Force -Path $patchDir | Out-Null

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupFile = Join-Path $backupDir ("local-" + $Reason + "-" + $stamp + ".patch")
    $latestFile = Join-Path $patchDir "local-customizations.patch"

    Invoke-Git -GitArgs @("-C", $Root, "add", "-A") | Out-Null
    $body = Invoke-Git -GitArgs @("-C", $Root, "diff", "--binary", "--cached", $UpstreamRef) -AllowFail
    Invoke-Git -GitArgs @("-C", $Root, "reset", "-q", "HEAD") | Out-Null

    if (-not $body) {
        Write-Hint "相对 $UpstreamRef 没有可导出的本地差异。"
        return $null
    }

    Set-Content -Path $backupFile -Value $body -Encoding UTF8
    Write-Host ("已备份本地改动：{0}" -f $backupFile)
    if ($UpdateTrackedPatch) {
        Set-Content -Path $latestFile -Value $body -Encoding UTF8
        Write-Host ("同时更新：{0}" -f $latestFile)
        return $latestFile
    }
    return $backupFile
}

function Initialize-Fork([string]$Root) {
    Write-Step "初始化二开仓库"
    Assert-Git
    Set-Location $Root

    if (-not (Test-GitRepo $Root)) {
        Invoke-Git -GitArgs @("-C", $Root, "init") | Out-Null
        Write-Host "已执行 git init"
    }
    Ensure-GitIdentity $Root

    $remotes = Invoke-Git -GitArgs @("-C", $Root, "remote") -AllowFail
    if ($remotes -notmatch "(^|\n)upstream(\r)?$") {
        Invoke-Git -GitArgs @("-C", $Root, "remote", "add", "upstream", $UpstreamUrl) | Out-Null
        Write-Host "已添加 upstream = $UpstreamUrl"
    } else {
        Invoke-Git -GitArgs @("-C", $Root, "remote", "set-url", "upstream", $UpstreamUrl) | Out-Null
        Write-Host "已更新 upstream = $UpstreamUrl"
    }

    Write-Step "提交当前本地代码快照"
    $status = Invoke-Git -GitArgs @("-C", $Root, "status", "--porcelain") -AllowFail
    $head = Invoke-Git -GitArgs @("-C", $Root, "rev-parse", "--verify", "HEAD") -AllowFail
    if (-not $head) {
        Invoke-Git -GitArgs @("-C", $Root, "add", "-A") | Out-Null
        Invoke-Git -GitArgs @("-C", $Root, "commit", "-m", "local: initial snapshot") | Out-Null
        Invoke-Git -GitArgs @("-C", $Root, "branch", "-M", "main") | Out-Null
        $head = Invoke-Git -GitArgs @("-C", $Root, "rev-parse", "HEAD")
    } elseif ($status) {
        Invoke-Git -GitArgs @("-C", $Root, "add", "-A") | Out-Null
        Invoke-Git -GitArgs @("-C", $Root, "commit", "-m", "local: snapshot before attaching upstream") | Out-Null
    }

    Write-Step "拉取原作者代码"
    $fetchText = Invoke-Git -GitArgs @("-C", $Root, "fetch", "upstream", "--tags", "--prune") -AllowFail
    $fetchOk = $script:LastGitExitCode -eq 0
    if (-not $fetchOk) {
        if ($fetchText) { Write-Host $fetchText }
        Write-Host "当前环境连不上 GitHub，本地快照已经保存。" -ForegroundColor Yellow
        Write-Host "网络可用后再次运行： .\sync-upstream.cmd -Init"
        Write-Host "如果 GitHub 被墙，可换成镜像，例如："
        Write-Host '  .\sync-upstream.cmd -Init -UpstreamUrl https://gitclone.com/github.com/chenyme/grok2api.git'
        return
    }

    $branch = Get-UpstreamBranch $Root
    $upstreamRef = "upstream/$branch"
    Write-Host ("原作者默认分支：$branch")

    Invoke-Git -GitArgs @("-C", $Root, "branch", "-M", "main") | Out-Null

    $tree = Invoke-Git -GitArgs @("-C", $Root, "rev-parse", "HEAD^{tree}")
    $upstreamCommit = Invoke-Git -GitArgs @("-C", $Root, "rev-parse", $upstreamRef)
    $parents = Invoke-Git -GitArgs @("-C", $Root, "rev-list", "--parents", "-n", "1", "HEAD")
    $alreadyGrafted = $parents -match $upstreamCommit
    if (-not $alreadyGrafted) {
        Write-Step "把当前文件接到原作者历史后面"
        $message = "local: retain fork customizations on upstream $branch"
        $newCommit = Invoke-Git -GitArgs @("-C", $Root, "commit-tree", $tree, "-p", $upstreamCommit, "-m", $message)
        Invoke-Git -GitArgs @("-C", $Root, "reset", "--hard", $newCommit) | Out-Null
        Write-Host "已将本地树接到 $upstreamRef 之上（工作区文件内容不变）"
    } else {
        Write-Hint "当前提交已经接在原作者历史上，跳过嫁接。"
    }

    Save-LocalPatch -Root $Root -UpstreamRef $upstreamRef -Reason "init" -UpdateTrackedPatch | Out-Null
    $leftover = Invoke-Git -GitArgs @("-C", $Root, "status", "--porcelain") -AllowFail
    if ($leftover) {
        Invoke-Git -GitArgs @("-C", $Root, "add", "-A") | Out-Null
        Invoke-Git -GitArgs @("-C", $Root, "commit", "-m", "local: store customization patch backup") | Out-Null
    }
    Write-Host ""
    Write-Host "初始化完成。以后原作者有更新，直接运行 .\sync-upstream.cmd" -ForegroundColor Green
}

function Show-Status([string]$Root) {
    Assert-Git
    if (-not (Test-GitRepo $Root)) {
        throw "还不是 git 仓库。请先运行：.\sync-upstream.cmd -Init"
    }
    Write-Step "检查原作者更新"
    Invoke-Git -GitArgs @("-C", $Root, "fetch", "upstream", "--tags", "--prune") | Out-Null
    $branch = Get-UpstreamBranch $Root
    $aheadBehind = Invoke-Git -GitArgs @("-C", $Root, "rev-list", "--left-right", "--count", "HEAD...upstream/$branch") -AllowFail
    $parts = @($aheadBehind -split "\s+")
    $localOnly = 0
    $behind = 0
    if ($parts.Count -ge 2) {
        $localOnly = [int]$parts[0]
        $behind = [int]$parts[1]
    }
    $head = Invoke-Git -GitArgs @("-C", $Root, "rev-parse", "--short", "HEAD")
    $upstreamHead = Invoke-Git -GitArgs @("-C", $Root, "rev-parse", "--short", "upstream/$branch")
    Write-Host ("当前提交：$head")
    Write-Host ("原作者 $branch：$upstreamHead")
    Write-Host ("你这边独有提交：$localOnly")
    Write-Host ("落后原作者提交：$behind")
    if ($behind -gt 0) {
        Write-Host "可以运行 .\sync-upstream.cmd 合并原作者更新。" -ForegroundColor Yellow
    } else {
        Write-Host "已经跟上原作者最新代码。" -ForegroundColor Green
    }
}

function Merge-Upstream([string]$Root, [bool]$Dry) {
    Assert-Git
    if (-not (Test-GitRepo $Root)) {
        throw "还不是 git 仓库。请先运行：.\sync-upstream.cmd -Init"
    }
    Ensure-GitIdentity $Root
    Set-Location $Root

    $status = Invoke-Git -GitArgs @("-C", $Root, "status", "--porcelain")
    if ($status) {
        throw 'Working tree is dirty. Commit first: git add -A; git commit -m "local: wip"'
    }

    Write-Step "拉取原作者代码"
    Invoke-Git -GitArgs @("-C", $Root, "fetch", "upstream", "--tags", "--prune") | Out-Null
    $branch = Get-UpstreamBranch $Root
    $upstreamRef = "upstream/$branch"

    Save-LocalPatch -Root $Root -UpstreamRef $upstreamRef -Reason "pre-merge" | Out-Null

    $behind = Invoke-Git -GitArgs @("-C", $Root, "rev-list", "--count", "HEAD..$upstreamRef")
    if ($behind -eq "0") {
        Write-Host "已经是原作者最新代码，无需合并。" -ForegroundColor Green
        return
    }

    Write-Host ("将合并原作者 $branch 的 $behind 个提交")
    if ($Dry) {
        Write-Host "DryRun：未执行 merge。" -ForegroundColor Yellow
        Invoke-Git -GitArgs @("-C", $Root, "log", "--oneline", "HEAD..$upstreamRef") | Write-Host
        return
    }

    Write-Step "合并原作者更新"
    $mergeOutput = Invoke-Git -GitArgs @("-C", $Root, "merge", "--no-edit", $upstreamRef) -AllowFail
    if ($mergeOutput) { Write-Host $mergeOutput }

    $unmerged = Invoke-Git -GitArgs @("-C", $Root, "diff", "--name-only", "--diff-filter=U") -AllowFail
    if ($unmerged) {
        Write-Host ""
        Write-Host "合并时出现冲突，这些文件需要你看一眼：" -ForegroundColor Yellow
        $unmerged.Split("`n") | Where-Object { $_ } | ForEach-Object { Write-Host ("  - " + $_) }
        Write-Host ""
        Write-Host "处理步骤："
        Write-Host "  1. Open the listed files and search for git conflict markers"
        Write-Host "  2. Keep both your changes and upstream code, then delete the markers"
        Write-Host "  3. git add ."
        Write-Host '  4. git commit -m "local: resolve upstream merge"'
        Write-Host "合并前备份在 .local-fork/backups/"
        throw "合并未完成，请先解决冲突。"
    }

    Save-LocalPatch -Root $Root -UpstreamRef $upstreamRef -Reason "post-merge" | Out-Null
    Write-Host ""
    Write-Host "合并完成。请重新构建后再启动：" -ForegroundColor Green
    Write-Host "  docker compose up -d --build"
}

$root = Get-RepoRoot
Set-Location $root

if ($Init) {
    Initialize-Fork $root
    return
}
if ($Status) {
    Show-Status $root
    return
}
if ($SavePatch) {
    Assert-Git
    if (-not (Test-GitRepo $root)) { throw "还不是 git 仓库。请先运行：.\sync-upstream.cmd -Init" }
    Invoke-Git -GitArgs @("-C", $root, "fetch", "upstream", "--tags", "--prune") | Out-Null
    $branch = Get-UpstreamBranch $root
    Save-LocalPatch -Root $root -UpstreamRef "upstream/$branch" -Reason "manual" -UpdateTrackedPatch | Out-Null
    return
}

Merge-Upstream -Root $root -Dry $DryRun

<#
.SYNOPSIS
    Prunes remotes and deletes local branches whose upstream was removed on the remote.

.DESCRIPTION
    Scans each git repository under the configured root folder, runs fetch --prune, then
    deletes local branches whose upstream is [gone] or that have no upstream set.
    Skips protected branch names (main, master, develop).

    Pass -Repo to clean one repository by folder name under the root (e.g. FilePipe).

.USAGE
    # Preview All git repos under D:\git
    .\git_branch_cleanup.ps1 -dryRun

    # Run on one repo by folder name
    .\git_branch_cleanup.ps1 FilePipe

    # Preview one repo
    .\git_branch_cleanup.ps1 ObtainX -dryRun
#>

param(
    [string]$Repo,
    [switch]$dryRun
)

$GitRootPath = "D:\git"
$ProtectedBranches = @("main", "master", "develop")

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "git is not available on PATH."
    exit 1
}

if (-not (Test-Path $GitRootPath)) {
    Write-Error "Root path not found: $GitRootPath"
    exit 1
}

if ($Repo) {
    $repoPath = Join-Path $GitRootPath $Repo
    if (-not (Test-Path $repoPath)) {
        Write-Error "Repo not found: $repoPath"
        exit 1
    }
    if (-not (Test-Path (Join-Path $repoPath ".git"))) {
        Write-Error "Not a git repository: $repoPath"
        exit 1
    }
    $repoPaths = @($repoPath)
} else {
    $repoPaths = @(
        Get-ChildItem -Path $GitRootPath -Directory |
            Where-Object { Test-Path (Join-Path $_.FullName ".git") } |
            ForEach-Object { $_.FullName }
    )
}

$reposProcessed = 0
$reposSkipped = 0
$branchesDeleted = 0
$branchesFailed = 0

foreach ($repoPath in $repoPaths) {
    Write-Host "`n=== Cleaning repo: $repoPath ===" -ForegroundColor Cyan

    git -C $repoPath fetch --prune 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  fetch failed; skipping repo." -ForegroundColor Red
        $reposSkipped++
        continue
    }

    $currentBranch = git -C $repoPath branch --show-current
    $currentBranchIsGone = $false
    $staleBranches = @()
    git -C $repoPath for-each-ref --format="%(refname:short)|%(upstream:short)|%(upstream:track)" refs/heads/ | ForEach-Object {
        if ($_ -match '^([^|]+)\|([^|]*)\|(.*)$') {
            $branchName = $matches[1]
            $upstream = $matches[2]
            $track = $matches[3]
            if ($branchName -in $ProtectedBranches) { return }
            if ($branchName -eq $currentBranch) {
                if ($track -eq "[gone]") { $currentBranchIsGone = $true }
                return
            }
            if ($track -eq "[gone]") {
                $staleBranches += [PSCustomObject]@{ Name = $branchName; Tag = "gone" }
            } elseif ($upstream -eq "") {
                $staleBranches += [PSCustomObject]@{ Name = $branchName; Tag = "local" }
            }
        }
    }

    if ($currentBranchIsGone) {
        Write-Host "  Current branch '$currentBranch' is stale; switch away before deleting." -ForegroundColor Yellow
    }

    if ($staleBranches.Count -eq 0) {
        Write-Host "  No stale branches found." -ForegroundColor DarkGray
    } else {
        Write-Host "  Stale branches ($($staleBranches.Count)):" -ForegroundColor Yellow
        foreach ($branch in $staleBranches) {
            Write-Host "    - $($branch.Name)  [$($branch.Tag)]"
        }

        if (-not $dryRun) {
            $confirm = Read-Host "  Delete these branches? (y/N)"
            if ($confirm -ne "y" -and $confirm -ne "Y") {
                Write-Host "  Skipped." -ForegroundColor DarkGray
                $reposProcessed++
                continue
            }

            foreach ($branch in $staleBranches) {
                git -C $repoPath branch -D $branch.Name 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $branchesDeleted++
                } else {
                    Write-Host "      delete failed: $($branch.Name)" -ForegroundColor Red
                    $branchesFailed++
                }
            }
        }
    }

    $reposProcessed++
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Repos processed: $reposProcessed"
Write-Host "  Repos skipped:   $reposSkipped"
if ($dryRun) {
    Write-Host "  Dry run only; no branches deleted." -ForegroundColor Yellow
} else {
    Write-Host "  Branches deleted: $branchesDeleted"
    if ($branchesFailed -gt 0) {
        Write-Host "  Branches failed:  $branchesFailed" -ForegroundColor Red
    }
}

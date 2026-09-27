$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
try {
    & (Join-Path $PSScriptRoot 'ArenaControl.ps1')
} catch {
    Write-Host "`n未完成：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '请保留这个窗口，不要删除备份或尝试手工导入 SQL。'
    exit 1
}

<#
.SYNOPSIS
    一键重建 assets/models 下的全部 GLB 素材。

.DESCRIPTION
    用无头 Blender 跑 tools/blender/build_all.py。--factory-startup 保证
    不受本机 Blender 偏好设置影响，任何机器上跑出来的模型都一致。

.EXAMPLE
    ./tools/build_assets.ps1                 # 全量重建
    ./tools/build_assets.ps1 tanks walls     # 只重建坦克与墙体
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Modules = @()
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'tools/blender/build_all.py'

# Blender 路径：优先环境变量 BLENDER_EXE，其次本机安装位置，最后 PATH
$blender = $env:BLENDER_EXE
if (-not $blender) { $blender = 'D:\DevSoftware\blender\blender.exe' }
if (-not (Test-Path $blender)) {
    $cmd = Get-Command blender -ErrorAction SilentlyContinue
    if ($cmd) { $blender = $cmd.Source }
}
if (-not (Test-Path $blender)) {
    throw "找不到 blender.exe。请设置环境变量 BLENDER_EXE 指向可执行文件。"
}

Write-Host "Blender : $blender"
Write-Host "脚本    : $script"
Write-Host "模块    : $(if ($Modules.Count) { $Modules -join ', ' } else { '全部' })"
Write-Host ''

$blenderArgs = @('--background', '--factory-startup', '--python', $script)
if ($Modules.Count) { $blenderArgs += '--'; $blenderArgs += $Modules }

& $blender @blenderArgs
$code = $LASTEXITCODE
if ($code -ne 0) {
    Write-Host ''
    Write-Error "资源构建失败（退出码 $code）。"
    exit $code
}

Write-Host ''
Write-Host '构建完成。产物：' -ForegroundColor Green
Get-ChildItem (Join-Path $root 'assets/models/*.glb') |
    Sort-Object Name |
    Format-Table Name, @{ Name = 'KB'; Expression = { [math]::Round($_.Length / 1KB, 1) } } -AutoSize

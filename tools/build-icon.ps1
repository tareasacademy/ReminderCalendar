# Draws the app icon and writes icon.ico (PNG-compressed frames, 16-256 px).
# Usage: powershell -File tools\build-icon.ps1 [-PreviewDir <folder>]
param([string]$PreviewDir)

Add-Type -AssemblyName System.Drawing

$Out   = Join-Path (Split-Path $PSScriptRoot) 'icon.ico'
$Sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256

function New-RoundRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $d = 2 * $r
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $p
}

function New-IconImage([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)

    $violet = [System.Drawing.Color]::FromArgb(124, 92, 255)
    $deep   = [System.Drawing.Color]::FromArgb(96, 64, 232)
    $white  = [System.Drawing.Color]::White

    # tile
    $m = [math]::Max(0.5, $s * 0.03)
    $tile = New-RoundRect $m $m ($s - 2 * $m) ($s - 2 * $m) ($s * 0.23)
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF(0, 0)), (New-Object System.Drawing.PointF($s, $s)),
        [System.Drawing.Color]::FromArgb(147, 120, 255), $deep)
    $g.FillPath($grad, $tile)

    # calendar page
    $cx = $s * 0.20; $cy = $s * 0.27; $cw = $s * 0.60; $ch = $s * 0.55
    $page = New-RoundRect $cx $cy $cw $ch ($s * 0.09)
    $g.FillPath((New-Object System.Drawing.SolidBrush $white), $page)
    # header band
    $g.SetClip($page)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(222, 214, 255))), $cx, $cy, $cw, $ch * 0.27)
    $g.ResetClip()
    # binder rings
    $rw = [math]::Max(1.5, $s * 0.075); $rh = $s * 0.15
    foreach ($fx in 0.36, 0.64) {
        $ring = New-RoundRect ($s * $fx - $rw / 2) ($s * 0.19) $rw $rh ($rw / 2)
        $g.FillPath((New-Object System.Drawing.SolidBrush $white), $ring)
        if ($s -ge 32) { $g.DrawPath((New-Object System.Drawing.Pen($deep, [single]($s * 0.018))), $ring) }
    }

    # bell in the page body
    $vb = New-Object System.Drawing.SolidBrush $violet
    $bx = $s * 0.5; $top = $cy + $ch * 0.36; $bot = $cy + $ch * 0.80
    $bw = $s * ($(if ($s -le 20) { 0.30 } else { 0.26 }))
    $bh = $bot - $top
    $bell = New-Object System.Drawing.Drawing2D.GraphicsPath
    $bell.AddBezier($bx - $bw * 0.62, $bot, $bx - $bw * 0.42, $bot - $bh * 0.25, $bx - $bw * 0.52, $top, $bx, $top)
    $bell.AddBezier($bx, $top, $bx + $bw * 0.52, $top, $bx + $bw * 0.42, $bot - $bh * 0.25, $bx + $bw * 0.62, $bot)
    $bell.CloseFigure()
    $g.FillPath($vb, $bell)
    $g.FillPath($vb, (New-RoundRect ($bx - $bw * 0.70) ($bot - $bh * 0.06) ($bw * 1.40) ($bh * 0.16) ($bh * 0.08)))
    $cr = $bh * 0.17
    $g.FillEllipse($vb, $bx - $cr, $bot + $bh * 0.06, 2 * $cr, 2 * $cr)

    $g.Dispose()
    $bmp
}

$frames = foreach ($s in $Sizes) {
    $img = New-IconImage $s
    $ms = New-Object System.IO.MemoryStream
    $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    if ($PreviewDir) { New-Item -ItemType Directory -Force $PreviewDir | Out-Null; $img.Save((Join-Path $PreviewDir "icon-$s.png")) }
    $img.Dispose()
    [pscustomobject]@{ Size = $s; Bytes = $ms.ToArray() }
}

# ICO container: ICONDIR, one ICONDIRENTRY per frame, then the PNG data.
$fs = [IO.File]::Create($Out)
$w = New-Object System.IO.BinaryWriter $fs
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
    $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$f.Bytes.Length); $w.Write([uint32]$offset)
    $offset += $f.Bytes.Length
}
foreach ($f in $frames) { $w.Write($f.Bytes) }
$w.Close()
Write-Host "Wrote $Out"

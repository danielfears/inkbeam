[CmdletBinding()]
param(
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path `
        $PSScriptRoot `
        '..\src\InkBeam\Assets\InkBeam.ico'
}

function New-RoundedRectanglePath {
    param(
        [Parameter(Mandatory)]
        [System.Drawing.RectangleF]$Rectangle,
        [Parameter(Mandatory)]
        [float]$Radius
    )

    $diameter = $Radius * 2
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddArc($Rectangle.X, $Rectangle.Y, $diameter, $diameter, 180, 90)
    $path.AddArc(
        $Rectangle.Right - $diameter,
        $Rectangle.Y,
        $diameter,
        $diameter,
        270,
        90
    )
    $path.AddArc(
        $Rectangle.Right - $diameter,
        $Rectangle.Bottom - $diameter,
        $diameter,
        $diameter,
        0,
        90
    )
    $path.AddArc(
        $Rectangle.X,
        $Rectangle.Bottom - $diameter,
        $diameter,
        $diameter,
        90,
        90
    )
    $path.CloseFigure()
    return $path
}

function New-IconPng {
    param([Parameter(Mandatory)][int]$Size)

    $bitmap = [System.Drawing.Bitmap]::new(
        $Size,
        $Size,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.SmoothingMode =
            [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.PixelOffsetMode =
            [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.Clear([System.Drawing.Color]::Transparent)

        $inset = [single]($Size * 0.04)
        $bounds = [System.Drawing.RectangleF]::new(
            $inset,
            $inset,
            [single]($Size - (2 * $inset)),
            [single]($Size - (2 * $inset))
        )
        $shape = New-RoundedRectanglePath `
            -Rectangle $bounds `
            -Radius ([single]($Size * 0.19))
        try {
            $background = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
                $bounds,
                [System.Drawing.ColorTranslator]::FromHtml('#080B14'),
                [System.Drawing.ColorTranslator]::FromHtml('#19122D'),
                45
            )
            try {
                $graphics.FillPath($background, $shape)
            }
            finally {
                $background.Dispose()
            }

            $border = [System.Drawing.Pen]::new(
                [System.Drawing.ColorTranslator]::FromHtml('#7557D6'),
                [single]([Math]::Max(1, $Size * 0.025))
            )
            try {
                $graphics.DrawPath($border, $shape)
            }
            finally {
                $border.Dispose()
            }
        }
        finally {
            $shape.Dispose()
        }

        $beamPen = [System.Drawing.Pen]::new(
            [System.Drawing.ColorTranslator]::FromHtml('#A78BFA'),
            [single]([Math]::Max(2, $Size * 0.065))
        )
        $beamPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $beamPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        try {
            $graphics.DrawArc(
                $beamPen,
                [single]($Size * 0.18),
                [single]($Size * 0.22),
                [single]($Size * 0.64),
                [single]($Size * 0.64),
                210,
                120
            )
            $graphics.DrawArc(
                $beamPen,
                [single]($Size * 0.29),
                [single]($Size * 0.33),
                [single]($Size * 0.42),
                [single]($Size * 0.42),
                210,
                120
            )
        }
        finally {
            $beamPen.Dispose()
        }

        $inkBrush = [System.Drawing.SolidBrush]::new(
            [System.Drawing.ColorTranslator]::FromHtml('#F8F7FF')
        )
        try {
            $graphics.FillEllipse(
                $inkBrush,
                [single]($Size * 0.43),
                [single]($Size * 0.43),
                [single]($Size * 0.14),
                [single]($Size * 0.14)
            )
            $graphics.FillPolygon(
                $inkBrush,
                [System.Drawing.PointF[]]@(
                    [System.Drawing.PointF]::new(
                        [single]($Size * 0.50),
                        [single]($Size * 0.49)
                    ),
                    [System.Drawing.PointF]::new(
                        [single]($Size * 0.67),
                        [single]($Size * 0.78)
                    ),
                    [System.Drawing.PointF]::new(
                        [single]($Size * 0.54),
                        [single]($Size * 0.66)
                    )
                )
            )
        }
        finally {
            $inkBrush.Dispose()
        }

        $stream = [System.IO.MemoryStream]::new()
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return $stream.ToArray()
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$images = @(
    foreach ($size in $sizes) {
        [pscustomobject]@{
            Size = $size
            Bytes = New-IconPng -Size $size
        }
    }
)

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $resolvedOutput
[void][System.IO.Directory]::CreateDirectory($outputDirectory)

$stream = [System.IO.File]::Open(
    $resolvedOutput,
    [System.IO.FileMode]::Create,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::None
)
$writer = [System.IO.BinaryWriter]::new($stream)
try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$images.Count)

    $dataOffset = 6 + (16 * $images.Count)
    foreach ($image in $images) {
        $dimension = if ($image.Size -eq 256) { 0 } else { $image.Size }
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$image.Bytes.Length)
        $writer.Write([uint32]$dataOffset)
        $dataOffset += $image.Bytes.Length
    }

    foreach ($image in $images) {
        $writer.Write([byte[]]$image.Bytes)
    }
}
finally {
    $writer.Dispose()
    $stream.Dispose()
}

Write-Host "Generated $resolvedOutput"

#Requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase
$drawing=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $repo 'assets\Update-Control.icon.xaml')))
function Render-Icon([int]$Size){
    $visual=New-Object Windows.Media.DrawingVisual
    $context=$visual.RenderOpen()
    try{$context.DrawImage($drawing,[Windows.Rect]::new(0,0,$Size,$Size))}finally{$context.Close()}
    $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap($Size,$Size,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=New-Object IO.MemoryStream
    try{$encoder.Save($stream);return ,$stream.ToArray()}finally{$stream.Dispose()}
}
$sizes=@(16,24,32,48,64,128,256)
$images=@($sizes | ForEach-Object {,[byte[]](Render-Icon $_)})
$writer=New-Object IO.BinaryWriter([IO.File]::Create((Join-Path $repo 'Update-Control.ico')))
try{
    $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$sizes.Count)
    $offset=6+16*$sizes.Count
    for($i=0;$i -lt $sizes.Count;$i++){
        $dimension=if($sizes[$i] -eq 256){0}else{$sizes[$i]}
        $writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0)
        $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$images[$i].Length);$writer.Write([uint32]$offset)
        $offset+=$images[$i].Length
    }
    foreach($bytes in $images){$writer.Write([byte[]]$bytes)}
}finally{$writer.Dispose()}
[IO.File]::WriteAllBytes((Join-Path $repo 'assets\Update-Control.png'),(Render-Icon 1024))
Write-Host 'Built Update-Control.ico (16 through 256 px) and assets/Update-Control.png (1024 px).'

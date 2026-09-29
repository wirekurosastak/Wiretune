$ErrorActionPreference = 'Stop'
$dir = 'c:\Users\wirekurosastak\Documents\GitHub\Wiretune'

Remove-Item -Path $dir\Wiretune.Core\Services\ILibraryService.cs -Force -ErrorAction SilentlyContinue
Remove-Item -Path $dir\Wiretune.Core\Repositories\ILibraryRepository.cs -Force -ErrorAction SilentlyContinue
Remove-Item -Path $dir\Wiretune.Core\Services\IMetadataScanner.cs -Force -ErrorAction SilentlyContinue
Remove-Item -Path $dir\Wiretune.Core\Audio\IAudioEngine.cs -Force -ErrorAction SilentlyContinue

Get-ChildItem -Path $dir -Recurse -Filter *.cs | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    $newContent = $content -replace ':\s*ILibraryService', ''
    $newContent = $newContent -replace ':\s*ILibraryRepository', ''
    $newContent = $newContent -replace ':\s*IMetadataScanner', ''
    $newContent = $newContent -replace ':\s*IAudioEngine', ''
    $newContent = $newContent -replace '\bILibraryService\b', 'LibraryService'
    $newContent = $newContent -replace '\bILibraryRepository\b', 'LibraryRepository'
    $newContent = $newContent -replace '\bIMetadataScanner\b', 'MetadataScanner'
    $newContent = $newContent -replace '\bIAudioEngine\b', 'WiretuneAudioEngine'
    
    if ($content -ne $newContent) {
        Set-Content -Path $_.FullName -Value $newContent -Encoding UTF8
        Write-Host "Updated $($_.FullName)"
    }
}

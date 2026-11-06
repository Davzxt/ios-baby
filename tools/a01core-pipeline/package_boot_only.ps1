param(
    [switch]$SkipDownload,
    [switch]$NativeMetalSelfTest,
    [switch]$NativeMetalLean,
    [string]$XnuArtifact = '13271625441',
    [string]$VulkanArtifact = '13280073766',
    [string]$PackageTag = 'DA22EDA'
)
$ErrorActionPreference = 'Stop'
if ($NativeMetalLean -and -not $NativeMetalSelfTest) { throw 'NativeMetalLean requires NativeMetalSelfTest' }
if (-not $SkipDownload) {
$env:GIT_TERMINAL_PROMPT = '0'
$credential = "protocol=https`nhost=github.com`n`n" | git credential fill
if ($LASTEXITCODE -ne 0) { throw 'GitHub credential unavailable' }
$password = $credential | Where-Object { $_ -like 'password=*' } | Select-Object -First 1
if (-not $password) { throw 'GitHub credential unavailable' }
$headers = @{ Authorization = 'Bearer ' + $password.Substring(9); 'User-Agent' = 'Codex' }
$dir = Join-Path $PSScriptRoot '../../a01-package-work'
New-Item -ItemType Directory -Force $dir | Out-Null
$artifacts = @{ metal='13281959359'; vulkan=$VulkanArtifact; gl='13217064917'; xnu=$XnuArtifact; shim='13096108025' }
foreach ($name in $artifacts.Keys) {
    $zip = Join-Path $dir "$name.zip"
    Invoke-WebRequest -Headers $headers -Uri "https://api.github.com/repos/Davzxt/ios-baby/actions/artifacts/$($artifacts[$name])/zip" -OutFile $zip
    Expand-Archive -Force $zip (Join-Path $dir $name)
    Write-Output "Downloaded $name"
}
} else {
    $dir = Join-Path $PSScriptRoot '../../a01-package-work'
}

function Run-Python {
    & python @args
    if ($LASTEXITCODE -ne 0) { throw "Python command failed: $($args[0])" }
}
$dir = (Resolve-Path $dir).Path
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Set-Location $root
$kernelDir = if ($NativeMetalSelfTest) { 'xnu-native' } else { 'xnu' }
$checksums = Get-Content (Join-Path $dir "$kernelDir/SHA256SUMS")
$kernelHash = ($checksums | Where-Object { $_ -match 'kernel\.development\.a01core' } | Select-Object -First 1) -split '\s+'
$kernel = Join-Path $dir "$kernelDir/kernel.development.a01core"
if (-not $kernelHash -or (Get-FileHash -Algorithm SHA256 $kernel).Hash -ne $kernelHash[0]) { throw 'Kernel checksum mismatch' }
$drop = Join-Path $dir 'a01drop.pkg'
$items = @("/System/Library/Extensions/A01Metal.bundle/A01Metal=$dir/metal/A01Metal.bundle/A01Metal", "/System/Library/Extensions/A01Metal.bundle/Info.plist=$dir/metal/A01Metal.bundle/Info.plist", "lib/libvulkan_powervr.dylib=$dir/vulkan/libvulkan_powervr.dylib", "lib/libdrm.2.dylib=$dir/vulkan/libdrm.2.dylib", "lib/libA01Metal.dylib=$dir/metal/libA01Metal.dylib", "lib/libOSMesa.8.dylib=$dir/gl/lib/libOSMesa.8.dylib", "lib/libvulkan.1.dylib=$dir/gl/lib/libvulkan.1.dylib", "lib/libheroeagl.dylib=$dir/gl/lib/libheroeagl.dylib", "/private/var/herolte/autorun=$dir/metal/a01metal-test")
if ($NativeMetalLean) {
    # Only for a root on which the preceding complete GPU package installed
    # its libraries successfully. The drop does not remove persisted files.
    $items = @()
}
if ($NativeMetalSelfTest) {
    $bundle = Join-Path $dir 'native-metal-trial/A01NativeMetal.bundle'
    if (-not (Test-Path (Join-Path $bundle 'A01NativeMetal'))) { throw 'NativeMetal plugin missing' }
    foreach ($file in Get-ChildItem -LiteralPath $bundle -File -Recurse) {
        $relative = [System.IO.Path]::GetRelativePath($bundle, $file.FullName).Replace('\', '/')
        $items += "/System/Library/Extensions/A01NativeMetal.bundle/$relative=$($file.FullName)"
    }
    $marker = Join-Path $dir 'native-metal-selftest.marker'
    [System.IO.File]::WriteAllText($marker, '1')
    $items += "/System/Library/Extensions/A01NativeMetal.selftest=$marker"
}
Run-Python tools/a01core-drop.py $drop @items
$adt = Join-Path $dir 'a01core.adt'
$payload = Join-Path $dir 'payload.bin'
$bootDir = Join-Path $dir $PackageTag
New-Item -ItemType Directory -Force $bootDir | Out-Null
$boot = Join-Path $bootDir 'boot.img'
$output = Join-Path $dir "AP_IOS16_BOOT_GPU_DIAG_3CPU_$PackageTag.tar.md5"
$cmdline = 'cpus=3 keepsyms=1 -noprogress rd=emmcroot0 emmcroot=userdata emmcwrite=1 rootrw=1 cs_enforcement_disable=1 unentitled_ios_sim_launch=1 ignition_level=1 launchd_unsecure_cache=1 wdt=-1 -wdt_no_pmu wdt_test=no_user_checkin a5fb_keep_on=1 a01keys_home=1 sweetfb_lw=828 sweetfb_lh=1792 a01quiet=1 a01gpu=2 serial=3 herogl=1 a01gl=zink'
if ($NativeMetalSelfTest) { $cmdline += ' a01metal=2' }
Run-Python tools/mkadt_a01core.py $adt
Run-Python tools/mkpayload.py $kernel $adt $payload --blob 'TouchFirmware=C:/A01CORE_RECOVERY/PORT_TEST/m3/td4150_a01core.img' --blob 'TouchFirmwareNVT=C:/Users/Admin/Desktop/ios_a03_core/a01core-kernel/firmware/tsp_novatek/nt36525_a01core_tp.bin' --blob 'GPUFirmware=C:/A01CORE_RECOVERY/VENDOR_EXTRACT/vendor/firmware/rgx.fw' --blob "A01Drop=$drop" --cmdline $cmdline
Run-Python tools/a01core-pack-boot.py pack C:/A01CORE_RECOVERY/PORT_TEST/stock/boot.img (Join-Path $dir 'shim/a01core.Image') $boot --append $payload
Run-Python tools/a01core-odin-pack.py tar $output $boot
Write-Output "Package: $output"

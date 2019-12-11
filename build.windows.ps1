$ErrorActionPreference = 'Stop'

$env:GIT_REDIRECT_STDERR = '2>&1'

$VERSION_FILE = Join-Path (Resolve-Path ".").Path "VERSION"
Get-Content $VERSION_FILE | Foreach-Object{
  $var = $_.Split('=')
  New-Variable -Name $var[0] -Value $var[1]
}

$PACKAGE_NAME = "windows"
$SOURCE_DIR = Join-Path (Resolve-Path ".").Path "_source\$PACKAGE_NAME"
$BUILD_DIR = Join-Path (Resolve-Path ".").Path "_build\$PACKAGE_NAME"
$PACKAGE_DIR = Join-Path (Resolve-Path ".").Path "_package\$PACKAGE_NAME"

if (!(Test-Path $BUILD_DIR)) {
  mkdir $BUILD_DIR
}

if (!(Test-Path $BUILD_DIR\vswhere.exe)) {
  Invoke-WebRequest -Uri "https://github.com/microsoft/vswhere/releases/download/2.8.4/vswhere.exe" -OutFile $BUILD_DIR\vswhere.exe
}

# vsdevcmd.bat の設定を入れる
# https://github.com/microsoft/vswhere/wiki/Find-VC
Push-Location $BUILD_DIR
  $path = .\vswhere.exe -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
Pop-Location
if ($path) {
  $path = Join-Path $path 'Common7\Tools\vsdevcmd.bat'
  if (Test-Path $path) {
    cmd /s /c """$path"" $args && set" | Where-Object { $_ -match '(\w+)=(.*)' } | ForEach-Object {
      $null = New-Item -force -path "Env:\$($Matches[1])" -value $Matches[2]
    }
  }
}

# $SOURCE_DIR の下に置きたいが、webrtc のパスが長すぎると動かない問題と、
# GitHub Actions の D:\ の容量が少なくてビルド出来ない問題があるので
# このパスにソースを配置する
$WEBRTC_DIR = "C:\webrtc"

# WebRTC ビルドに必要な環境変数の設定
$Env:GYP_MSVS_VERSION = "2019"
$Env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
$Env:PYTHONIOENCODING = "utf-8"

if (!(Test-Path $SOURCE_DIR)) {
  New-Item -ItemType Directory -Path $SOURCE_DIR
}

# depot_tools
if (!(Test-Path $SOURCE_DIR\depot_tools)) {
  Push-Location $SOURCE_DIR
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
  Pop-Location
} else {
  Push-Location $SOURCE_DIR\depot_tools
    git fetch
    git checkout -f origin/HEAD
  Pop-Location
}

$Env:PATH = "$SOURCE_DIR\depot_tools;$Env:PATH"
# Choco へのパスを削除
$Env:PATH = $Env:Path.Replace("C:\ProgramData\Chocolatey\bin;", "");

# WebRTC のソース取得
if (!(Test-Path $WEBRTC_DIR)) {
  mkdir $WEBRTC_DIR
}
if (!(Test-Path $WEBRTC_DIR\src)) {
  Push-Location $WEBRTC_DIR
    gclient
    fetch webrtc
  Pop-Location
} else {
  Push-Location $WEBRTC_DIR\src
    git clean -xdf
    git reset --hard
    Push-Location build
      git reset --hard
    Pop-Location
    Push-Location third_party
      git reset --hard
    Pop-Location
    git fetch
  Pop-Location
}

Get-PSDrive

Push-Location $WEBRTC_DIR\src
  git checkout -f "$WEBRTC_COMMIT"
  git clean -xdf
  gclient sync

  # WebRTC ビルド
  gn gen $BUILD_DIR\debug --args='is_debug=true rtc_include_tests=false rtc_use_h264=false is_component_build=false use_rtti=true use_custom_libcxx=false'
  ninja -C "$BUILD_DIR\debug"

  gn gen $BUILD_DIR\release --args='is_debug=false rtc_include_tests=false rtc_use_h264=false is_component_build=false use_rtti=true use_custom_libcxx=false'
  ninja -C "$BUILD_DIR\release"
Pop-Location

foreach ($build in @("debug", "release")) {
  ninja -C "$BUILD_DIR\$build" audio_device_module_from_input_and_output

  # このままだと webrtc.lib に含まれないファイルがあるので、いくつか追加する
  Push-Location $BUILD_DIR\$build\obj
    lib.exe `
      /out:$BUILD_DIR\$build\webrtc.lib webrtc.lib `
      api\task_queue\default_task_queue_factory\default_task_queue_factory_win.obj `
      rtc_base\rtc_task_queue_win\task_queue_win.obj `
      modules\audio_device\audio_device_module_from_input_and_output\audio_device_factory.obj `
      modules\audio_device\audio_device_module_from_input_and_output\audio_device_module_win.obj `
      modules\audio_device\audio_device_module_from_input_and_output\core_audio_base_win.obj `
      modules\audio_device\audio_device_module_from_input_and_output\core_audio_input_win.obj `
      modules\audio_device\audio_device_module_from_input_and_output\core_audio_output_win.obj `
      modules\audio_device\windows_core_audio_utility\core_audio_utility_win.obj `
      modules\audio_device\audio_device_name\audio_device_name.obj
  Pop-Location
  Move-Item $BUILD_DIR\$build\webrtc.lib $BUILD_DIR\$build\obj\webrtc.lib -Force
}

# WebRTC のヘッダーをパッケージに含める
if (Test-Path $BUILD_DIR\package) {
  Remove-Item -Force -Recurse -Path $BUILD_DIR\package
}
mkdir $BUILD_DIR\package
mkdir $BUILD_DIR\package\webrtc
robocopy "$WEBRTC_DIR\src" "$BUILD_DIR\package\webrtc\include" *.h *.hpp /S

# webrtc.lib をパッケージに含める
foreach ($build in @("debug", "release")) {
  mkdir $BUILD_DIR\package\webrtc\$build
  Copy-Item $BUILD_DIR\$build\obj\webrtc.lib $BUILD_DIR\package\webrtc\$build\
}

# WebRTC の各種バージョンをパッケージに含める
New-Item -Type File $BUILD_DIR\package\webrtc\VERSIONS
Push-Location $WEBRTC_DIR\src
  Write-Output "WEBRTC_SRC_COMMIT=$(git rev-parse HEAD)" >> $BUILD_DIR\package\webrtc\VERSIONS
Pop-Location
Push-Location $WEBRTC_DIR\src\build
  Write-Output "WEBRTC_SRC_BUILD_COMMIT=$(git rev-parse HEAD)" >> $BUILD_DIR\package\webrtc\VERSIONS
Pop-Location
Push-Location $WEBRTC_DIR\src\buildtools
  Write-Output "WEBRTC_SRC_BUILDTOOLS_COMMIT=$(git rev-parse HEAD)" >> $BUILD_DIR\package\webrtc\VERSIONS
Pop-Location
Push-Location $WEBRTC_DIR\src\buildtools\third_party\libc++\trunk
  Write-Output "WEBRTC_SRC_BUILDTOOLS_THIRD_PARTY_LIBCXX_TRUNK=$(git rev-parse HEAD)" >> $BUILD_DIR\package\webrtc\VERSIONS
Pop-Location
Push-Location $WEBRTC_DIR\src\buildtools\third_party\libc++abi\trunk
  Write-Output "WEBRTC_SRC_BUILDTOOLS_THIRD_PARTY_LIBCXXABI_TRUNK=$(git rev-parse HEAD)" >> $BUILD_DIR\package\webrtc\VERSIONS
Pop-Location
Push-Location $WEBRTC_DIR\src\buildtools\third_party\libunwind\trunk
  Write-Output "WEBRTC_SRC_BUILDTOOLS_THIRD_PARTY_LIBUNWIND_TRUNK=$(git rev-parse HEAD)" >> $BUILD_DIR\package\webrtc\VERSIONS
Pop-Location
Push-Location $WEBRTC_DIR\src\third_party
  Write-Output "WEBRTC_SRC_THIRD_PARTY_COMMIT=$(git rev-parse HEAD)" >> $BUILD_DIR\package\webrtc\VERSIONS
Pop-Location
Push-Location $WEBRTC_DIR\src\tools
  Write-Output "WEBRTC_SRC_TOOLS_COMMIT=$(git rev-parse HEAD)" >> $BUILD_DIR\package\webrtc\VERSIONS
Pop-Location

# その他のファイル
Copy-Item "static\NOTICE" $BUILD_DIR\package\webrtc\NOTICE

# まとめて zip にする
if (!(Test-Path $PACKAGE_DIR)) {
  mkdir $PACKAGE_DIR
}
if (Test-Path $PACKAGE_DIR\webrtc.zip) {
  Remove-Item -Force -Path $PACKAGE_DIR\webrtc.zip
}
Push-Location $BUILD_DIR\package
  7z a $PACKAGE_DIR\webrtc.zip webrtc
Pop-Location
# 职责：构建固定依赖的FlyWow客户端握手程序集，安装到Unity Plugins。
# 边界：Build；SDK源码以本脚本目录为唯一源；不复制维护源码、不修改业务协议。
# 生命周期：下载包校验后在调用方指定目录构建，替换生成DLL；不启动Unity或Server。
# 不负责：不升级Skynet/Unity，不把.NET构建说成IL2CPP发布验证。
param([Parameter(Mandatory=$true)][string]$BuildDirectory,
      [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'FlyWowHandshake.cs'
if (-not (Test-Path -LiteralPath $source))
{
    throw "缺少SDK源码：$source"
}
$work = [IO.Path]::GetFullPath($BuildDirectory)
$package = Join-Path $work 'bc-2.6.2.nupkg'
$expectedHash = '623936FB1FD171579C706390390711282898CF2C759A5167852E5AB82208F8CB'
New-Item -ItemType Directory -Force $work | Out-Null
if (-not (Test-Path -LiteralPath $package))
{
    Invoke-WebRequest 'https://api.nuget.org/v3-flatcontainer/bouncycastle.cryptography/2.6.2/bouncycastle.cryptography.2.6.2.nupkg' -OutFile $package
}
if ((Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash -ne $expectedHash)
{
    throw 'Bouncy Castle包校验失败'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($package)
try
{
    $entry = $archive.GetEntry('lib/netstandard2.0/BouncyCastle.Cryptography.dll')
    if (-not $entry)
    {
        throw '包内缺少netstandard2.0程序集'
    }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $work 'BouncyCastle.Cryptography.dll'), $true)
    $license = $archive.GetEntry('LICENSE.md')
    if (-not $license)
    {
        throw '包内缺少原许可证'
    }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($license, (Join-Path $work 'BouncyCastle.LICENSE.md'), $true)
}
finally
{
    $archive.Dispose()
}
# 生成项目只链接唯一源码；不创建第二份客户端实现。
$escapedSource = [Security.SecurityElement]::Escape($source)
$project = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>netstandard2.1</TargetFramework><EnableDefaultCompileItems>false</EnableDefaultCompileItems><AssemblyName>FlyWow.Gateway</AssemblyName><LangVersion>8.0</LangVersion><Deterministic>true</Deterministic><NuGetAudit>false</NuGetAudit></PropertyGroup>
  <ItemGroup><Compile Include="$escapedSource" /><Reference Include="BouncyCastle.Cryptography"><HintPath>BouncyCastle.Cryptography.dll</HintPath></Reference></ItemGroup>
</Project>
"@
$projectPath = Join-Path $work 'GatewaySdk.csproj'
[IO.File]::WriteAllText($projectPath, $project, [Text.UTF8Encoding]::new($false))
dotnet build $projectPath --configuration Release --nologo
if ($LASTEXITCODE -ne 0)
{
    throw 'FlyWow客户端SDK编译失败'
}
$plugins = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $plugins | Out-Null
Copy-Item -LiteralPath (Join-Path $work 'bin/Release/netstandard2.1/FlyWow.Gateway.dll') -Destination $plugins
Copy-Item -LiteralPath (Join-Path $work 'BouncyCastle.Cryptography.dll') -Destination $plugins
Copy-Item -LiteralPath (Join-Path $work 'BouncyCastle.LICENSE.md') -Destination $plugins
Write-Output 'FLYWOW_UNITY_SDK_BUILT BC=2.6.2 target=netstandard2.1'

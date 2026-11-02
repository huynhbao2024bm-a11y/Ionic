param([Parameter(Mandatory=$true)][string]$Tag)
$ErrorActionPreference='Stop'
if ($Tag -notmatch '^v\d+\.\d+\.\d+-preview\.\d+$') { throw 'Use a versioned preview tag.' }
$workspaceRoot=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location $workspaceRoot
try {
  if (git status --porcelain) { throw 'Commit reviewed source before preparing a release.' }
  $sourceCommit=git rev-parse HEAD
  $sdkRoot=if($env:ANDROID_HOME){$env:ANDROID_HOME}else{Join-Path $env:LOCALAPPDATA 'Android\Sdk'}
  $buildTools=Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'build-tools') -Directory | Where-Object {$_.Name -match '^\d+\.\d+\.\d+$'} | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
  $aapt=Join-Path $buildTools.FullName 'aapt.exe'
  $signer=Join-Path $buildTools.FullName 'apksigner.bat'
  $releaseDir=Join-Path $workspaceRoot '.data\releases'
  New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
  $assets=[ordered]@{}; $certificate=$null; $version=$null
  foreach($abi in @('arm64-v8a','armeabi-v7a','x86_64')) {
    $source=Join-Path $workspaceRoot "apps\client\build\app\outputs\flutter-apk\app-$abi-release.apk"
    $badging=& $aapt dump badging $source
    if($LASTEXITCODE -ne 0){throw 'Cannot read APK metadata.'}
    $package=$badging | Where-Object {$_ -match "^package: name='app.ionic.mobile' versionCode='(\d+)' versionName='([^']+)'"} | Select-Object -First 1
    if(!$package -or $package -notmatch "versionCode='(\d+)' versionName='([^']+)'"){throw 'Unexpected package identity.'}
    $code=[int]$Matches[1];$candidateVersion=$Matches[2]
    if($version -and $version -ne $candidateVersion){throw 'APK versions differ.'};$version=$candidateVersion
    $verification=& $signer verify --print-certs $source
    if($LASTEXITCODE -ne 0){throw 'APK signature verification failed.'}
    $digest=($verification | Where-Object {$_ -match '^Signer #1 certificate SHA-256 digest: '}) -replace '^Signer #1 certificate SHA-256 digest: ',''
    if(!$digest -or ($certificate -and $certificate -ne $digest)){throw 'APK signing certificates differ.'};$certificate=$digest
    $name="ionic-$Tag-$abi.apk"; $destination=Join-Path $releaseDir $name
    $hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if(Test-Path -LiteralPath $destination){if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash){throw 'An existing release artifact has different bytes.'}}
    else{Copy-Item -LiteralPath $source -Destination $destination}
    $assets[$abi]=[ordered]@{url="https://github.com/huynhbao2024bm-a11y/Ionic/releases/download/$Tag/$name";sha256=$hash;bytes=(Get-Item -LiteralPath $source).Length;versionCode=$code}
  }
  $manifest=[ordered]@{schemaVersion=1;version=$version;sourceCommit=$sourceCommit;assets=$assets}
  $manifestPath=Join-Path $releaseDir 'ionic-android-update.json'
  [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  [ordered]@{manifest=$manifestPath;sourceCommit=$sourceCommit;signingCertificate=$certificate;assets=$assets} | ConvertTo-Json -Depth 8
} finally { Pop-Location }

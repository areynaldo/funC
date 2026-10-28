# Builds the funC language server, bundles it into the VS Code extension and installs it.
# Run again after changing the server or the extension.
$ErrorActionPreference = "Stop"
$extension = Join-Path $PSScriptRoot "editors/vscode"

function Invoke-Step([string]$what, [scriptblock]$step) {
	Write-Host "-- $what"
	& $step
	if ($LASTEXITCODE) { throw "$what failed (exit $LASTEXITCODE)" }
}

New-Item -ItemType Directory -Force (Join-Path $extension "server") | Out-Null
Invoke-Step "build server" { odin build (Join-Path $PSScriptRoot "lsp") "-out:$(Join-Path $extension 'server/funC-lsp.exe')" }
New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot "bin") | Out-Null
Invoke-Step "build command line tool" { odin build (Join-Path $PSScriptRoot "cli") "-out:$(Join-Path $PSScriptRoot 'bin/funC.exe')" }

Push-Location $extension
try {
	Invoke-Step "install extension dependencies" { npm install --no-audit --no-fund }
	Invoke-Step "package extension" { npx --yes @vscode/vsce@3.2.1 package --skip-license --allow-missing-repository --out func.vsix }
	Invoke-Step "install extension" { code --install-extension func.vsix --force }
} finally {
	Pop-Location
}

Write-Host "Installed. Run 'Developer: Reload Window' in VS Code, then open a .func file (try examples/hello.func)."
# a reinstall at the same version doesn't restart anything: a running server is still the old build
$running = Get-Process funC-lsp -ErrorAction SilentlyContinue
if ($running) {
	Write-Warning "$($running.Count) funC server(s) from before this install are still running. VS Code keeps using the old build, which may reject newer .func files, until you reload the window."
}

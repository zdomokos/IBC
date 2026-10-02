#Requires -Version 7

# Builds build/userguide.pdf from docs/userguide.md (the PDF isn't committed). Needs
# pandoc and xelatex (for example MiKTeX) on the PATH.

$ErrorActionPreference = 'Stop'
$docs = Split-Path $PSScriptRoot -Parent
$build = Join-Path (Split-Path $docs -Parent) 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null

pandoc (Join-Path $PSScriptRoot 'meta.yml') (Join-Path $docs 'userguide.md') `
    -f markdown -o (Join-Path $build 'userguide.pdf') --pdf-engine=xelatex
exit $LASTEXITCODE

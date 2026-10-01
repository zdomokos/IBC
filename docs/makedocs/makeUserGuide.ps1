#Requires -Version 7

# Builds docs/userguide.pdf from docs/userguide.md. Needs pandoc and xelatex
# (for example MiKTeX) on the PATH.

$ErrorActionPreference = 'Stop'
$docs = Split-Path $PSScriptRoot -Parent

pandoc (Join-Path $PSScriptRoot 'meta.yml') (Join-Path $docs 'userguide.md') `
    -f markdown -o (Join-Path $docs 'userguide.pdf') --pdf-engine=xelatex
exit $LASTEXITCODE

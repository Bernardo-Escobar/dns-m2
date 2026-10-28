param(
    [Parameter(Mandatory=$true)]
    [string]$NovoIP,
    [switch]$SemReload
)
# Coleta automatica: transcript, logs Docker, parametros e status por execucao.
if ($env:DNS_EVIDENCE_WRAPPED -ne '1') {
    & (Join-Path $PSScriptRoot "_registrar-evidencias.ps1") -ScriptPath $PSCommandPath -Parametros $PSBoundParameters -Experimento 'AUX'
    return
}

$ErrorActionPreference = 'Stop'
if ($NovoIP -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$' -or
    @($NovoIP.Split('.') | Where-Object { [int]$_ -gt 255 }).Count -gt 0) {
    throw "IP IPv4 invalido: $NovoIP"
}
$zona = Join-Path $PSScriptRoot '..\zones\db.sd.lab'
$texto = [System.IO.File]::ReadAllText((Resolve-Path $zona))
$padraoApp = '(?m)^(app\s+IN\s+A\s+)(\d{1,3}(?:\.\d{1,3}){3})(\s*)$'
$m = [regex]::Match($texto, $padraoApp)
if (-not $m.Success) { throw "Nao foi encontrado o registro app IN A no arquivo da zona." }
$antigo = $m.Groups[2].Value
$texto = $texto.Substring(0, $m.Groups[2].Index) + $NovoIP + $texto.Substring($m.Groups[2].Index + $m.Groups[2].Length)
$padraoSerial = '(?m)(\d{10})(\s*;\s*serial\b)'
$s = [regex]::Match($texto, $padraoSerial)
if (-not $s.Success) { throw "Serial da zona nao encontrado." }
$serialAntigo = [long]$s.Groups[1].Value
$serialNovo = $serialAntigo + 1
$texto = $texto.Substring(0, $s.Groups[1].Index) + $serialNovo.ToString() + $texto.Substring($s.Groups[1].Index + $s.Groups[1].Length)
[System.IO.File]::WriteAllText((Resolve-Path $zona), $texto, [System.Text.Encoding]::ASCII)
Write-Host "app.sd.lab: $antigo -> $NovoIP | serial $serialAntigo -> $serialNovo" -ForegroundColor Green
if (-not $SemReload) {
    docker exec ns1 rndc -k /etc/bind/rndc.key reload sd.lab
    if ($LASTEXITCODE -ne 0) { throw "Falha ao recarregar a zona do NS1." }
    Write-Host "Verifique os secundaries: .\scripts\01-diagnostico.ps1"
}

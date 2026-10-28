
# Coleta automatica: transcript, logs Docker, parametros e status por execucao.
if ($env:DNS_EVIDENCE_WRAPPED -ne '1') {
    & (Join-Path $PSScriptRoot "_registrar-evidencias.ps1") -ScriptPath $PSCommandPath -Parametros $PSBoundParameters -Experimento 'AUX'
    return
}
Write-Host 'Verificando Docker Desktop, Docker Compose e status do motor...' -ForegroundColor Cyan
docker --version
docker compose version
docker info --format 'Servidor Docker: {{.ServerVersion}} | Sistema: {{.OperatingSystem}}'
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'Docker nao respondeu. Abra o Docker Desktop e verifique o WSL 2.'
} else {
    Write-Host 'Docker esta respondendo.' -ForegroundColor Green
}

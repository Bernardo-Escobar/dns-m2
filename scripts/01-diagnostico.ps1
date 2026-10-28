
# Coleta automatica: transcript, logs Docker, parametros e status por execucao.
if ($env:DNS_EVIDENCE_WRAPPED -ne '1') {
    & (Join-Path $PSScriptRoot "_registrar-evidencias.ps1") -ScriptPath $PSCommandPath -Parametros $PSBoundParameters -Experimento 'AUX'
    return
}
$ErrorActionPreference = 'Stop'
Push-Location (Resolve-Path "$PSScriptRoot/..")
try {
    Write-Host "=== STATUS DOS CONTEINERES ===" -ForegroundColor Cyan
    docker compose ps
    Write-Host "`n=== RESPOSTAS AUTORITATIVAS ===" -ForegroundColor Cyan
    foreach ($s in @(11,12,13)) {
        Write-Host "NS$s - registro A:" -ForegroundColor Yellow
        docker exec cliente dig "@172.31.0.$s" app.sd.lab A +short
        Write-Host "NS$s - SOA:" -ForegroundColor Yellow
        docker exec cliente dig "@172.31.0.$s" sd.lab SOA +short
    }
    Write-Host "`n=== RESPOSTA PELO RESOLVEDOR ===" -ForegroundColor Cyan
    docker exec cliente dig "@172.31.0.53" app.sd.lab A +short
    Write-Host "`n=== CONTROLE DO NS1 ===" -ForegroundColor Cyan
    docker exec ns1 rndc -k /etc/bind/rndc.key status
} finally {
    Pop-Location
}

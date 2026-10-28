# E9: comparar tamanho de respostas identicas, diferindo apenas no bit DO.

# Coleta automatica: transcript, logs Docker, parametros e status por execucao.
if ($env:DNS_EVIDENCE_WRAPPED -ne '1') {
    & (Join-Path $PSScriptRoot "_registrar-evidencias.ps1") -ScriptPath $PSCommandPath -Parametros $PSBoundParameters -Experimento 'E9'
    return
}
$ErrorActionPreference='Stop'
$raiz=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $raiz
try {
 $dir=Join-Path $raiz 'evidencias\E9';New-Item -ItemType Directory -Force $dir|Out-Null
 $a=(& docker exec cliente dig '@172.31.0.11' app.sd.lab A +nodnssec +nocookie +noall +answer +stats 2>&1) -join "`n"
 if($LASTEXITCODE -ne 0){throw 'Falha na consulta sem DNSSEC.'}
 $b=(& docker exec cliente dig '@172.31.0.11' app.sd.lab A +dnssec +nocookie +noall +answer +stats 2>&1) -join "`n"
 if($LASTEXITCODE -ne 0){throw 'Falha na consulta com DNSSEC.'}
 $m1=[regex]::Match($a,'MSG SIZE\s+rcvd:\s*(\d+)');$m2=[regex]::Match($b,'MSG SIZE\s+rcvd:\s*(\d+)')
 if(-not $m1.Success -or -not $m2.Success){throw 'Nao foi possivel extrair MSG SIZE rcvd.'}
 if($b -notmatch '\bRRSIG\s+A\b'){throw 'Resposta DNSSEC sem RRSIG A; verifique ativacao.'}
 $n1=[int]$m1.Groups[1].Value;$n2=[int]$m2.Groups[1].Value
 $pct=[math]::Round(100.0*($n2-$n1)/$n1,2)
 $resumo="Sem DNSSEC: $n1 bytes; com DNSSEC: $n2 bytes; diferenca: $($n2-$n1) bytes; aumento: $pct %."
 Write-Host $resumo -ForegroundColor Green
 @($resumo,'','SEM DNSSEC:',$a,'','COM DNSSEC:',$b) | Out-File (Join-Path $dir 'comparacao-tamanho.txt') -Encoding utf8
} finally {Pop-Location}

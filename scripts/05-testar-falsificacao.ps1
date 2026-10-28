# E9: UNICO teste de falsificacao: dado A adulterado com RRSIG original preservada.
# PowerShell 5.1+; executar apos .\ativar-dnssec.ps1.
param([switch]$Restaurar)
# Coleta automatica: transcript, logs Docker, parametros e status por execucao.
if ($env:DNS_EVIDENCE_WRAPPED -ne '1') {
    & (Join-Path $PSScriptRoot "_registrar-evidencias.ps1") -ScriptPath $PSCommandPath -Parametros $PSBoundParameters -Experimento 'E9'
    return
}

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Push-Location (Resolve-Path (Join-Path $PSScriptRoot '..'))
$zona = '.\zones\db.sd.lab.adulterado'
$config = '.\configs\resolvedor\named.conf'
$backupZona = '.\evidencias\E9\atacante-zona.pre-teste.bak'
$backupConfig = '.\evidencias\E9\resolvedor-conf.pre-teste.bak'
$evidencias = '.\evidencias\E9'
$alterou = $false
function DockerChecked([string[]]$ArgsDocker) {
    # Mensagens de progresso em stderr nao sao falhas quando exit code = 0.
    $saida = @(& {
        $ErrorActionPreference = 'Continue'
        & docker @ArgsDocker 2>&1
    })
    $codigo = $LASTEXITCODE
    if ($codigo -ne 0) { throw "Falha: docker $($ArgsDocker -join ' ') (exit $codigo)`n$($saida -join "`n")" }
    return $saida
}
function Restaurar-Ambiente {
    if (Test-Path $backupConfig) { Copy-Item $backupConfig $config -Force }
    if (Test-Path $backupZona) { Copy-Item $backupZona $zona -Force }
    DockerChecked @('exec','resolvedor','named-checkconf') | Out-Null
    DockerChecked @('restart','resolvedor') | Out-Host
    $running = @(& {
        $ErrorActionPreference = 'Continue'
        & docker inspect -f '{{.State.Running}}' atacante 2>$null
    })
    $inspectCodigo = $LASTEXITCODE
    if ($inspectCodigo -eq 0 -and "$running".Trim() -eq 'true') {
        DockerChecked @('restart','atacante') | Out-Host
    }
    DockerChecked @('exec','resolvedor','rndc','flush') | Out-Null
    Start-Sleep -Seconds 2
    $confirmacao = (DockerChecked @('exec','cliente','dig','@172.31.0.53','app.sd.lab','A','+dnssec','+nocookie','+time=3','+tries=1') | Out-String)
    $confirmacao | Set-Content -Encoding ascii (Join-Path $evidencias 'e9-apos-restauracao.txt')
    if ($confirmacao -notmatch 'status:\s*NOERROR' -or $confirmacao -notmatch 'flags:.*\bad\b' -or $confirmacao -match '10\.66\.66\.66') {
        throw 'Restauracao nao comprovada: esperado NOERROR com flag ad e IP legitimo.'
    }
    Write-Host 'Arquivos e resolvedor restaurados; NOERROR + AD confirmados.' -ForegroundColor Green
}
try {
    if ($Restaurar) { Restaurar-Ambiente; return }
    New-Item -ItemType Directory -Path $evidencias -Force | Out-Null
    if ((Test-Path $backupConfig) -or (Test-Path $backupZona)) {
        throw 'Ha backups de um teste anterior. Execute -Restaurar e confira o ambiente antes de repetir.'
    }
    foreach ($p in @($zona,$config,'.\configs\resolvedor\trust-anchors.conf')) {
        if (-not (Test-Path $p)) { throw "Arquivo ausente: $p" }
    }
    $confOriginal = Get-Content $config -Raw
    $anchor = Get-Content '.\configs\resolvedor\trust-anchors.conf' -Raw
    if ($confOriginal -notmatch 'dnssec-validation\s+yes\s*;' -or
        $confOriginal -notmatch 'include\s+"/etc/bind/trust-anchors.conf"\s*;' -or
        $anchor -notmatch 'static-key') { throw 'Ative DNSSEC e configure a ancora antes do teste.' }
    $forwarders = 'forwarders\s*\{\s*172\.31\.0\.11\s*;\s*172\.31\.0\.12\s*;\s*172\.31\.0\.13\s*;\s*\}\s*;'
    if ([regex]::Matches($confOriginal,$forwarders).Count -ne 1) {
        throw 'Forwarders legitimos nao encontrados exatamente uma vez. Restaure a configuracao original.'
    }
    Write-Host '1/5 Exportando zona DNSSEC legitima por AXFR...' -ForegroundColor Cyan
    $axfr = DockerChecked @('exec','ns2','dig','@172.30.0.11','sd.lab','AXFR','+dnssec','+noall','+answer','+onesoa','+nostats','+time=3','+tries=1')
    $original = ($axfr -join "`n") + "`n"
    if ($original -notmatch '(?m)^sd\.lab\.\s+\d+\s+IN\s+DNSKEY\s+' -or
        $original -notmatch '(?m)^app\.sd\.lab\.\s+\d+\s+IN\s+RRSIG\s+A\s+') {
        throw 'AXFR incompleta: DNSKEY ou RRSIG A ausente.'
    }
    $padrao = '(?m)^(app\.sd\.lab\.\s+\d+\s+IN\s+A\s+)(\d{1,3}(?:\.\d{1,3}){3})(\s*)$'
    $matchesA = [regex]::Matches($original,$padrao)
    if ($matchesA.Count -ne 1) { throw "Esperado um unico A de app.sd.lab; encontrados $($matchesA.Count)." }
    $ipLegitimo = $matchesA[0].Groups[2].Value
    if ($ipLegitimo -eq '10.66.66.66') { throw 'IP legitimo ja adulterado.' }
    $adulterado = $original.Substring(0,$matchesA[0].Groups[2].Index) + '10.66.66.66' + $original.Substring($matchesA[0].Groups[2].Index + $matchesA[0].Groups[2].Length)
    [IO.File]::WriteAllText((Join-Path (Get-Location).Path 'evidencias/E9/zona-assinada-original.txt'),$original,[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path (Get-Location).Path 'evidencias/E9/zona-assinada-adulterada.txt'),$adulterado,[Text.Encoding]::ASCII)
    Copy-Item $zona $backupZona -Force
    Copy-Item $config $backupConfig -Force
    $alterou = $true
    [IO.File]::WriteAllText((Join-Path (Get-Location).Path 'zones/db.sd.lab.adulterado'),$adulterado,[Text.Encoding]::ASCII)
    Write-Host "Alterado SOMENTE o registro A: $ipLegitimo -> 10.66.66.66; RRSIG preservada." -ForegroundColor Yellow
    Write-Host '2/5 Iniciando atacante com a zona assinada adulterada...' -ForegroundColor Cyan
    DockerChecked @('compose','--profile','seguranca','up','-d','atacante') | Out-Host
    DockerChecked @('exec','atacante','named-checkzone','sd.lab','/etc/bind/db.sd.lab.adulterado') | Out-Host
    DockerChecked @('exec','atacante','rndc','reload','sd.lab') | Out-Host
    Start-Sleep -Seconds 2
    $direto = (DockerChecked @('exec','cliente','dig','@172.31.0.66','app.sd.lab','A','+dnssec','+norecurse','+nocookie','+time=3','+tries=1') | Out-String)
    $direto | Set-Content -Encoding ascii (Join-Path $evidencias 'e9-atacante.txt')
    if ($direto -notmatch 'status:\s*NOERROR' -or $direto -notmatch '10\.66\.66\.66' -or $direto -notmatch '\bRRSIG\s+A\b') {
        throw 'Atacante nao respondeu com IP adulterado E RRSIG A original.'
    }
    Write-Host '3/5 Apontando resolvedor validador somente ao atacante...' -ForegroundColor Cyan
    $confAtaque = [regex]::Replace($confOriginal,$forwarders,'forwarders { 172.31.0.66; };')
    [IO.File]::WriteAllText((Join-Path (Get-Location).Path 'configs/resolvedor/named.conf'),$confAtaque,[Text.Encoding]::ASCII)
    DockerChecked @('exec','resolvedor','named-checkconf') | Out-Null
    DockerChecked @('restart','resolvedor') | Out-Host
    DockerChecked @('exec','resolvedor','rndc','flush') | Out-Null
    Write-Host '4/5 Testando SERVFAIL e controle CD...' -ForegroundColor Cyan
    $normal = (DockerChecked @('exec','cliente','dig','@172.31.0.53','app.sd.lab','A','+dnssec','+nocookie','+time=3','+tries=1') | Out-String)
    $normal | Set-Content -Encoding ascii (Join-Path $evidencias 'e9-validacao-normal.txt')
    Write-Host $normal
    $cd = (DockerChecked @('exec','cliente','dig','@172.31.0.53','app.sd.lab','A','+dnssec','+cdflag','+nocookie','+time=3','+tries=1') | Out-String)
    $cd | Set-Content -Encoding ascii (Join-Path $evidencias 'e9-controle-cd.txt')
    Write-Host $cd
    $logs = DockerChecked @('logs','--since','3m','resolvedor')
    $logs | Set-Content -Encoding ascii (Join-Path $evidencias 'e9-logs-resolvedor.txt')
    if ($normal -notmatch 'status:\s*SERVFAIL') { throw 'Teste inconclusivo: resposta normal nao retornou SERVFAIL.' }
    if ($cd -notmatch 'status:\s*NOERROR' -or $cd -notmatch '10\.66\.66\.66') {
        throw 'Teste inconclusivo: consulta CD nao retornou NOERROR e IP adulterado.'
    }
    if ($logs -notmatch '(?i)validat|RRSIG|signature|broken trust|insecurity|dnssec') {
        Write-Warning 'Logs nao mostram causa DNSSEC; SERVFAIL + CD sao evidencias, mas investigue a causa antes de concluir.'
    }
    Write-Host '5/5 SERVFAIL com validacao; NOERROR e IP adulterado com CD. Evidencias salvas.' -ForegroundColor Green
    Write-Host 'Consulte e9-logs-resolvedor.txt para confirmar mensagens de falha DNSSEC.'
} finally {
    if ($alterou) {
        Write-Host 'Restaurando automaticamente o laboratorio...' -ForegroundColor Cyan
        Restaurar-Ambiente
        # Excluir backups apenas apos restauracao bem-sucedida.
        Remove-Item $backupZona,$backupConfig -Force
    }
    Pop-Location
}

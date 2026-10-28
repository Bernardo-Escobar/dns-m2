# E4 - Cache negativo (DNS): NXDOMAIN -> registro criado -> NXDOMAIN em cache -> resposta atualizada
# Executar a partir de C:\dns-m2: .\scripts\07-e4-cache-negativo.ps1

# Coleta automatica: transcript, logs Docker, parametros e status por execucao.
if ($env:DNS_EVIDENCE_WRAPPED -ne '1') {
    & (Join-Path $PSScriptRoot "_registrar-evidencias.ps1") -ScriptPath $PSCommandPath -Parametros $PSBoundParameters -Experimento 'E4'
    return
}
$ErrorActionPreference = 'Stop'

$raiz = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$zona = Join-Path $raiz 'zones\db.sd.lab'
$pastaEvidencias = Join-Path $raiz 'evidencias'
$arquivoLog = Join-Path $pastaEvidencias 'e4-cache-negativo.txt'
$arquivoBackup = Join-Path $pastaEvidencias 'db.sd.lab.antes-e4'

if (-not (Test-Path -LiteralPath $zona)) { throw "Arquivo da zona nao encontrado: $zona" }
if (-not (Test-Path -LiteralPath $pastaEvidencias)) {
    New-Item -Path $pastaEvidencias -ItemType Directory | Out-Null
}

$textoOriginal = [System.IO.File]::ReadAllText($zona)
if ($textoOriginal -match '(?m)^\s*novo\s+IN\s+A\s+') {
    throw 'O registro novo.sd.lab ja existe na zona. Nao execute novamente sem preparar outro nome de teste.'
}

function Registrar {
    param([string]$Mensagem)
    Write-Host $Mensagem
    [System.IO.File]::AppendAllText($arquivoLog, $Mensagem + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
}

function Consultar {
    param([string]$Endereco)
    $saida = & docker exec cliente dig ("@${Endereco}") novo.sd.lab A +time=2 +tries=1 +noall +comments +answer +authority
    if ($LASTEXITCODE -ne 0) { throw "Falha de consulta DNS para ${Endereco}." }
    return ($saida -join [Environment]::NewLine)
}

[System.IO.File]::WriteAllText($arquivoLog, '', [System.Text.Encoding]::UTF8)
Registrar '=== EXPERIMENTO E4 - CACHE NEGATIVO ==='
Registrar ("Iniciado em: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'))
Registrar '1) Limpando a entrada negativa no cache do resolvedor...'
& docker exec resolvedor rndc -k /etc/bind/rndc.key flushname novo.sd.lab
if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel limpar o cache do resolvedor.' }

Registrar '2) Consultando novo.sd.lab ANTES de criar (esperado: NXDOMAIN)...'
$antes = Consultar '172.31.0.53'
Registrar $antes
if ($antes -notmatch 'status:\s*NXDOMAIN') {
    throw 'A consulta inicial nao retornou NXDOMAIN. O experimento foi interrompido sem alterar a zona.'
}

# Registrar backup e atualizar sem pausa, para observar a janela curta de TTL negativo (20 s).
Copy-Item -LiteralPath $zona -Destination $arquivoBackup -Force
$padraoSerial = '(?m)(\d{10})(\s*;\s*serial\b)'
$match = [regex]::Match($textoOriginal, $padraoSerial)
if (-not $match.Success) { throw 'Serial SOA nao encontrado no arquivo da zona.' }
$serialAnterior = [long]$match.Groups[1].Value
$serialNovo = $serialAnterior + 1
$textoNovo = $textoOriginal.Substring(0, $match.Groups[1].Index) + $serialNovo.ToString() + $textoOriginal.Substring($match.Groups[1].Index + $match.Groups[1].Length)
if (-not $textoNovo.EndsWith("`n")) { $textoNovo += "`r`n" }
$textoNovo += "novo IN A 10.0.0.50`r`n"
[System.IO.File]::WriteAllText($zona, $textoNovo, [System.Text.Encoding]::ASCII)
Registrar ("3) Novo registro adicionado no primario: novo.sd.lab -> 10.0.0.50, serial $serialAnterior -> $serialNovo")

& docker exec ns1 named-checkzone sd.lab /var/lib/bind/db.sd.lab
if ($LASTEXITCODE -ne 0) { throw 'Erro na sintaxe da zona; verifique o backup antes de prosseguir.' }
& docker exec ns1 rndc -k /etc/bind/rndc.key reload sd.lab
if ($LASTEXITCODE -ne 0) { throw 'Falha no reload do primario.' }

$relogio = [Diagnostics.Stopwatch]::StartNew()
Registrar '4) Resposta direta do primario (esperado: 10.0.0.50):'
$primario = Consultar '172.31.0.11'
Registrar $primario
Registrar '5) Resposta imediata do resolvedor (esperado: NXDOMAIN enquanto TTL negativo estiver ativo):'
$logoApos = Consultar '172.31.0.53'
Registrar $logoApos
if ($logoApos -match 'status:\s*NXDOMAIN') {
    Registrar 'RESULTADO: o resolvedor continuou respondendo NXDOMAIN mesmo com o registro criado no NS1.'
} else {
    Registrar 'OBSERVACAO: nao foi visto NXDOMAIN apos a criacao. O cache pode ter expirado antes da consulta; repetir com nome de teste novo.'
}

Registrar '6) Consultando o resolvedor a cada 2 segundos ate obter o registro novo...'
$atualizou = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 2
    $resposta = Consultar '172.31.0.53'
    if ($resposta -match '10\.0\.0\.50') {
        Registrar ("Resolvedor atualizado apos cerca de " + [math]::Round($relogio.Elapsed.TotalSeconds,1) + ' s desde o reload:')
        Registrar $resposta
        $atualizou = $true
        break
    }
}
if (-not $atualizou) {
    Registrar 'ATENCAO: o resolvedor nao retornou o novo registro durante os 40 segundos de verificacao. Inspecione os secundarios e seus logs.'
}
Registrar ("Evidencia: $arquivoLog")
Registrar ("Backup anterior a alteracao: $arquivoBackup")

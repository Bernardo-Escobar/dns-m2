# Guia de portabilidade e execucao manual — DNS M2

Este ZIP inicia em **E1–E8 (DNSSEC desabilitado)**, com `app.sd.lab = 10.0.0.1` e serial `2026102301`. Os resultados antigos continuam na pasta `evidencias/`. O arquivo `zones/db.sd.lab.final-e8` guarda o estado da zona que veio no ZIP original. **Nao executar scripts da pasta `scripts/` e necessario** para os procedimentos abaixo.

## Requisitos e inicializacao no PowerShell

Instalar Docker Desktop com Docker Compose e backend Linux/WSL2 (Windows), ou Docker Engine/Compose (Linux). Abrir PowerShell na pasta extraida. Verificar se as redes `172.30.0.0/24` e `172.31.0.0/24` nao conflitam com VPN ou redes existentes.

```powershell
docker compose up -d --build
docker compose ps
docker exec cliente dig "@172.31.0.11" app.sd.lab A +short
docker exec cliente dig "@172.31.0.53" app.sd.lab A +short
```

Resultado inicial esperado: `10.0.0.1`. Se os secundarios ainda estiverem carregando, aguardar alguns segundos. No PowerShell, **colocar os argumentos `@IP` entre aspas**.

## E1–E8

Executar os testes de acordo com o enunciado e o roteiro do projeto. Para alterar a zona: `notepad .\zones\db.sd.lab`, incrementar o SOA serial, validar `docker exec ns1 named-checkzone sd.lab /var/lib/bind/db.sd.lab`, aplicar `docker exec ns1 rndc reload sd.lab`. Para mudancas de `named.conf`, usar `docker restart <container>`. As mudancas de E3–E8 alteram o estado do laboratorio: registrar e restaurar as configuracoes apos cada teste. Os scripts legados sao opcionais e podem ter pressupostos diferentes.

## E9 — ativacao automatica (recomendado)

Na pasta principal, depois de concluir E1-E8 e iniciar os cinco conteineres, execute no PowerShell:

```powershell
.\ativar-dnssec.ps1
```

O arquivo na raiz do projeto (nao na pasta `scripts`) habilita DNSSEC no ns1, espera a nova DNSKEY, atualiza `trust-anchors.conf`, ativa o resolvedor e verifica `NOERROR`, `ad` e `RRSIG`. Nao e necessario copiar chaves manualmente. Ele guarda copias anteriores dos arquivos `.conf` com sufixo `.pre-e9`. Se o PowerShell bloquear scripts, use `powershell -ExecutionPolicy Bypass -File .\ativar-dnssec.ps1` apenas se confiar no conteudo do arquivo.

**Nao execute com o resolvedor apontando para o atacante.** O procedimento substitui a configuracao do resolvedor pela versao legitima. Para repetir E9 com chaves novas, recrie o volume DNSSEC e execute novamente; nao mantenha uma ancora antiga. A ativacao foi preparada para PowerShell e Docker Compose; precisa ser validada no seu Docker.

### Alternativa manual

## E9 — assinatura e validacao DNSSEC em uma instalacao nova

**Nao reutilizar uma ancora antiga.** A chave privada e gerada pelo `ns1` no volume Docker `ns1_keys`, que nao faz parte do ZIP. O arquivo `configs/ns1/named.conf.dnssec` ja contem `dnssec-policy default`, `inline-signing yes` e `key-directory`.

1. Com E1–E8 encerrados e servidores saudaveis, ativar a configuracao DNSSEC no primario:

```powershell
Copy-Item .\configs\ns1\named.conf.dnssec .\configs\ns1\named.conf -Force
docker exec ns1 named-checkconf
docker restart ns1
docker exec cliente dig "@172.31.0.11" sd.lab DNSKEY +dnssec +noall +answer
docker exec cliente dig "@172.31.0.11" app.sd.lab A +dnssec +noall +answer
```

2. Esperar os secundarios receberem a zona assinada; conferir SOA nos tres servidores. **Copiar a chave publica DNSKEY atual**, que aparece como `sd.lab. ... IN DNSKEY 257 3 13 <BASE64>` (a base64 pode estar quebrada em varios grupos). Nao copiar a chave `.private`.

3. Editar `configs/resolvedor/trust-anchors.conf` e inserir:

```conf
trust-anchors {
    sd.lab. static-key 257 3 13 "<BASE64_DA_DNSKEY_ATUAL_SEM_ESPACOS>";
};
```

4. Ativar o resolvedor validador:

```powershell
Copy-Item .\configs\resolvedor\named.conf.dnssec .\configs\resolvedor\named.conf -Force
docker exec resolvedor named-checkconf
docker restart resolvedor
docker exec cliente dig "@172.31.0.53" app.sd.lab A +dnssec
```

A resposta legitima deve conter `NOERROR` e flag `ad`. Se retornar `SERVFAIL`, conferir a chave publica, os logs do resolvedor e o sincronismo dos secundarios. Uma chave nova **nao** valida com a ancora antiga.

## E9 — UNICO teste de adulteracao: RRSIG original preservada

Apos ativar DNSSEC com ` .\ativar-dnssec.ps1 `, execute **somente**:

```powershell
.\scripts\05-testar-falsificacao.ps1
```

O script exporta a zona assinada via AXFR, altera apenas o registro `A` de `app.sd.lab` para `10.66.66.66`, preserva a `RRSIG A` original, inicia o atacante com essa zona, encaminha temporariamente o resolvedor validador ao atacante, verifica `SERVFAIL` e compara com a consulta `+cdflag` (`NOERROR` e IP adulterado). Os resultados e logs ficam em `evidencias/E9/`. O script restaura automaticamente os arquivos de zona e configuracao mesmo se o teste falhar; confira a restauracao no terminal. **Nao existe teste alternativo com zona sem RRSIG.**

Se for necessario recuperar manualmente os arquivos apos uma interrupcao abrupta:

```powershell
.\scripts\05-testar-falsificacao.ps1 -Restaurar
```

Para conferir a recuperacao, consulte `docker exec cliente dig "@172.31.0.53" app.sd.lab A +dnssec` e verifique `NOERROR`, IP legitimo e flag `ad`. A saida dos logs deve ser examinada para corroborar a falha de assinatura.

## E9 — tamanho de resposta

```powershell
docker exec cliente dig "@172.31.0.53" app.sd.lab A +nodnssec +nocookie +stats
docker exec cliente dig "@172.31.0.53" app.sd.lab A +dnssec +nocookie +stats
```

Comparar `MSG SIZE rcvd` e `ANSWER`. Os 55/157 bytes medidos na maquina original sao **resultados anteriores**, nao valores garantidos para outro ambiente.

## Limpeza e repeticao

`docker compose down` remove conteineres e redes, mas **preserva** o volume `ns1_keys`. Para comecar do zero, primeiro restaurar `named.conf` inicial (sem DNSSEC), `trust-anchors.conf` vazio e a zona inicial; entao `docker compose down -v` e `docker compose up -d --build`. **Cuidado:** `down -v` apaga as chaves DNSSEC persistidas, e qualquer ancora anterior deixa de valer. Nao executar `down -v` durante E9 sem refazer a ancora.

O `compose.yaml` usa nomes fixos de containers e redes; executar apenas uma copia do laboratorio por vez. `docker compose config` permite conferir a sintaxe antes de iniciar. O ZIP nao inclui imagens Docker, volumes nem estado de cache. Os experimentos que envolvem tempo de cache, propagacao e expiracao devem ser medidos novamente em cada maquina.

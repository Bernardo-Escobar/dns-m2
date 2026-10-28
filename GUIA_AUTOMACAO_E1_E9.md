# Guia de execução dos experimentos DNS E1–E9

## Preparação

No PowerShell, na pasta do projeto:

```powershell
docker compose up -d
.\scripts\00-checar-docker.ps1
.\scripts\01-diagnostico.ps1
```

Execute **um experimento por vez**. Os experimentos com mudanças exigem `-ConfirmarAlteracoes`. Os arquivos de evidência ficam em `evidencias/E*/<data-hora>/`.

## Execução

```powershell
.\scripts\08-experimentos-e1-e8.ps1 -Experimento E1
.\scripts\08-experimentos-e1-e8.ps1 -Experimento E2
.\scripts\08-experimentos-e1-e8.ps1 -Experimento E3 -ConfirmarAlteracoes -Repeticoes 5
.\scripts\08-experimentos-e1-e8.ps1 -Experimento E4 -ConfirmarAlteracoes
.\scripts\08-experimentos-e1-e8.ps1 -Experimento E5 -ConfirmarAlteracoes
.\scripts\08-experimentos-e1-e8.ps1 -Experimento E6 -ConfirmarAlteracoes
.\scripts\08-experimentos-e1-e8.ps1 -Experimento E7 -ConfirmarAlteracoes -Repeticoes 5
.\scripts\08-experimentos-e1-e8.ps1 -Experimento E8 -ConfirmarAlteracoes
```

E9, **somente adulteração com RRSIG original**:

```powershell
.\ativar-dnssec.ps1
.\scripts\05-testar-falsificacao.ps1
.\scripts\06-comparar-tamanho.ps1
```

## Limitações e cuidados

- E3 mede cinco repetições com e sem NOTIFY, com sondagem de 100 ms. O refresh do SOA é 30 s: a série sem NOTIFY pode levar vários minutos. Os resultados não são garantidos até a execução.
- E4 usa um nome inexistente exclusivo para cache negativo e registra a janela temporal.
- E5 não publica alterações com ns1 parado: demonstra a impossibilidade da escrita e coleta consultas diretas.
- E6 observa o SERVFAIL após expiração da zona de ns3; 
- E7 usa isolamento/reconexão repetidos e `rndc refresh`, medindo a recuperação do registro e comparando os seriais. Se E6 não chegar a SERVFAIL, a evidência é inconclusiva.
- E8 usa serial inferior e consulta os seriais. Com DNSSEC inline, podem existir serial interno e serial de arquivo diferentes; confira o SOA servido antes de concluir.
- A restauração é feita em `finally` para falhas tratáveis, **mas não cobre encerramento abrupto do PowerShell, queda de energia ou interrupção do Docker**. O serial de restauração é incrementado (não retrocede).
- Para E9, não há opção de teste simplificado: a zona é exportada por AXFR, o registro A é alterado sem reassinar, o resolvedor valida, consulta CD é usada como controle e a configuração é restaurada.

## Coleta automatica padronizada (todos os scripts)

Todos os scripts `.ps1` da pasta `scripts` e o `ativar-dnssec.ps1` da raiz iniciam automaticamente uma coleta ao serem chamados diretamente. Cada execucao recebe uma pasta independente:

```text
evidencias/<E1..E9 ou AUX>/<AAAAMMDD-HHMMSS-ms>-<nome-do-script>/
  execucao.json          # comando/parametros e horario inicial
  terminal.txt           # transcricao do PowerShell
  resultado.json         # SUCESSO/ERRO e duracao
  erro.txt               # somente em caso de excecao
  docker-compose-ps.txt  # estado dos conteineres ao terminar
  logs-ns1.txt           # logs do periodo da execucao
  logs-ns2.txt
  logs-ns3.txt
  logs-resolvedor.txt
```

**Limites:** a transcricao pode nao incluir saidas redirecionadas para arquivos ou suprimidas pelo script original; por isso os artefatos proprios dos experimentos continuam importantes. `resultado.json` indica se o script terminou sem erro do PowerShell, nao se o experimento atendeu a todos os criterios cientificos. A coleta de logs depende de Docker acessivel. Falhas abruptas, `exit` no processo ou desligamento podem impedir a gravacao final. Execute os testes em PowerShell no Windows, um de cada vez.

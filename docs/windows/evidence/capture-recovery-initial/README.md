# Evidência da recuperação limitada de captura

Campanhas de 30/09 e 01/10/2026, interpretadas no [relatório de recuperação](../../capture-recovery-progress.md).
Os resultados positivos e as falhas esperadas possuem escopos distintos.

- `desktop-024/`: dez ciclos de perda injetada da duplicação DXGI real em 30/09; CSV completo, resultado do host, polling e lançamento da janela animada.
- `reconciliation.json`: primeira linha IDR de cada época, tempo do host até nova aquisição, polling externo e recursos amostrados.
- `desktop-024-client.log`: continuação do decode na mesma execução do cliente durante a campanha positiva.
- `desktop-025/` e `desktop-026/`: autenticação sem primeiro frame em 01/10; preservam falha em vez de marcar uma sessão normal como aprovada.
- `desktop-025-client.log`, `desktop-026-client.log` e `desktop-026-retry-client.log`: observação do cliente para as inicializações que falharam.
- `desktop-027/`: perda persistente injetada desde a inicialização; `negative-test.json` exige código de saída 1 e registra que não existiu primeiro frame antes da injeção.
- `recovery-build.log`, `recovery-diagnostic-build.log` e `ux03-native-build.log`: build MSVC e casos determinísticos de recuperação/input, sem enviar teclado real nesses casos.
- `recovery-baseline-*` e `recovery-final-*`: testes da implementação de recuperação, anteriores ao incremento de menu da sessão.
- `ux03-cleanup.json`: zero processos Windows, tarefas, porta UDP e regras temporárias ao encerrar a rodada de 01/10.
- `source-manifest.json`: hashes dos fontes selecionados e identificação da base Git com alterações locais.
- `MANIFEST.sha256`: integridade de todos os arquivos desta pasta, exceto o próprio manifesto.

UTF-16 foi normalizado para UTF-8 nos arquivos selecionados.
Workers de lançamento e arquivo privado de pareamento não estão incluídos.
Os marcadores vazios `stop`/`hold-capture-loss` são comandos de laboratório preservados como evidência; não são chaves.
Não houve bloqueio real, alteração de frequência, mudança de resolução ou remoção do device nesta campanha.
Os tempos do host não incluem encode/apresentação e não medem latência ponta a ponta.

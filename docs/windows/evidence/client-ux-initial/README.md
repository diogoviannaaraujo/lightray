# Evidências — métricas e teclado, 29/09/2026

Relatório: [implementação e validação](../../client-ux-progress.md).
Referência: [investigação do Parsec](../../../reviews/parsec-reference-2026-09-29.md).

- `client.log`: diagnósticos do cliente, incluindo decode e espera na fila em ms.
- `host-result.json`, `host.log`, `frame-timings.csv` e `launch.json`: resultado e configuração da rodada `desktop-018`.
- `test-window.json`: texto conhecido restaurado, contadores de copiar/colar e clique, sem texto arbitrário ou conteúdo de clipboard.
- `ui-observations.json`: registro das verificações pela interface e das leituras intermediárias do resultado Windows; não é um teste automatizado reproduzível sozinho.
- `cleanup.json`: processos, tarefas, endpoint UDP e regra de firewall temporária removidos.
- `mac-tests.log`, `python-tests.log`, `mac-build.log`, `windows-build.log`: verificações de regressão e compilação.
- `source-manifest.json`: hashes das fontes e dos executáveis usados, para rastreabilidade.
- `sources.json`: páginas oficiais utilizadas na comparação, com os tópicos que sustentam.

Logs originalmente UTF-16 foram normalizados para UTF-8.
Não estão incluídos workers, pareamento, clipboard, chaves ou screenshots de aplicativos pessoais.

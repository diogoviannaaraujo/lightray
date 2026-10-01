# Evidência da tentativa 4K90 — 29/09/2026

Conclusões, limitações e estado da recuperação: [relatório](../../host-4k90-progress.md).

- `desktop-006/`, `desktop-007/`, `desktop-016/` e `desktop-017/`: resultados do host, CSV de tempos, logs do cliente, configuração e hashes dos binários; a primeira rodada inclui amostra NVIDIA.
- `desktop-009/` e `desktop-010/`: modos enumerados e códigos de falha ao tentar 144/120 Hz.
- `desktop-011/` a `desktop-014/`: falhas posteriores de criação da captura; `desktop-014/cleanup.json` registra a limpeza antes da recuperação.
- `desktop-015/` e `desktop-016/`: captura recuperada após confirmação local do modo e sessão completa de 90 segundos; `desktop-016/cleanup.json` registra a limpeza dessa rodada.
- `desktop-017/`: origem confirmada em 160 Hz, stream 4K com alvo 90 FPS por dois minutos; `cleanup.json` registra a limpeza final.
- `display-recovery-001/`: falha ao reaplicar o modo original de 4K/60 Hz.
- `metrics.json`: agregação das amostras do cliente e CSVs; cadência por diferença de timestamps, sem estimar latência óptica.
- `client-decoded-3840x2160.png`: imagem da cena própria decodificada pelo cliente; resolução conferida no cabeçalho PNG.
- `mac-tests.log`, `python-tests.log`, `mac-build.log` e `windows-build.log`: validações de regressão e compilação.
- `source-manifest.json`: hashes das fontes no estado final desta tentativa, posterior às rodadas com imagem.

Seleção explícita de evidências, sem arquivos de pareamento, workers ou chaves.
Logs PowerShell originalmente UTF-16 foram normalizados para UTF-8, sem alterar seu conteúdo textual.
Os endereços presentes são da LAN do laboratório.

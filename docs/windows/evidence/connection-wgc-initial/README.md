# Evidências de conexão gráfica e captura WGC

Campanhas de 01/10/2026 descritas no [relatório do incremento](../../connection-capture-progress-2026-10-01.md).

- `capture-001/002`: DXGI sem frames; a segunda rodada inclui produtor animado conhecido e contadores Win32.
- `capture-003`: WGC em D3D11 por hardware na RTX 4090, sem salvar pixels e sem input.
- `desktop-028`: vídeo e entrada reais em duas sessões pela UI; perda injetada terminou com `0xc0000005`, sem `result.json` normal e com uma linha CSV parcial preservada.
- `desktop-029`: apartamento COM mantido entre recriações; três recuperações, quatro épocas/IDRs e encerramento normal em 1080p30.
- `desktop-030`: 4K com alvo de 90 FPS, origem/monitor cliente a 60 Hz; 80–90 FPS decodificados, três descartes de fila e 142 ajustes de cadência no host.
- `ui/`: launcher final, porta inválida, timeout, painel completo, entrada Windows real e retorno à lista; nenhuma aplicação pessoal foi capturada nessas imagens selecionadas.
- `f01-f02-analysis.json`: métricas derivadas de CSV/log, incluindo aquecimento, população dos percentis e linha inválida excluída apenas da análise numérica da campanha com crash.
- `source-manifest.json`: fontes finais, base Git e hash do cliente de laboratório; o build das campanhas está identificado em cada `launch.json`.
- `MANIFEST.sha256`: integridade dos arquivos desta pasta, exceto o manifesto.

Logs PowerShell podem estar em UTF-16LE; preservar a codificação original ao conferir o hash.
O catálogo real e as preferências foram desativados na UI de laboratório; testes de persistência usam domínios isolados.
Pairing, configuração SSH e arquivos de trabalho privados não estão incluídos.
Contadores de FPS representam decode; não houve instrumento de apresentação física, input→photon, benchmark do Parsec ou soak.

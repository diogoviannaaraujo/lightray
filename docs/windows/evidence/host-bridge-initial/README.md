# Evidências: ponte C do host, 29/09/2026

- `source-manifest.json`: fontes de origem, cópias isoladas, dependências e hashes dos inputs no Mac.
- `experiment-inputs.json`: hashes dos scripts/ponte/harness e dos seis arquivos de payload/config NVENC efetivamente usados.
- `cross-platform-input-comparison.json`: igualdade dos fontes entre plataformas; registra CRLF versus LF como única diferença do JSON de vetores públicos.
- `mac/debug-tests.log`: rodada final de 88 testes aprovados.
- `mac/initial-compile-failure.log`: falha inicial de compilação do fixture por label ausente, corrigida antes da validação final.
- `mac/result.json`: gate de quantidade de testes e identificação da execução local.
- `mac/python-tests.log`: 25 testes do harness aprovados.
- `mac/docs-check.log`: 15 blocos verificados, zero problemas.
- `windows/debug-tests.log`, `windows/release-tests.log`: rodadas finais, 88 testes cada; Release usa motor `native` depreciado.
- `windows/*-validation-*/result.json`: gates preservados, incluindo rodadas iniciais de 87 e finais de 88 testes; conferir timestamp e mínimo exigido no arquivo.
- `windows/pipeline-final.log` e `.exit`: build/test/ABI final, encerrado com zero.
- `windows/abi-result.json`: seis casos do probe C anterior aprovados.
- `windows/host-abi-result.json`: 100 ciclos por quatro threads, 16 hosts, três sessões autenticadas e 360 payloads NVENC entregues integralmente.
- `windows/binary-provenance.json`: Swift x64 nativo, tamanho/hash da DLL e dos dois executáveis, zero processos de probe restantes.
- `windows/python-windows.log` e `.exit`: 25 testes do harness aprovados e exit code zero.
- `windows/initial-*` e `windows/pipeline.log`: rodada anterior de 87 testes, preservada como histórico.

O peer usa chave pública fixa de teste, relógio simulado e entrega de datagramas em memória.
Os registros NVENC vêm do ensaio `native-nvenc-003`, cujo encoding/decode já está documentado em `../host-nvenc-initial/`.
Esta etapa não mede encoding ao vivo, UDP real, captura, apresentação, FPS, latência ou vazamento de memória.
`MANIFEST.sha256` cobre os arquivos deste diretório para conferência do pacote de evidências.

# Evidências: NVENC reutilizável e integração UDP local, 29/09/2026

- `windows/native-nvenc-005/`: regressão final de 360 frames, CSVs, perfil/frames decodificados por ffprobe e proveniência do encoder.
- `windows/nvenc-component-media-hashes.json`: hashes dos bitstreams/payloads/configs dos corpus 003/004/005 e dos bitstreams das duas rodadas finais de lifecycle; caminhos originais Windows preservados.
- `verification.json`: conferência local de igualdade dos três corpus e dos fontes finais realmente compilados.
- `windows/nvenc-lifecycle-002/` e `003/`: rodadas que entregaram os 600 frames, mas falharam no limite de crescimento de memória privada com aquecimento inicial insuficiente para o ciclo completo.
- `windows/nvenc-lifecycle-004/` e `005/`: duas rodadas finais, cada uma com 30 ciclos completos de aquecimento e 100 ciclos medidos; 131 amostras de recursos preservam a fase fria.
- `windows/nvenc-lifecycle-*/native/frames.csv`: sequência de 600 frames medidos e metadados de geração/resolução/IDR.
- `windows/nvenc-lifecycle-*/ffprobe.json`: dimensão, tipo e pixel format do decode independente de cada frame medido.
- `windows/host-loopback-002/` e `003/`: integrações aprovadas; `003` é a versão final com a DLL NVENC retida durante o processo.
- `windows/host-loopback-003/live.json`: 360 frames codificados ao vivo, três sessões autenticadas e 2.179 datagramas enviados/recebidos por UDP IPv4 loopback.
- `windows/host-loopback-003/memory.json`: regressão do modo em memória na mesma build C++.
- `windows/host-loopback-003/socket-tests.json`: sete casos do adapter UDP.
- `windows/host-loopback-003/provenance.json`: hashes de DLL Swift, executável MSVC e fontes/componentes do ensaio.
- `windows/host-loopback-build-001.log`: warning de conversão de porta tratado como erro; corrigido por tipo explícito antes dos ensaios aprovados.
- `windows/nvenc-component-build-004.log`: compilação MSVC final e 14 testes de framing.
- `windows/nvenc-component-python-windows.log`: 29 testes Python finais aprovados.
- `windows/nvenc-component-cleanup.json`: zero processos de probe e zero endpoints de teste remanescentes.
- `mac/nvenc-component-baseline.log`: 25 testes do harness antes das alterações.
- `mac/nvenc-component-python-mac.log`: primeira execução dos novos testes, com fixture de reordenação que acidentalmente não alterava o valor; corrigido antes do resultado final.
- `mac/nvenc-component-python-mac-final.log`: 29 testes finais aprovados.
- `mac/nvenc-component-docs-check.log`: 15 blocos de protocolo verificados, zero problemas.

Os CSVs brutos e gates finais não escondem o crescimento frio de memória; o limite de 32 MiB só qualifica a janela medida após aquecimento completo.
O aquecimento inicial continua sendo um custo do processo que precisa de profiling, não foi declarado resolvido por manter a DLL carregada.
Os limites de recursos não foram ampliados depois das falhas.
A DLL Swift é exatamente a validada anteriormente; esta etapa não executou novamente os 88 testes Swift nem mudou seus fontes.
As comparações de bytes ligam a regressão aos corpus anteriores, mas não constituem um novo teste de decode Mac de todos os clips nesta etapa.
Bitstreams grandes ficam nos diretórios ignorados de resultados no laboratório; os hashes aqui permitem identificá-los e os runners permitem regenerar novos ensaios sem sobrescrita.
Relógio do protocolo simulado, FEC desligado, sem captura, display, input ou rede entre máquinas.

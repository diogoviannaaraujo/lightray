# Evidências do segundo incremento

- `baseline-tests.log`: 68 testes core + 7 Mac antes das alterações deste incremento.
- `memory-tests.log`: 75 core + 7 Mac após os limites de memória.
- `decode-tests.log`: 80 core + 10 Mac após integração inicial de decoder, migração e socket.
- `tests.log`: suíte final, incluindo evolução do worker e migração de IP/porta.
- `release-build.log`: build release final do host/cliente Mac.
- `thread-sanitizer.log`: nove testes direcionados com Thread Sanitizer, quatro Mac e cinco core.
- `docs-check.log`: checker de vetores, links e âncoras.
- `fec-fixture-check.log`: fixture FEC independente.
- `baseline-preservation.json`: conferência dos 73 arquivos originais.
- `lab-tests.log`: testes Python do runner.
- `software-reference/result.json`: decode completo dos três clips por FFmpeg em software; sem simulação de perda e sem medição Windows.
- `software-reference/*.framehash`: SHA-256 por frame yuv420p decodificado.
- `windows-access/result.json`: bloqueio de verificação de identidade SSH; o inventário remoto não foi executado.

Os logs Swift têm dois runners, um por target de testes; somar os totais de core e Mac.
Arquivos de resultado com `dirty: true` correspondem a modificações locais sobre a revisão base informada.
Nenhum arquivo deste diretório atesta teste de GPU, GUI ou Windows nativo.

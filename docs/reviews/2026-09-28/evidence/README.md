# Evidências da revisão de 28/09/2026

Os logs desta pasta foram obtidos no Mac descrito em [environment.txt](environment.txt).
São evidências históricas da baseline, não resultados do código corrigido; os probes devem ser executados no checkout original preservado.
Nenhum teste de desempenho Windows foi executado.
As chaves e endereços dentro do probe são fixtures sintéticas; o programa não lê pairing salvo, não abre sockets e não altera o produto.

| Arquivo | Conteúdo |
| --- | --- |
| [source-manifest.json](source-manifest.json) | SHA-256 dos 73 arquivos originais inventariados |
| [upstream-comparison.json](upstream-comparison.json) | Correspondência com o commit original no GitHub |
| [artifact-check.json](artifact-check.json) | Conferência dos 73 hashes originais e dos links locais nos quatro documentos novos |
| [macos-tests.log](macos-tests.log) | 64 testes existentes aprovados (59 core + 5 adaptadores) |
| [vector-tests.log](vector-tests.log) | 11 testes do gerador aprovados |
| [vector-check.log](vector-check.log) | 15 blocos, zero problemas |
| [release-build.log](release-build.log) | Build release aprovado |
| [probes.log](probes.log) | Cinco comportamentos da revisão reproduzidos |
| [parity-crash.log](parity-crash.log) | Falha isolada com paridade inválida, sinal 5 |
| [probes/Package.swift](probes/Package.swift) | Pacote de diagnóstico dependente do core original |

Na raiz do projeto, reproduzir os checks existentes:

```sh
swift test --package-path macos
swift test --package-path tools/vectors
swift run --package-path tools/vectors lightray-vectors check
swift build -c release --package-path macos
```

Reproduzir os diagnósticos sem crash:

```sh
swift run --package-path docs/reviews/2026-09-28/evidence/probes ReviewProbes
```

O pacote de diagnóstico inicialmente precisou declarar macOS 14 para satisfazer o deployment target de `LightrayCore`; isso foi corrigido no próprio pacote de diagnóstico.
As precondições registram o comportamento defeituoso desta baseline e devem ser substituídas pelos testes de regressão adequados quando as correções forem feitas.
Não usar a aprovação destes probes como gate de qualidade futuro: R01–R05 devem deixar de ocorrer.

O modo `--crash-parity` é deliberadamente fatal e só deve ser executado em subprocesso descartável, com core dump desativado.
O ensaio registrado teve limite de 15 segundos e retornou imediatamente com `Fatal error: Number of elements to remove should be non-negative`.
Não é necessário executá-lo novamente para ler a revisão.

O checker documental existente só percorre Markdown diretamente em `docs/`, sem recursão.
Por isso, os links locais dos documentos novos precisam de uma verificação separada.

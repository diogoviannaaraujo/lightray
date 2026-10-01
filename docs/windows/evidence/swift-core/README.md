# Evidências do experimento Swift Windows x64

- `source-manifest.json`: hashes dos 25 fontes/fixtures copiados e das cinco adaptações de import.
- `Package.resolved`: revisões exatas de Swift Crypto e Swift ASN.1.
- `experiment-inputs.json`: hashes dos scripts/fontes auxiliares finais; o preparador e os scripts evoluíram durante o ensaio.
- `mac-debug-tests.log`: 80 testes aprovados no Mac com o pacote isolado.
- `windows-initial-build.log`: primeiro build nativo, 80 testes aprovados, Release compilado e falha posterior na descoberta recursiva da DLL.
- `windows-debug-and-release-build.log`: 80 testes aprovados e build Release após corrigir a descoberta; conserva a falha posterior do chamador que ainda executava `FreeLibrary`.
- `windows-release-zero-tests.log` e `windows-release-no-strip-zero-tests.log`: motor padrão retornou exit 0 sem executar testes Release, inclusive após desabilitar dead stripping.
- `release-zero-test-gate.json`: o laboratório recusa esse resultado vazio.
- `windows-release-native-tests.log`, `windows-release-native.exit` e `release-native-gate.json`: 80 testes Release passaram com o motor `native`; seu estado depreciado permanece como risco documentado.
- `validated-build.log`, `validated-build.exit`, `debug-final-gate.json` e `release-final-gate.json`: script completo após as correções, com 80 testes por configuração, build MSVC, seis casos ABI e exit 0.
- `abi-before-unload.json` e `abi-unload-timeout.log`: os seis casos passavam antes do travamento ao descarregar a DLL; isso sozinho não foi considerado um run aprovado.
- `abi-final.json` e `abi-final.log`: chamada corrigida, com a DLL mantida até o encerramento do processo.
- `portable-manifest.json`: 20 arquivos do pacote experimental com hashes/tamanhos e dependências do sistema.
- `portable-abi.json`, `portable-abi.log` e `portable.exit`: seis casos aprovados e processo encerrado com código zero, sem o toolchain no PATH.
- `mac-lab-tests.log` e `windows-lab-tests.log`: 17 testes do laboratório aprovados nos dois sistemas, incluindo recusa de zero testes com exit 0.

Não foram copiados executáveis, DLLs ou dependências de terceiros para este diretório.
Eles permanecem no laboratório Windows, em `tools/windows/results/swift-core-001/portable-003`, repetido após o último rebuild da DLL.
Os logs nativos preservam as falhas encontradas, em vez de apresentar somente os resultados corrigidos.
Os testes de rede do core usam simulador; não houve sessão UDP real entre Mac e Windows neste experimento.

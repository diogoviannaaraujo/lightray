# Verificações antes da publicação

Execução de 01/10/2026, após organizar a documentação do pull request, em macOS 26.6.1 com Swift 6.4.
O código parte de `5002116872492da705aa6252f26482b02e3df5b5`; a adaptação ao renderer/requisito macOS 27 de `5ef9685` não foi executada ou validada nesta rodada.

- `pr-swift-tests-final.log`: 33 casos Mac e 83 core aprovados, total de 116; os resumos XCTest com zero casos não substituem os resultados de Swift Testing.
- `pr-python-tests-final.log`: 31 casos aprovados.
- `pr-release-build.log`: build Release completo do pacote, incluindo cliente e host Mac, sem abertura dos aplicativos.
- `pr-document-validation.json`: links relativos conferidos e sete manifestos de evidências/relatórios verificados, sem erro de digest; a conferência precede a inclusão desta pasta.
- `checks.json`: resumo e distinção entre esta execução local e os resultados nativos/GPU anteriores.
- `MANIFEST.sha256`: integridade dos arquivos desta pasta, exceto o manifesto.

Os testes de 39 componentes nativos Windows e os ensaios GPU/desktop pertencem às campanhas anteriores registradas nas demais evidências.
Nenhum teste de foco, captura, input remoto, GPU ou modo de tela foi iniciado como efeito colateral da publicação.

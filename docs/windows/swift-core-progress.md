# Experimento A: core Swift em Windows x64 — 28/09/2026

Os 80 testes existentes do core passaram nativamente em Windows x64, em Debug e Release, com Swift 6.4 e Swift Crypto 5.0.0/BoringSSL.
Uma cópia isolada dos mesmos fontes também passou pelos 80 testes no Mac.
O experimento mantém o modelo sans-I/O: não foi acrescentado socket, renderizador, captura ou input de plataforma ao core.

## Escopo e dependências

O [preparador](../../tools/windows/prepare-swift-core.py) copia os fontes/testes para `tools/windows/results/swift-core-001` e adapta cinco imports de `CryptoKit` para `Crypto`, sem alterar os fontes de produção.
Isso inclui quatro arquivos do core e o teste dos vetores criptográficos.
As fixtures FEC e os vetores públicos do protocolo são copiados; hashes de origem e das cópias ficam no [manifesto de fontes](evidence/swift-core/source-manifest.json).

| Dependência | Versão/revisão do experimento |
| --- | --- |
| Windows | 11 Home x64, build 26200 |
| Swift | 6.4, target `x86_64-unknown-windows-msvc`, distribuição oficial com assertions |
| MSVC | Visual Studio Build Tools 2022, tools 14.44.35207 |
| SDK | Windows SDK 10.0.26100.0 |
| Swift Crypto | 5.0.0, `a9d1d5ab8951ada40cafff8c8e2b551dfde4f390` |
| Swift ASN.1 | 1.7.3, `3b6410f7dee09eb33cdd26260c5fd47fda19b0e2` |

O Swift foi instalado pelo canal oficial `Swift.Toolchain`, em escopo de usuário, com modo silencioso e reinício suprimido.
O instalador também instalou Python 3.10.11 como dependência; a versão previamente disponível era Python 3.12.
Os hashes de download foram verificados pelo winget.
Não foram alterados drivers, firewall ou sessão de desktop.
As dependências seguem a [orientação oficial de instalação](https://www.swift.org/install/windows/manual/); a cadeia fica fixada no [Package.resolved](evidence/swift-core/Package.resolved).

## O que os testes demonstram

- Handshake e tráfego protegido correspondem aos vetores do projeto; autenticação adulterada é recusada.
- FEC, reassembly, limites de memória, fila de decode, replay, rebinding, reconexão, NACK e retransmissão mantêm os contratos da referência.
- Os testes de sessão incluem perda e stalls em simulador; não equivalem a tráfego UDP Mac→Windows real.
- O caminho Windows compila BoringSSL; o resultado Mac sozinho não bastaria, pois Swift Crypto usa CryptoKit em plataformas Apple.
- A biblioteca dinâmica também foi compilada em Release no Windows.

Um executável MSVC C++20, compilado com `/W4 /WX /O2`, carregou a DLL Release e passou por [seis casos da fronteira C](evidence/swift-core/abi-final.json): pacote autenticado, tag adulterada, ponteiro nulo, pacote truncado, chave curta e saída insuficiente.
O export usa `@_cdecl` e buffers emprestados durante a chamada; não é ainda a ABI completa de sessões.

O [empacotador experimental](../../tools/windows/package-swift-core-probe.ps1) inspeciona dependências com `dumpbin`, copia transitivamente os runtimes necessários e executa com PATH restrito à pasta do pacote e ao Windows.
Foram 20 arquivos, totalizando 76.071.720 bytes (72,55 MiB), incluindo o executável, a DLL do core e os runtimes locais; hashes e dependências de sistema estão no [manifesto portátil](evidence/swift-core/portable-manifest.json).
Os mesmos [seis casos passaram](evidence/swift-core/portable-abi.json), com [código de saída zero](evidence/swift-core/portable.exit).
Esse ensaio elimina a dependência do PATH do toolchain nessa execução; não substitui um teste em Windows limpo sem ferramentas de desenvolvimento instaladas.
Licenças, assinatura, instalador e atualização dos runtimes permanecem pendentes.

## Problemas do laboratório e correções

Uma tentativa inicial de destacar o instalador do processo SSH foi encerrada com a sessão, antes de produzir resultado de instalação.
A instalação em primeiro plano, mantendo a sessão SSH viva, terminou com código zero.
O runner de build aplica a mesma regra para não deixar o resultado depender de processos destacados.

O build Release terminou, mas a primeira busca recursiva pela DLL falhou em caminhos intermediários do SwiftPM/PowerShell 5.1.
O layout nesta versão é `.build/out/Products/Release-windows-x86_64`, diferente da suposição inicial de uma pasta `release`.
Os scripts agora consultam `swift build --show-bin-path` e verificam o arquivo esperado diretamente.

**Descarregamento da DLL:** a primeira versão do chamador executou os seis casos, mas ficou presa em `FreeLibrary`.
O [log com checkpoints](evidence/swift-core/abi-unload-timeout.log) localizou a espera após o retorno correto do vetor; a execução instrumentada foi encerrada pelo timeout de 30 segundos.
Retirar o descarregamento explícito e manter o módulo durante toda a vida do processo permitiu encerrar normalmente, inclusive com runtimes locais.
Essa é uma restrição observada do experimento, não uma demonstração de que toda DLL Swift tenha o mesmo comportamento.
O cliente deverá liberar recursos de sessão por APIs explícitas e manter a biblioteca carregada até terminar; hot reload/unload do core não está homologado.
Os scripts limitam a execução do chamador a 30 segundos e falham se o processo exceder esse prazo.

**Descoberta de testes Release:** o motor padrão `swiftbuild` retornou zero mesmo executando zero testes em Release.
Repetir com `--disable-dead-strip` não corrigiu a descoberta.
Isso não foi aceito como aprovação: `verify-swift-tests` agora exige saída zero e pelo menos 80 testes reportados como aprovados.
O controle negativo conserva o [log](evidence/swift-core/windows-release-zero-tests.log) e o [resultado recusado pelo gate](evidence/swift-core/release-zero-test-gate.json).
Com `--build-system native`, os [80 testes passaram em Release](evidence/swift-core/windows-release-native-tests.log), e o [gate confirmou a contagem](evidence/swift-core/release-native-gate.json).
Esse contraste delimita uma diferença entre os caminhos de build/teste neste ambiente; não identifica sozinho a causa interna no SwiftPM, linker ou framework de testes.
O script usa `swiftbuild` para Debug e para a DLL Release testada pelo C++, e o motor `native` para a suíte Release.
O próprio CLI marca `native` como depreciado: é um contorno de laboratório com dívida explícita, que precisa ser eliminado ou fixado por versão antes de fechar a arquitetura/CI de longo prazo.

Depois das correções, o [script completo](evidence/swift-core/validated-build.log) terminou com [exit 0](evidence/swift-core/validated-build.exit): gate Debug com 80 testes, gate Release com 80 testes, DLL Release, build MSVC com warnings como erro e seis casos ABI.
Os 17 testes Python do laboratório passaram nos dois sistemas; o checker documental conferiu 15 blocos sem problemas.
Ao concluir este experimento, o digest dos arquivos de implementação selecionados foi conferido como idêntico no Mac e no Windows, conforme [experiment-inputs.json](evidence/swift-core/experiment-inputs.json).

## Decisão provisória e trabalho restante

A reutilização do core Swift em Windows x64 é uma candidata viável com evidência de testes, fronteira C e runtimes locais, sem necessidade demonstrada de reescrever toda a sessão em C++.
Isso ainda não encerra E03: faltam contrato de ABI/ownership, distribuição e licenças dos runtimes, ciclo de vida sob concorrência real, transporte Winsock e integração de mídia/apresentação.
Também falta resolver de forma sustentável a descoberta Release no motor padrão; um pipeline verde com zero testes é um bloqueio de qualidade.
O experimento C++ mínimo deve comparar os riscos que restarem, sem duplicar todo o core por antecipação.
O suporte documentado de [Swift Crypto](https://github.com/apple/swift-crypto) menciona Windows ARM64; a execução x64 deste laboratório não amplia por si só a matriz oficial de suporte do fornecedor.
É necessário fixar toolchain/dependências, manter CI Windows e explicitar gatilhos de migração se atualizações quebrarem o x64.

O próximo incremento deverá estabilizar a fronteira nativa e preparar o teste de apresentação.
Não é necessária ação do usuário para continuar testes sem interface; abrir janela e testar foco/input continua condicionado à combinação prévia solicitada pelo usuário.

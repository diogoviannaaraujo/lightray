# Primeira validação nativa Windows — 28/09/2026

Continuação: [decode efetivo 1440p/4K nos três backends](resolution-validation-progress.md).
Este relatório preserva o escopo e o estado do primeiro ensaio de 1080p.

O acesso ao Windows foi desbloqueado após o usuário conferir localmente a impressão digital pública do servidor SSH.
A chave conferida foi registrada somente no arquivo de confiança exclusivo do laboratório, ignorado pelo Git; não foram alteradas as configurações SSH globais.
O usuário liberou testes de GPU e pediu combinação prévia para testes que usem tela/foco.
Todas as execuções deste incremento foram sem interface gráfica, por SSH; nenhuma janela foi aberta e nenhum input foi injetado.

## Ambiente confirmado

| Componente | Resultado |
| --- | --- |
| Sistema | Windows 11 Home x64, build 26200 |
| CPU/RAM | Core i7-12700KF, 12 cores/20 threads, aproximadamente 64 GiB de RAM |
| GPU | RTX 4090, 24.564 MiB reportados pelo NVIDIA, driver 591.86 |
| Rede física | Ethernet Realtek ativa a 1 Gbps; Wi-Fi desconectado |
| Tailscale | Três discovery pings diretos de 1 ms; não são medida do UDP Lightray |
| Sessão | SSH não interativo, session ID 0; tela reportada nessa sessão não representa o console físico |
| Compilador | Visual Studio Build Tools 17.14.37614.0; MSVC tools 14.44.35207, compilador `_MSC_FULL_VER=194435228` |
| SDK | Windows SDK 10.0.26100.0 |
| Build auxiliares | CMake 3.31.6-msvc6 e Ninja 1.12.1 encontrados dentro do Visual Studio, apesar de não estarem no PATH inicial |
| Mídia | FFmpeg/ffprobe 8.1 já instalados; `HEVCVideoExtension` ativável e D3D11-aware |
| Swift | Não encontrado no PATH; experimento do core Swift ainda não executado |

Foi criado um checkout isolado em `%LOCALAPPDATA%\LightrayLab\client-probe-20260928\repo`, na revisão auditada, com overlay dos fontes e fixtures necessários aos ensaios.
O diretório contém somente material deste projeto e resultados dos probes; nenhum serviço, driver, plano de energia ou regra de firewall foi alterado.
Os resultados registram SHA base, dirty flag e digest dos arquivos selecionados; cada run preserva o código efetivamente usado naquele momento.

## Código executado e resultados

Foram compilados dois probes C++20 x64 com `/W4 /WX /O2`, usando as bibliotecas do SDK instalado:

- [Descoberta de plataforma](../../tools/windows/src/platform_probe.cpp): device D3D11, adapters, perfis/configurações de vídeo e ativação de decoder Media Foundation.
- [Decode Media Foundation](../../tools/windows/src/mf_decode_probe.cpp): Source Reader, samples em GPU, leitura NV12, recorte da área visível e hashes de pixels.

A RTX anunciou profile HEVC Main e duas configurações para cada dimensão consultada: 1920×1080, 2560×1440 e 3840×2160.
Somente 1920×1080 foi efetivamente decodificado neste incremento; não confundir essa consulta com teste de 1440p/4K.
DXGI enumerou duas entradas com o nome RTX 4090 e uma entrada de software; foi selecionado explicitamente o índice 0, com vendor/device conferidos também no log FFmpeg.
Isso não demonstra a presença de duas GPUs físicas.

| Caminho Windows | Clips | Frames decodificados | Diferenças de pixels contra o Mac | Evidência |
| --- | --- | --- | --- | --- |
| FFmpeg software | 3 | 360 | 0 | [Comparação](evidence/native-initial/comparison-software/result.json) |
| FFmpeg D3D11VA / RTX 4090 | 3 | 360 | 0 | [Comparação](evidence/native-initial/comparison-d3d11va/result.json) |
| Media Foundation / D3D11 / RTX 4090 | 3 | 360 | 0 | [Comparação](evidence/native-initial/comparison-media-foundation/result.json) |

Foram 1.080 decodificações de frames no Windows, usando os mesmos 360 frames do corpus em três caminhos.
A referência Mac foi gerada com FFmpeg 8.0.1; os hashes correspondem a pixels yuv420p em ordem, sem exigir igualdade dos headers/timestamps dos arquivos `.framehash`.
Nos testes D3D11VA o grafo operou com frames `d3d11` e download explícito; no probe Media Foundation todos os samples precisaram expor `IMFDXGIBuffer`.
Os resultados não dependem apenas do nome de uma opção `hardware`.

## Problemas encontrados e corrigidos durante os ensaios

**Superfície maior que a imagem visível:** Media Foundation entregou superfícies de 1920×1088 para o conteúdo 1920×1080.
O probe passou a usar a abertura de exibição válida e o pitch da superfície antes de converter NV12 em planos Y/U/V; depois disso, os três clips produziram pixels idênticos à referência.
Essa distinção consta da [documentação Microsoft sobre display aperture](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-mt-minimum-display-aperture-attribute) e precisa permanecer no decoder final.
Oito testes nativos de geometria passaram, incluindo tamanho alinhado, recorte válido, offsets inválidos, fração, dimensões vazias e ultrapassagem da superfície.

**Seleção inválida de adapter:** no controle negativo, o FFmpeg aceitou índice 15 e decodificou pelo device padrão.
O runner agora enumera DXGI antes de executar e recusa índice inexistente, adapter de software, falha de device ou ausência de HEVC Main.
Após a correção, índice 15 retornou falha e índice 0 continuou passando nos dois backends de GPU.
O log conserva a primeira observação e o resultado corrigido.

**Inventário PowerShell 5.1:** a enumeração do Visual Studio precisava expandir o array de `ConvertFrom-Json` antes de selecionar propriedades.
A coleta corrigida passou a registrar versão, completude e disponibilidade da instalação.

## Verificações e limites

- Treze testes Python do laboratório aprovados tanto no Mac quanto no Windows, incluindo comparador, integridade de artefatos, arquivo de confiança SSH, plataforma e seleção de adapter.
- Oito casos nativos de geometria aprovados; arquivo de entrada inexistente retorna exit 1; adapter inexistente retorna exit 2 no runner.
- Builds C++ com warnings tratados como erro aprovados no MSVC instalado.
- Corpus integral validado por checksum antes de decodificar; resultados e logs selecionados preservados no [índice de evidências](evidence/native-initial/README.md).
- Nenhuma alteração no core Swift neste incremento; os 90 testes da etapa anterior continuam sendo a evidência desse código, sem rerun desnecessário para mudanças exclusivas de laboratório.

Os probes ainda fazem cópia GPU→CPU e, no caso Media Foundation, alocam staging por frame para conferir pixels.
Esse caminho não é o renderizador final nem um benchmark equivalente de latência entre backends.
Os percentis `ReadSample` incluem demux/espera e não incluem download/hashing; não foram usados para anunciar latência de apresentação ou input→photon.
Os clips foram lidos completos, sem injetar perda; cenários LTR do corpus de pesquisa não ampliam o contrato implementado de PREVIOUS/IDR.

A existência de HEVC Media Foundation nesta máquina não demonstra disponibilidade em Windows N ou instalações sem a extensão.
O FFmpeg instalado foi usado como ferramenta de laboratório; empacotamento, licença e escolha de build redistribuível continuam pendentes.
A documentação atual de [Swift Crypto](https://github.com/apple/swift-crypto) menciona Windows ARM64; reutilização em x64 precisa de experimento e avaliação de manutenção antes de ser adotada.
Ainda não há decisão final de core ou backend.

## Próximos passos e participação do usuário

O bloqueio SSH foi resolvido; não é necessária nova informação do usuário para continuar inventário técnico, compilação, testes de core e ensaios de GPU sem interface.
Faltam concluir os experimentos A/B do core, ampliar o corpus para 1440p/4K, exercitar indisponibilidade do decoder/fallback, medir spans e filas equivalentes e preparar a apresentação D3D11.
Quando houver um executável de apresentação pronto para teste, combinar previamente a janela de uso da sessão Windows para abrir janela, medir apresentação e testar foco/input.
E01/E03 seguem parcialmente concluídas; os gates de GUI, interoperabilidade de sessão, desempenho, estabilidade e distribuição permanecem abertos.

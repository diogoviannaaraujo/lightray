# Conexão gráfica e captura Windows Graphics Capture

Atualização de 01/10/2026, incrementos F01/F02 da [matriz de evolução](../reviews/parsec-parity-2026-10-01.md).
Escopo: cliente Mac → host Windows nativo com RTX 4090 e HEVC/NVENC.
As alterações permanecem locais na branch `codex/windows-foundation`, sobre `5002116872492da705aa6252f26482b02e3df5b5`, sem commit ou PR publicado.

## Resultado

O cliente Mac voltou a visualizar e controlar a janela real do Windows pelo caminho Windows Graphics Capture → D3D11 BGRA/NV12 → NVENC → UDP autenticado → VideoToolbox.
Não há WSL, FFmpeg ou encoder de software nesse caminho.
A nova interface abre a lista de computadores, seleciona o monitor local, conecta, desconecta e inicia outra sessão sem reiniciar o aplicativo.
A rodada em 4K com alvo de 90 FPS recebeu vídeo, mas ainda não atingiu estabilidade ou apresentação física certificada a 90 FPS.
O backend WGC é uma opção explícita de laboratório; DXGI continua como padrão e a causa de sua ausência de frames permanece aberta.

## F01: diagnóstico, backend e recuperação

`capture-001` criou device e duplicação DXGI com sucesso na RTX 4090, na sessão de console 1, em WinSta0/Default, com composição DWM habilitada.
Nenhum frame chegou em cinco segundos; o device não reportou remoção.
`capture-002` repetiu DXGI com a janela própria animada: 692 repinturas reportadas, 227 timeouts de aquisição e zero frames.
O resultado localiza o impedimento antes de NVENC, transporte e decoder, sem estabelecer sua causa.
A documentação da Microsoft descreve timeout normal quando não há atualização; a janela animada foi usada para testar um produtor conhecido, mantendo a distinção entre repintura Win32 e apresentação efetiva do compositor. [AcquireNextFrame](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgioutputduplication-acquirenextframe).

`capture-003` usou Windows Graphics Capture no mesmo output e adapter: suporte disponível, device NVIDIA por hardware, 20 texturas 3840×2160 em cinco segundos e nenhuma mudança de dimensão ou remoção de device.
O probe conta frames e descreve texturas; não salva pixels nem injeta entrada.
O caminho utiliza criação direta para o monitor, pool independente de DispatcherQueue com dois buffers e interoperabilidade com o D3D11 device do encoder. [CreateForMonitor](https://learn.microsoft.com/en-us/windows/win32/api/windows.graphics.capture.interop/nf-windows-graphics-capture-interop-igraphicscaptureiteminterop-createformonitor), [CreateFreeThreaded](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.direct3d11captureframepool.createfreethreaded?view=winrt-26100), [interop D3D11](https://learn.microsoft.com/en-us/windows/win32/api/windows.graphics.directx.direct3d11.interop/nf-windows-graphics-directx-direct3d11-interop-createdirect3d11devicefromdxgidevice).
O indicador de captura e o cursor padrão da plataforma foram preservados.
O host conserva no máximo dois buffers de captura e usa o frame mais recente disponível para a conversão; reutiliza a superfície NV12 quando a origem não atualiza.

A primeira integração, `desktop-028`, entregou vídeo e input, mas o teste de recriação terminou com código `0xc0000005`, sem relatório final normal e com uma linha CSV truncada.
O ciclo encerrava e reinicializava o apartamento COM entre sessões WGC; a implementação passou a manter esse apartamento durante toda a vida de `DesktopCapture`, inclusive até a destruição dos objetos COM.
Na rodada posterior, `desktop-029`, três perdas injetadas da sessão de captura recuperaram sem nova falha: 165,864 ms, 198,577 ms e 165,483 ms até aquisição.
Cada nova época começou com um IDR configurado; houve uma sessão autenticada, 2.823 frames, quatro épocas/IDRs, três recriações e três recuperações.
O resultado terminou normalmente, sem falha de input ou tecla/botão retido.
Essa comparação sustenta a correção do ciclo exercitado; não houve dump/depuração de stack nem homologação de todas as causas possíveis de falha nativa.
O teste libera e recria o objeto real da API; não simula troca real de usuário, bloqueio, perda de device, hot-plug ou alteração de geometria.

O anúncio do display agora contém dimensão física e frequência obtida do backend, em vez de dimensão reduzida do stream e 30 Hz fixos.
Na campanha 4K, o cliente recebeu `native=3840x2160 refresh_millihertz=60000`.
O helper de metadados tem oito casos de teste, incluindo 160 Hz e a razão fracionária 60000/1001.
WGC consulta a frequência inteira do modo Windows atual; DXGI conserva a razão fornecida pela API.
A resolução do stream permanece separada da dimensão física, preservando o mapeamento de coordenadas de entrada.

## F02: experiência de conexão

- Sem endereço na CLI, o cliente abre a janela Computadores; `--launcher` permite abrir essa janela com parâmetros iniciais.
- A interface inclui nome/endereço, lista de computadores salvos, importação de pareamento, seleção de monitor local e conectar/desconectar.
- O catálogo guarda somente metadados públicos, com versão, limite de 32 computadores e limite de 64 KiB antes do decode; os arquivos de pareamento usam o armazenamento privado existente e permissão 0600.
- Nomes dos arquivos privados são derivados do identificador público de pareamento e validados antes de acesso, impedindo uso de caminho arbitrário nesse novo fluxo.
- O monitor é lembrado por UUID; a lista é atualizada ao voltar à janela e antes de conectar, com fallback explicado quando o monitor anterior desaparece.
- Porta/endereço inválidos recebem orientação específica; não há indicador fictício de disponibilidade.
- Sem autenticação após 12 segundos, o cliente encerra a tentativa e volta à lista, com indicação para conferir host, rede e pareamento.
- Desconectar pelo painel, pelo menu da aplicação ou ao fechar o último stream cancela timer/socket, invalida decoders, libera input e volta à lista no modo gráfico.
- A CLI de conexão direta continua disponível e fecha o aplicativo ao encerrar sua última janela.
- Importar/lembrar/esquecer e manipular o clipboard do campo são ações locais da janela, separadas da entrada encaminhada ao Windows.

O catálogo e seus casos de corrupção/versão/limite foram testados em suítes isoladas de UserDefaults.
A UI real foi executada com `--no-host-catalog --no-preferences`, preservando os dados já salvos do usuário.
A gravação/importação/esquecimento de um pareamento de produto pela UI não foi exercitada no perfil real; exige teste de onboarding em perfil descartável.
Preferências e telas permanecem em inglês; localização PT-BR/EN, navegação completa por teclado e auditoria de acessibilidade continuam pendentes.
O resolvedor DNS ainda pode bloquear a thread principal durante a resolução; o prazo de 12 segundos cobre a tentativa de transporte após esse estágio e não é uma garantia de duração máxima para DNS.
IPv6 global é aceito pelo parser; endereços com zona IPv6 ainda dependem de transporte com scope ID e não foram validados em rede.

## Validação real no Samsung

A interface foi inspecionada no Samsung U28E590, display ID 4, máximo reportado de 60 FPS.
A rodada `desktop-028` começou pela janela Computadores e voltou a receber vídeo após desconectar e reconectar pelo painel, com duas sessões registradas pelo host.
A janela própria Windows confirmou texto esperado, um clique, uma rolagem, dois Ctrl+A, um Ctrl+C e um Ctrl+V.
O host registrou 117 eventos de input e zero teclas/botões retidos nas amostras antes da falha de captura.
Ctrl+C/Ctrl+V foram exercitados dentro do Windows; transferência de texto Mac↔Windows permanece ausente.
O painel libera entrada ao abrir, permanece totalmente dentro da janela e oferece desconexão também sem imagem.
Os botões remotos ficam indisponíveis sem vídeo ativo.
Alt+Tab e tecla Windows continuam com testes anteriores de entrada e testes automatizados, mas seus novos botões ainda não receberam aceite visual de efeito remoto nesta campanha.

## Desempenho e regressões

| Verificação | Resultado desta atualização |
| --- | --- |
| Baseline | 111 testes Swift e 31 Python aprovados |
| Resultado local | 116 Swift: 83 core + 33 Mac; 31 Python aprovados |
| Build Mac | Release e assinatura ad hoc verificados; não é build notarizado |
| Build Windows | MSVC `/W4 /WX /O2`; 12 casos de recuperação, 19 de input e 8 de metadados aprovados |
| WGC 1080p30 (`desktop-029`) | 2.823 frames; 18 amostras de cliente com 25–31 FPS, incluindo janelas de recuperação; RTT 3,1–10,0 ms |
| WGC 4K, alvo 90 (`desktop-030`) | 3.579 frames; 8 amostras de cliente com 80–90 FPS; RTT 4,5–6,5 ms |
| Primeiro decode após autenticação, 4K | 124,040 ms com host já preparado; não é conexão fria nem apresentação física |
| Contadores do receptor, 4K | Zero perda reportada; três descartes acumulados de fila de decode; zero erros de envio/recepção |
| Cadência do host, 4K | 142 ajustes/descartes do contador `skipped`; 2.420 superfícies novas e 1.159 reutilizadas (32,4%) |
| GPU, 4K | Cinco amostras globais NVIDIA: encoder 36–38%, GPU 30–49%; não há atribuição exclusiva por processo |
| Limpeza | Zero processos Mac/Windows de laboratório, tarefas temporárias, listeners UDP 37373 e regras temporárias Windows |

A rodada `desktop-029` manteve o host por 100 segundos e o cliente por 100 segundos, incluindo a inicialização, e terminou normalmente.
A rodada `desktop-030` manteve o host por 100 segundos; a conexão do cliente começou com o host já preparado e recebeu aproximadamente 42 segundos de vídeo antes do encerramento programado do host.
O cliente encerrou após 60 segundos totais; sua reconexão após o fechamento programado não representa falha inesperada da captura.
Não houve injeção artificial de perda nessas campanhas.

As distribuições abaixo vêm do CSV nativo completo, excluindo os primeiros dez segundos a partir do primeiro frame capturado e usando percentil por nearest rank.

| Rodada / amostras após aquecimento | Capture/convert p50 / p95 / p99 | Encode p50 / p95 / p99 |
| --- | --- | --- |
| 1080p30 / 2.523 frames | 0,183 / 0,402 / 1,011 ms | 4,916 / 12,137 / 13,068 ms |
| 4K, alvo 90 / 2.741 frames | 0,126 / 0,286 / 0,604 ms | 5,586 / 8,883 / 14,973 ms |

O tempo de capture/convert inclui retorno da superfície em cache e conversão quando houver superfície nova; não mede idade do frame no produtor WGC nem latência física da tela.
O p99 de encode em 4K ultrapassa o orçamento de 11,11 ms de um frame a 90 FPS.
A origem e o Samsung reportaram 60 Hz; reutilização de superfícies e FPS decodificados não certificam 90 imagens únicas ou apresentações por segundo.
A cena própria comprime facilmente e não equivale a jogo, tela complexa ou carga de 80 Mb/s; 80 Mb/s é o alvo configurado, não a taxa efetivamente recebida.
RTT não deve ser somada como latência de uma direção nem apresentada como mouse→imagem.
Não houve benchmark A/B do aplicativo Parsec.

## Próximas entregas e critérios de aceite

1. Fechar F01: dez partidas frias, sessão contínua de dez minutos, falhas reais de desktop/device/geometria, recuperação ou erro explícito, ausência de estado de input retido e estabilidade de COM/handles/memória; manter WGC explícito até esses gates passarem.
2. Completar F02: onboarding de pareamento em perfil descartável, reconexões repetidas após host reiniciar, DNS fora da thread principal, identificadores de tela após hot-plug, acessibilidade e localização.
3. Implementar F03: clipboard Unicode por ação explícita, capacidade negociada, direção por host, limite de texto, cancelamento/geração e nenhuma gravação de conteúdo em logs; garantir peers antigos e testar emoji, acentos e reconexão.
4. Completar F04 e iniciar F05/F06: teclado ANSI/ISO/ABNT2 e AltGr, hotkeys configuráveis, mouse relativo/confinamento com saída local e áudio Windows→Mac com buffers limitados.
5. Executar F07/F08/F10/F11: renegociação de qualidade com confirmação/rollback, controle adaptativo de bitrate, instrumentação da apresentação, gráficos e exportação revisável; para 90 FPS físicos, usar a tela integrada adequada e uma origem com frequência suficiente.
6. Prosseguir F09/F12/F13 e depois F14–F18: múltiplos outputs Windows, gamepad, host/tray/instalação, display virtual, cor, permissões/convidados e periféricos, com os gates detalhados na matriz.

## Reprodução e evidência

As [evidências selecionadas](evidence/connection-wgc-initial/README.md) preservam campanhas bem-sucedidas e a falha nativa, CSVs, logs, screenshots somente do aplicativo/janela de teste, hashes e limites.
O core/ABI não mudou neste incremento; o laboratório continua usando explicitamente a DLL `swift-core-003` compatível com a telemetria.
Reconstruir o host com `tools/windows/build-desktop-host.ps1` antes de usar o runner atualizado.
Para diagnóstico isolado, executar `run-capture-probe.ps1 -DesktopApproved -Run capture-NNN -Motion -Backend wgc`, escolhendo um identificador novo.
Para o host, acrescentar `-CaptureBackend wgc` a `start-desktop-host-test.ps1`; o parâmetro é explícito e não troca automaticamente após uma falha de DXGI.
Manter os demais argumentos, o pareamento privado, bind/peer e firewall restrito conforme o [fluxo do laboratório](../../tools/windows/README.md).
Não alterar refresh, topologia, driver ou aplicativos de terceiros para reproduzir esta campanha.

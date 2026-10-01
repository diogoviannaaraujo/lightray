# Lightray e Parsec — lacunas de produto e próximos incrementos

Revisão de 01/10/2026 baseada no código local e na documentação oficial consultada nesta data.
Escopo principal: cliente Mac → host Windows com NVIDIA NVENC.
Não houve execução do aplicativo Parsec, comparação visual lado a lado ou benchmark A/B nesta revisão.
As prioridades e os critérios abaixo são decisões propostas para o Lightray.
Este complemento detalha o [plano de produto](../windows/product-validation-plan-2026-10-01.md) e preserva a [investigação inicial](parsec-reference-2026-09-29.md).

## Conclusão

O projeto possui fundamentos de vídeo, transporte autenticado, métricas e entrada remota, mas ainda precisa completar a experiência cotidiana de conexão, áudio, texto, jogos, monitores e recuperação.
O menu de sessão implementado aproxima uma parte do fluxo de uso; ele ainda não corresponde a equivalência funcional ou de desempenho.
A atualização [F01/F02](../windows/connection-capture-progress-2026-10-01.md) restabeleceu primeiro frame/input pelo backend WGC explícito e acrescentou conexão pela interface; estabilidade ampla e paridade completa permanecem abertas.
O conjunto de referência depende do sistema operacional, hardware e plano do Parsec, conforme sua [matriz oficial](https://support.parsec.app/hc/en-us/articles/32381463419924-Feature-Matrix).

## Matriz de incrementos

P0 representa pré-requisito funcional, P1 experiência principal de desktop/jogo e P2 expansão após essa experiência estar aprovada.
“Parcial” significa que existe código ou validação de parte do comportamento, sem aceite de toda a funcionalidade.

| ID / prioridade | Recurso | Estado observado no Lightray | Próxima entrega | Critério de aceite |
| --- | --- | --- | --- | --- |
| F01 / P0 | Inicialização e recuperação | DXGI sem frames; WGC restabeleceu vídeo/input; três perdas injetadas recuperaram após ajuste de COM; validação ampla pendente | Diagnóstico preciso, início estável, falhas reais de desktop e reconstrução do pipeline | Dez inicializações, sessão contínua, recuperação ou falha explícita; nenhuma tecla retida |
| F02 / P1 | Conexão pela interface | Computadores, catálogo público limitado, monitor por UUID, importação, prazo de conexão e retorno à lista implementados; onboarding em perfil descartável pendente | Tela de computadores pareados, disponibilidade, conectar/desconectar/reconectar, preferências e seleção do monitor local | Uso normal sem terminal; estados e erros com ação útil; pareamento protegido |
| F03 / P1 | Clipboard entre máquinas | Ctrl+C/Ctrl+V dentro do Windows validado; transferência Mac↔Windows ausente | Texto Unicode por ação explícita; configuração de direção/permissão por host | Texto internacional, limites, cancelamento e reconexão; nenhum conteúdo em logs |
| F04 / P1 | Teclado completo | Command/Control, Alt+Tab/Windows, ISO/menu/F13–F20; texto internacional pendente | ANSI/ISO/ABNT2, acentos, cedilha, AltGr/Caps Lock, hotkeys configuráveis e modo imersivo voluntário | Texto correto, conflitos explicados, permissão negada tratada e escape local acessível |
| F05 / P1 | Mouse de jogo e cursor | Coordenadas absolutas e cursor local opcional; canal de cursor/relativo ausentes | Movimento relativo, confinamento, liberação, formas/posição do cursor remoto e escala coerente | Câmera de jogo contínua; arrastar/scroll/DPI; saída da sessão sem cursor preso |
| F06 / P1 | Áudio do host | Não implementado nos aplicativos atuais | Captura Windows, Opus, reprodução Mac, mute/volume e seleção de dispositivo | Sem estalos, buffers limitados, troca de dispositivo e sincronismo medido |
| F07 / P1 | Qualidade durante a sessão | Resolução/FPS/bitrate definidos no launcher; painel sem renegociação | Presets Desktop/Jogo e controles confirmados de bitrate/FPS/resolução/monitor | Host confirma aplicação; IDR e geração corretos; rollback; peers antigos funcionam |
| F08 / P1 | Adaptação de rede | Bitrate e FEC fixos; existem mecanismos de reparo e limites de fila | Controle adaptativo de bitrate, proteção e pacing; diagnóstico separado por rota | Banda reduzida/jitter/perda sem filas crescentes ou tempestade de IDR; retorno medido |
| F09 / P1 | Monitores Windows | Cliente/core já têm conceitos de múltiplos streams; host nativo anuncia um display e captura output 0 | Enumerar outputs, selecionar monitor, múltiplas janelas e qualidade por stream | DPI misto, offsets, retrato, hot-plug e limite global de recursos aprovados |
| F10 / P1 | Apresentação e fluidez | FPS decodificados medidos; apresentação física ainda não certificada | Instrumentação do renderer, cadência, ajuste de escala e política de sincronização | FPS apresentados e p95/p99 separados de decode; teste 4K90 em tela adequada |
| F11 / P1 | Diagnóstico no produto | Captura/encode/RTT/decode/fila no HUD; logs de laboratório | Gráficos limitados, avisos persistentes úteis, decoder/encoder real e exportação revisável | Sem dados inventados/segredos; sem fila de UI por frame; custo medido |
| F12 / P1 para jogos | Gamepad | Aplicativos não implementam encaminhamento/emulação | Captura no Mac, emulação no Windows, mapeamento, slots, reconexão e vibração suportada | Controle reconhecido no jogo; eixos/dead zones; hot-plug; desconexão zera o estado |
| F13 / P1 | Host instalado e disponível | Executável e tarefas temporárias de laboratório | App/tray, iniciar/parar host, inicialização automática configurável, instalador e atualização | Máquina limpa, restart/crash, dependências, upgrade/rollback e desinstalação |
| F14 / P2 | Host sem monitor físico | Captura exige output conectado e não rotacionado | Display virtual/fallback com driver compatível, seleção explícita e restauração de topologia | Conectar sem monitor; remoção segura; recuperar após falha sem deixar telas alteradas |
| F15 / P2 | Nitidez e precisão de cor | HEVC Main 8-bit 4:2:0 SDR | Avaliar 4:4:4, range/colorimetria e 10-bit com suporte real do Mac e NVENC | Texto/cores corretos, backend identificado e impacto medido em 4K90 |
| F16 / P2 | Permissões e compartilhamento | Transporte com pareamento; sem experiência de convidados/papéis | Revogar dispositivo, visualizar apenas, controle autorizado, aviso local e encerramento de sessão | Negação/revogação efetivas e estado limpo; integridade Windows/UIPI tratada |
| F17 / P2 | Microfone e periféricos avançados | Não implementados | Microfone para o host, política de eco e dispositivos virtuais; caneta/câmera como escopos separados | Compatibilidade por plataforma, permissão e hot-plug; não prometer periférico USB genérico |
| F18 / P2 | Compatibilidade e acesso remoto amplo | Caminho principal HEVC/NVENC em LAN/Tailscale; infraestrutura de produto ausente | Outros GPUs/backends, diagnóstico de rota/MTU e arquitetura de descoberta/traversal/relay se necessária | Hardware-alvo e caminhos reais; fallback explícito, capacidade negociada e limites documentados |

A documentação do Parsec confirma áudio, mouse para jogos, gamepads e acesso à tela de logon no host Windows; a implementação equivalente no Lightray demanda entregas próprias. [Referência de capacidades](https://support.parsec.app/hc/en-us/articles/32381463419924-Feature-Matrix).
Para gamepad, o Parsec documenta emulação por driver virtual e configuração do tipo de controle; suporte específico varia por dispositivo/plataforma. [Configuração de gamepad](https://support.parsec.app/hc/en-us/articles/32381705301908-Setup-Gamepad).

## Detalhes de uso que precisam de aceite explícito

- Desktop parado: ao reduzir FPS em conteúdo estático, distinguir ausência legítima de mudança de falha de captura/rede; o observador atual interrompe após dois segundos sem novo decode e precisará de estado de saúde do host para esse modo.
- Monitor local: salvar preferência com identificador persistente e fallback explicado; os números de `--screen-id` pertencem ao inventário daquela execução e podem mudar.
- Frequência anunciada: Metadados de dimensão física/refresh foram corrigidos e validados, com 60 Hz recebidos pelo cliente na campanha WGC; continuar distinguindo Hz da origem, FPS configurados, decodificados e apresentados.
- Sessão sem imagem: informar se está conectando, esperando captura, recuperando, sem decoder ou desconectada; oferecer reconectar/desconectar e diagnóstico sem depender de imagem.
- Mudança de qualidade: mostrar configuração aplicada pelo host, com estado pendente e erro/rollback; não atualizar somente o rótulo do cliente.
- Tela cheia e escala: preservar monitor e posição anteriores, aspect ratio, letterboxing, pointer mapping e navegação local do menu.
- Foco e teclado: impedir que widgets locais emitam input remoto, consumir o clique de retomada, manter escape acessível e exibir de forma consistente quem recebe o teclado/mouse.
- Acessibilidade e identidade: foco visível, labels, ordem de Tab, contraste, localização PT-BR/EN e uma hierarquia estável de Computadores/Configurações/Sessão, com marca/ciano Lightray.
- Preferências: separar padrão global, perfil por host e override daquela sessão, com reset e migração versionada; persistir monitor, áudio, hotkeys e qualidade somente quando os backends suportarem.
- Operação do host: estado no tray, indicador de sessão ativa, parar/desconectar e recuperação do processo; disponibilizar logon/UAC exige arquitetura própria, além de `SendInput` no usuário atual.
- Sessão compartilhada: definir arbitragem do controle, visualizar apenas e revogação antes de ampliar o modelo atual de uma sessão ativa.

O Parsec oferece hotkeys editáveis e liberação de input, com requisitos de Acessibilidade/modo imersivo para atalhos de sistema no Mac. [Hotkeys e comportamento no macOS](https://support.parsec.app/hc/en-us/articles/32381778420372-Configure-Hotkeys).
Seu overlay inclui gráficos, estados de processamento/rede e ajustes de stream; a proposta Lightray mantém métricas por etapa e acrescenta apresentação somente depois de instrumentá-la. [Overlay e diagnóstico](https://support.parsec.app/hc/en-us/articles/32381603663636-Stream-Overlay-Stats-and-Logging).
Sua documentação também descreve redução do limite efetivo de bitrate em congestionamento e economia de envio em desktop estático, salvo modo de FPS constante; estes são comportamentos ainda pendentes no Lightray. [Métricas e logs de rede](https://support.parsec.app/hc/en-us/articles/32381603663636-Stream-Overlay-Stats-and-Logging).

## Recursos avançados e seus limites

Múltiplas telas simultâneas, displays virtuais adicionais e modo de privacidade dependem de Warp/Teams em cenários documentados do Parsec; fallback de um display virtual Windows sem telas físicas é documentado para todos os usuários, com driver.
Esses recursos devem ser comparados com o plano/plataforma efetivamente usado como referência. [Monitores e displays virtuais](https://support.parsec.app/hc/en-us/articles/32381733729044-Multiple-Monitors-and-Virtual-Displays), [modo de privacidade](https://support.parsec.app/hc/en-us/articles/32361381211284-Privacy-Mode).
No Lightray, privacidade precisa de garantia de restauração das telas, indicador de falha e encerramento seguro antes de ser oferecida como proteção.
Um display virtual é uma possível entrega futura para uso sem monitor, não uma causa comprovada nem solução automática para a falha atual de primeiro frame.

O Parsec documenta 4:4:4 e 10-bit como ajustes de qualidade, com 10-bit experimental e requisitos específicos de hardware. [Qualidade e precisão de cor](https://support.parsec.app/hc/en-us/articles/32381785123860-Improve-Stream-Quality-and-Color-Accuracy).
Para Mac → Windows, verificar decode/apresentação reais antes de expor 4:4:4 ou 10-bit; 10-bit não certifica HDR.
H.264 como fallback exigiria revisar o contrato atual do Lightray, que fixa HEVC por versão; não basta acrescentar um seletor visual. [Contrato de vídeo](../video.md), [perfil implementado](../windows/compatibility-profile.md).
Não foi estabelecida nesta pesquisa equivalência de transferência de arquivos, encaminhamento USB genérico ou suporte completo de DualSense no Mac; esses itens não devem ser anunciados como paridade certificada.

## Ordem recomendada e escopo de cada incremento

1. F01 e os detalhes de estado/refresh: restabelecer captura, validar o painel novo com vídeo ativo e corrigir informação enganosa de configuração.
2. F02/F03/F04: conexão pela interface, teclado internacional e clipboard explícito, mantendo testes automatizados independentes do desktop.
3. F06/F05: áudio do host e mouse relativo, completando uso cotidiano e navegação/jogo.
4. F07/F08/F10/F11: qualidade renegociável, adaptação de rede, apresentação instrumentada e gráficos/avisos; iniciar campanhas comparativas controladas.
5. F09/F12/F13: monitores Windows, gamepad e instalação/host disponível; aprovar 30 minutos por cenário e depois soak de 8/24 horas.
6. F14–F18: display virtual/privacidade, cor avançada, convidados, microfone/periféricos e compatibilidade ampliada, com gates próprios de driver/protocolo/plataforma.

Para trabalho cotidiano, clipboard/teclado/áudio têm prioridade alta; para jogos, mouse relativo/gamepad/cadência também são critérios centrais.
Parte do desenho de UI, configuração e testes isolados pode avançar enquanto o diagnóstico de captura estiver aberto, mas aceite dentro da sessão depende de primeiro frame real.
A comparação de desempenho deve usar mesmas telas, cena, duração, modo, rede e hardware; a matriz de funcionalidades por si só não prova latência ou fluidez equivalentes.
O Samsung permanece reservado à interface; a tela integrada de maior frequência deve receber testes de apresentação 4K90 sem ocupar os dois monitores utilizados pelo usuário.

# Painel de milissegundos e atalhos Mac → Windows

Implementado e testado em 29/09/2026, com referência no [estudo do Parsec e plano de evolução](../reviews/parsec-reference-2026-09-29.md).
O cliente atualizado está no app de laboratório `output/windows-client/Lightray Windows Lab.app` e no produto Swift `lightray-client`.

## Recursos disponíveis

- Painel sobre o vídeo, também em tela cheia, com resolução, Network RTT, Decode, Queue, FPS decodificados, tráfego da conexão, perdas e descartes da fila.
- Menu View para mostrar/ocultar o painel; `--no-stats` inicia com o painel oculto.
- Menu Input com troca opcional Command↔Control; `--swap-command-control` ativa esse perfil desde a abertura.
- Comandos explícitos Alt+Tab, tecla Windows e Ctrl+Esc, independentes do perfil físico.
- Liberação de teclas/botões ao perder foco, desativar o app, fechar a janela ou encerrar a sessão; a troca de perfil libera as teclas com o mapeamento anterior, e “Release Input” suspende também ponteiro e rolagem.
- Clique de retomada consumido localmente; somente os próximos cliques são encaminhados ao host.

| Ação | Atalho local |
| --- | --- |
| Mostrar/ocultar métricas | Control+Option+Command+M |
| Liberar entrada remota | Control+Option+Command+Esc |
| Alternar tela cheia | Control+Option+Command+F |
| Enviar Alt+Tab ao Windows | Control+Option+Command+Tab |
| Enviar tecla Windows | Control+Option+Command+W |
| Sair do cliente | Control+Option+Command+Q |

Com a troca ativada, ⌘C/⌘V opera como Ctrl+C/Ctrl+V dentro do Windows e Control representa Windows; Option continua Alt.
O modo físico original continua disponível e é o padrão.
Não há sincronização de clipboard entre os sistemas nesta entrega.
Atalhos reservados pelo macOS podem continuar locais; captura HID/imersiva permanece no plano.

## Semântica das métricas

Network RTT é a estimativa suavizada de ida e volta do transporte, em milissegundos, apresentada somente depois de uma amostra real.
Decode é a média da duração da chamada síncrona do backend por frame decodificado com sucesso na geração atual.
Queue é a média entre a conclusão da remontagem do frame no cliente e o início dessa chamada de decode.
As médias são retiradas e reiniciadas aproximadamente a cada segundo; resultados cancelados ou de gerações inválidas não entram na estatística.
Sem novas amostras, Decode e Queue mostram “—”; o estado de reconexão substitui as métricas antigas.
O painel não apresenta encode do Windows, tempo de display, FPS fisicamente apresentados ou latência input→photon.
Os contadores Lost e Decode drops são cumulativos e distintos; o tráfego é agregado por conexão.

## Validação real — `desktop-018`

Stream 3840×2160, alvo de 90 FPS, NVENC nativo, cliente Mac com troca Command↔Control ativada e painel visível.
O host reportou origem de 60 Hz nesta sessão; nenhuma frequência foi alterada por esta rodada.
Houve interações e screenshots durante o teste, portanto seus números não devem ser tratados como benchmark limpo de desempenho.

| Caso | Resultado |
| --- | --- |
| ⌘A / ⌘C / substituição / ⌘A / ⌘V | Texto conhecido restaurado; `test_text_matches=true`, dois Ctrl+A, um Ctrl+C e um Ctrl+V observados na janela Windows |
| Liberar entrada e tentar digitar | Texto remoto permaneceu intacto; painel mostrou entrada liberada e host registrou `held=0` |
| Retomar por menu | Estado de captura de entrada restaurado |
| Alt+Tab remoto | Janela de teste perdeu foco no Windows, com contador de perda de foco incrementado |
| Tecla Windows remota | Menu Iniciar observado no stream; fechado com Escape sem executar aplicativo |
| Métricas em tela cheia | Painel permaneceu visível e legível; ativação/ocultação pelo atalho local verificada |
| Primeiro clique após liberação | Não acionou o botão remoto; o clique seguinte incrementou o contador para um |
| Encerramento pelo atalho local | Cliente encerrou normalmente; host concluiu sem falhas de input ou teclas/botões retidos |

O resultado final do host registra 14.979 frames, uma sessão, 1.131 eventos de input aplicados, zero usos não suportados, zero falhas e zero entradas retidas.
A janela de teste grava apenas correspondência com texto conhecido e contadores, sem registrar conteúdo arbitrário digitado ou conteúdo de clipboard.
As verificações de texto/contadores usam leitura remota do resultado; o menu Iniciar e a apresentação do painel foram inspecionados pela interface do cliente.

## Testes e estado da entrega

- 102 testes Swift aprovados: 80 core e 22 Mac, incluindo dez testes novos para mapeamento, modificadores, repetição, liberação e medição de tempos.
- 29 testes Python aprovados.
- Build Windows MSVC com `/W4 /WX /O2` aprovado; 15 casos de input com emissor falso aprovados.
- Build release do cliente Mac aprovado, assinatura ad hoc do app de laboratório atualizada e `git diff --check` sem erros.
- Limpeza confirmada: zero processos Windows de laboratório, zero tarefas temporárias, zero endpoints UDP de teste e zero regras temporárias de firewall; cliente Mac encerrado.

Fontes implementadas: `RemoteKeyboard.swift`, `DecodeTimings.swift`, `BoundedVideoDecoder.swift`, `StatisticsOverlay.swift`, `VideoView.swift`, `StreamWindow.swift`, `ClientApp.swift` e opções da CLI.
A alteração Windows desta rodada limita-se aos contadores da janela de teste; não mudou o protocolo ou o encoder.
São alterações locais, ainda não publicadas em commit/PR.

Reprodução, com host de laboratório ativo e arquivos privados de pareamento preparados:

```sh
swift build --package-path macos -c release --product lightray-client
macos/.build/release/lightray-client 192.168.15.5:37373 --pair-file tools/windows/results/desktop-pairing --streams 1 --no-fec --local-cursor --screen-id 5 --swap-command-control
```

Conferir os IPs e o ID de tela no ambiente antes de reproduzir.
Evidências selecionadas e hashes estão em [client-ux-initial](evidence/client-ux-initial/README.md).

# Telemetria do host Windows no cliente Mac — 30/09/2026

## Escopo e semântica

A etapa UX02 acrescenta captura/conversão e encode em milissegundos ao painel do cliente Mac.
O Windows continua usando captura nativa e NVENC da NVIDIA; não há encoder por software ou WSL nesta implementação.
Os valores são durações medidas no próprio Windows, transportadas junto ao frame, sem subtrair relógios de computadores diferentes.
A interface mostra médias dos frames decodificados com sucesso desde a atualização anterior, aproximadamente uma vez por segundo, com “—” quando não há amostras.
RTT, decode e espera na fila continuam separados.

“Capture/convert” mede a chamada de aquisição do desktop e submissão da conversão; “Encode” mede a chamada síncrona até disponibilizar a saída codificada.
A GPU executa trabalho de modo assíncrono, e uma espera pela conversão pode ser contabilizada na chamada de encode.
Esses valores delimitam etapas da aplicação, sem isolar o tempo de GPU de cada operação.
Frames reutilizados também entram na média; a frequência de decode não comprova frequência de atualização do desktop ou apresentação no monitor.
Frames perdidos, descartados ou que falharam no decode não entram na amostragem do painel.
A soma dos indicadores não mede latência de ponta a ponta ou resposta do input até a tela.

## Compatibilidade e limites

A extensão experimental local `0xF0` ocupa 20 bytes por frame, ou 1.800 bytes/s a 90 FPS, antes de efeitos eventuais sobre fragmentação.
O identificador precisa ser acordado com o mantenedor antes de virar uma atribuição oficial do protocolo.
A versão 1 contém duas durações em microssegundos e um contador de tentativa do host; o contador permite conciliar amostras com `frame-timings.csv` e pode apresentar lacunas.
Amostras de versão desconhecida, tamanho incorreto, durações superiores a um segundo ou extensões duplicadas tornam a telemetria indisponível sem descartar um vídeo válido.
Um contêiner TLV truncado continua sendo erro de protocolo.
Quando não há espaço no limite de extensões, a telemetria opcional é omitida.
A chamada C `lr_host_submit` permanece disponível; `lr_host_submit_timed` é uma adição à ABI.
O executável Windows atualizado exige a DLL nova, enquanto consumidores da chamada antiga continuam compatíveis com essa DLL.
A especificação exata está em [docs/video.md](../video.md).

## Validação concluída em 30/09/2026

A entrega funcional de telemetria está validada entre o host Windows nativo/NVENC e o cliente Mac.
As fontes e os binários são os preparados em 29/09/2026; os hashes das fontes do core foram reconferidos antes da execução de 30/09/2026.
Não há commit ou PR publicado nesta entrega.

- 106 testes Swift no Mac: 83 core e 23 Mac.
- 31 testes Python, incluindo verificação de correspondência, divergência, ausência de amostras e IDs duplicados.
- 92 testes Windows em Debug e 92 em Release.
- Interface C: seis casos do core, 100 ciclos de lifecycle, quatro chamadores concorrentes e 360 frames do corpus entregue pelo caminho de compatibilidade; esse probe usa relógio simulado, sem captura ou NVENC ao vivo.
- Build MSVC com warnings tratados como erros e 15 casos de input aprovados; build Release Mac e assinatura ad hoc conferidos.
- Sessão real: `desktop-022`, 20.811 frames, seis sessões, NVENC ativo, zero falhas de input e zero teclas/botões retidos ao sair.
- Conciliação exata: 32 amostras do benchmark mais seis da recuperação `desktop-021`, sem divergência entre captura/encode recebidos no Mac e as linhas correspondentes do CSV Windows.
- Interface: painel legível em janela e tela cheia, ocultação e reabertura com valores atualizados; o vídeo preservou a proporção em um monitor Mac na vertical.
- Compatibilidade: cliente anterior com host novo por 25 segundos, encerramento normal; cliente novo com executável e DLL anteriores por 35 segundos, vídeo funcional e campos de captura/encode exibidos como “—”.

### Comparação exploratória do painel

Foram quatro execuções de 45 segundos, na ordem ligado/oculto/oculto/ligado, com os primeiros dez segundos excluídos das estatísticas de CPU e dos recortes dos logs.
A configuração foi HEVC/NVENC, 3840×2160, alvo de 90 FPS, orçamento de 80 Mbps, LAN e FEC desligado, com a mesma janela Windows de teste animada.
A origem Windows e a tela escolhida pelo cliente reportaram 60 Hz nesta campanha; nenhuma frequência foi alterada por estes testes.
A GPU estava em 0% antes do início; durante a amostragem, o uso global teve mediana de 33%, encoder 33% e potência 38,31 W.
Essas leituras pertencem à GPU Windows inteira, não isolam processos e não medem a GPU do Mac.

| Rodada | Painel | CPU do cliente, um núcleo | FPS decodificados, mediana | Captura p50, ms | Encode p50, ms | Encode p95, ms | Encode p99, ms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Ligado | 13.24% | 89 | 0.106 | 5.808 | 9.149 | 15.547 |
| 2 | Oculto | 11.63% | 90 | 0.104 | 5.607 | 9.132 | 15.245 |
| 3 | Oculto | 11.27% | 88 | 0.103 | 5.489 | 8.738 | 15.359 |
| 4 | Ligado | 11.16% | 89 | 0.108 | 5.476 | 8.925 | 15.037 |

As distribuições de captura e encode vêm dos frames do CSV entre o primeiro e o último ID amostrado após o aquecimento de cada rodada.
Os FPS são janelas de aproximadamente um segundo registradas a cada cinco segundos, não contagem de apresentações na tela.
A faixa observada nessas janelas foi de 79 a 90 FPS; não houve incremento dos contadores de perda ou descarte de decode nos recortes após o aquecimento.
O primeiro cliente teve seis perdas e seis descartes na inicialização, preservados nos logs; os outros três não registraram essas perdas iniciais.
As medianas de RTT por rodada ficaram entre 4,6 e 5,4 ms, decode entre 2,20 e 2,40 ms e espera na fila entre 0,04 e 0,05 ms.
O encode apresentou p99 entre 15,04 e 15,55 ms, acima do orçamento de 11,11 ms para 90 FPS, e um pico de 72,47 ms na quarta rodada.
A sessão inteira reutilizou 7.006 frames em 20.811 tentativas registradas, aproximadamente 33,7%, coerente com uma origem de 60 Hz e envio próximo de 90 FPS.

Não apareceu uma diferença consistente de FPS entre painel ligado e oculto; a quarta rodada ligada usou menos CPU que as duas ocultas.
A ordem temporal, o tamanho pequeno da amostra e a permanência de input ativo com eventos durante a execução impedem atribuir causalmente a diferença de CPU ao painel.
Trata-se de uma medição exploratória, sem teste de significância, sem certificação de 90 FPS estáveis e sem medir input-to-photon.
Uma campanha de custo isolado deve repetir as rodadas com input desativado, controlar o estado de energia e a carga dos dois computadores e coletar a cadência de apresentação.

### Falha encontrada e recuperação

A primeira tentativa de 30/09/2026, `desktop-020`, autenticou mas não recebeu nenhum frame e terminou com `DXGI_ERROR_ACCESS_LOST (0x887A0026)`.
A janela de teste continuava animando; isso mostrou que conexão e processo de teste ativos não bastam para declarar a captura saudável.
A tentativa seguinte, `desktop-021`, reinicializou somente o host e capturou normalmente, sem reiniciar o Windows, mexer no driver ou alterar a configuração de tela.
O descritor de captura reportou 160 Hz na tentativa que falhou e 60 Hz na seguinte; a causa da transição não foi estabelecida.
A pausa de 29/09/2026 durante o jogo e seus dados parciais permanecem separados desta campanha.

A recuperação automática ainda não está implementada: hoje essa falha encerra o host.
A documentação da Microsoft orienta recriar a interface de duplicação quando ela fica inválida, por exemplo após transição de desktop ou modo; isso orienta a correção seguinte, sem provar a causa específica deste incidente. [Microsoft: AcquireNextFrame](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgioutputduplication-acquirenextframe).

### Próximos itens priorizados

1. UX02a — recuperar a captura: distinguir timeout de frame, perda da duplicação e perda do device; invalidar o cache de imagem, liberar input retido, tentar recriação com intervalo e prazo limitados e registrar cada transição; não reenviar uma superfície antiga como se fosse conteúdo atual.
2. UX02a — garantir retomada coerente: verificar geometria/formato e adapter após recriar a captura, reconstruir encoder quando necessário e exigir IDR/configuração atualizada; apresentar estado de captura indisponível quando não houver primeiro frame dentro do prazo.
3. UX02a — validar falhas: testes determinísticos de transição, prazo e descarte de recursos, depois ciclos reais coordenados de perda/retorno da captura; medir tempo até o primeiro frame, vazamentos e teclas retidas, sem automação de mudanças de frequência nesta fase.
4. UX03 — ampliar teclado: ANSI/ISO/ABNT2, acentos, cedilha, AltGr, Caps Lock e funções, preservando copiar/colar remoto, Alt+Tab, Windows e escape local; testar perda de foco e reconexão e só depois persistir preferências por host.
5. UX06 — confirmar desempenho: campanha sem input durante a medição, modo de tela estável e instrumentação de apresentação; executar 30 minutos por cenário antes de testes de 8/24 horas ou comparações de produto com Parsec.

### Evidências e limpeza

Os logs, CSVs, comparações, observações da interface e hashes estão em [evidências da telemetria](evidence/host-telemetry-initial/README.md).
O executável Windows atualizado foi restaurado após o teste com o host anterior e seu hash foi comparado com o usado na rodada principal.
A limpeza confirmou zero processos de laboratório, tarefas temporárias, endpoints UDP de teste e regras temporárias de firewall; o cliente Mac e a coleta de GPU também foram encerrados.

## Reprodução

1. Execute `swift test --package-path macos` e compile `swift build --package-path macos -c release --product lightray-client`.
2. Prepare uma cópia isolada com `python3 tools/windows/prepare-swift-core.py --output tools/windows/results/swift-core-003 --host-bridge`, usando um identificador livre se já existir.
3. Transfira a cópia e as fontes Windows; execute `build-swift-core-probe.ps1 -Probe swift-core-003` e `build-desktop-host.ps1` no Windows nativo.
4. Inicie o laboratório autorizado com `start-desktop-host-test.ps1 -CoreProbe swift-core-003`, informando os endereços, pareamento privado e duração limitada, conforme o guia Windows.
5. Compare as amostras com `python3 tools/windows/verify-host-timings.py --host-csv caminho/frame-timings.csv --client-log caminho/client.log`.
6. Para custo visual, alterne execuções do mesmo binário com e sem `--no-stats`, mantendo cena, tela, resolução, frequência e parâmetros de rede; descarte o aquecimento e registre CPU e cadência.
7. Ao terminar, encerre o host, a janela de teste e o cliente, remova a tarefa e a regra temporária de firewall e confirme que a porta UDP não ficou aberta.

A medição de CPU do cliente usa a diferença do tempo acumulado de processo dividida pelo intervalo observado, expressa como porcentagem de um núcleo.
A comparação curta do HUD avalia o custo de exibição, pois a coleta limitada de métricas permanece ativa com o painel oculto.
Ela não substitui campanhas prolongadas, instrumentação de apresentação ou medição física de latência.

# Windows → Mac: tentativa de 4K a 90 FPS

Em 29/09/2026, após o usuário configurar o Windows em 3840×2160 a 160 Hz, o cliente Mac recebeu a captura real em 4K com alvo de 90 FPS durante dois minutos.
A rodada final registrou mediana de 89 FPS decodificados, picos de 90 FPS e média de 88,52 frames submetidos por segundo.
O encoder utilizado foi NVIDIA NVENC nativo na RTX 4090, sem WSL ou processo FFmpeg no caminho da sessão.
**4K próximo de 90 FPS está demonstrado em uma rodada curta; 90 FPS sustentados e apresentação física nessa cadência ainda não estão qualificados.**
A limitação anterior de origem a 60 Hz foi removida: o host confirmou 160 Hz, com apenas 40 reutilizações entre 10.622 frames, aproximadamente 0,38%.
As falhas anteriores de mudança de modo foram registradas e a captura foi recuperada após intervenção local do usuário.

## Configuração

- Windows 11 Home x64 build 26200, RTX 4090, driver NVIDIA 591.86; host nativo MSVC, Desktop Duplication, conversão GPU BGRA→NV12, NVENC HEVC Main 8-bit 4:2:0 e core Swift por ABI C.
- Alvo do stream: 3840×2160, 90 FPS, 80 Mb/s, NVENC P1/ultra-low-latency; UDP pela LAN, pareamento autenticado e FEC desativado.
- Cliente Mac Apple M5 Pro, colocado na tela de ID 5, com `maximumFramesPerSecond=160` reportado pelo macOS; isso não mede a apresentação física de cada frame.
- Cena própria com faixas animadas em aproximadamente 10% da altura, texto, botão e contador; não representa jogo, vídeo de tela inteira ou carga sustentada de 80 Mb/s.
- O cliente reportou aproximadamente 5–7 Mb/s com origem a 60 Hz e 6,9–9,8 Mb/s na rodada com origem a 160 Hz; o alvo configurado de 80 Mb/s não equivale ao tráfego efetivamente produzido.

## Resultado final com origem em 160 Hz — `desktop-017`

| Métrica | Resultado |
| --- | --- |
| Origem confirmada pelo inventário e Desktop Duplication | 3840×2160, 160 Hz |
| Stream / duração da medição | 3840×2160, alvo 90 FPS / 120 s |
| Frames submetidos / cadência calculada | 10.622 / 88,52 FPS |
| Atualizações do desktop / taxa calculada | 10.582 / 88,18 por segundo |
| Reutilizações de frame | 40, aproximadamente 0,38% |
| FPS decodificados: mínimo / mediana / máximo | 85 / 89 / 90, em 23 amostras |
| RTT: mínimo / mediana / máximo | 2,9 / 5,0 / 6,9 ms |
| Tráfego reportado: mínimo / mediana / máximo | 6,9 / 8,0 / 9,8 Mb/s |
| Encode: p50 / p95 / p99 | 3,400 / 4,499 / 5,283 ms |
| Intervalo entre inícios de captura: p50 / p95 / p99 | 11,085 / 11,571 / 14,543 ms |
| Última amostra: `lost` / descartes de decode / NACKs | 6 / 6 / 0 |
| Erros de socket nas amostras | Zero |
| Encerramento | Normal, zero falhas de input e zero teclas/botões retidos |

Os contadores de perda e descarte já estavam em seis na primeira amostra, aos cinco segundos, e permaneceram constantes nas amostras seguintes.
A cadência média ainda ficou abaixo de 90 FPS; os intervalos acima do orçamento de 11,111 ms precisam de investigação, apesar do encode p99 abaixo desse orçamento.
Os percentis usam nearest-rank sobre as linhas do CSV e não representam latência até a tela do Mac.
Não houve snapshot ou inspeção visual concorrente nesta rodada.
O modo de 160 Hz escolhido pelo usuário foi preservado; o runner não alterou a frequência nesta execução.

## Rodadas anteriores com origem em 60 Hz

| Métrica | `desktop-006` | `desktop-007` | `desktop-016` após recuperação |
| --- | --- | --- | --- |
| Intervalo entre primeiro e último frame submetido | 120,00 s | 58,39 s | 89,99 s |
| Frames submetidos pelo host | 10.542 | 5.133 | 7.913 |
| Cadência de submissão calculada | 87,84 FPS | 87,90 FPS | 87,92 FPS |
| Amostras de diagnóstico do cliente | 23 | 11 | 17 |
| FPS decodificados: mínimo / mediana / máximo | 86 / 88 / 90 | 79 / 88 / 90 | 84 / 89 / 90 |
| RTT: mínimo / mediana / máximo | 1,9 / 4,1 / 5,7 ms | 2,5 / 3,8 / 6,9 ms | 3,3 / 4,4 / 8,1 ms |
| Frequência da origem reportada pela captura | 60 Hz | 60 Hz | 60 Hz |
| Atualizações do desktop por segundo | 57,93 | 57,92 | 58,88 |
| Reutilizações de frame acumuladas | 3.590 | 1.750 | 2.613 |
| Tempo mediano de encode | 3,406 ms | 3,377 ms | 3,275 ms |
| Contador `lost` na última amostra | 35 | 6 | 6 |
| Descartes da fila de decode na última amostra | 85 | 6 | 6 |
| Falhas de input / teclas ou botões retidos ao encerrar | 0 / 0 | 0 / 0 | 0 / 0 |

A cadência de submissão usa `(número de linhas − 1) / intervalo entre os timestamps inicial e final` do CSV do host.
A taxa de atualizações usa a diferença do contador `desktop_updates` no mesmo intervalo; esse contador deriva de `LastPresentTime`, sem comparação dos pixels ou medição óptica.
RTT é a métrica de transporte do cliente, não latência input→photon nem captura→display.
Nas rodadas de origem a 60 Hz, FPS decodificados e submissões incluem muitos frames repetidos; na rodada a 160 Hz, o contador de atualizações chegou a 88,18 por segundo, ainda abaixo de 90.
Esse contador não prova distinção visual de cada imagem ou apresentação física no Mac.
Os contadores de perda e de descarte não devem ser somados como se fossem uma única taxa de perda.

A primeira rodada salvou um PNG de 3840×2160 e teve inspeção visual durante a medição; essas operações podem interferir no desempenho.
A segunda não usou `--snapshot` e foi encerrada antes do prazo para investigar a frequência da origem; não constitui teste prolongado de estabilidade.
A rodada de recuperação de 90 segundos também não usou snapshot; os contadores de perda e descarte permaneceram em seis desde a primeira amostra, com 14 NACKs acumulados e zero erros de socket na última amostra.
Houve interação durante as sessões; a campanha não foi isolada de outros usos da máquina.
Uma amostra `nvidia-smi` registrou 29% de uso do encoder e 58% de GPU, valores agregados que não atribuem toda a carga exclusivamente ao host.
A imagem decodificada confirma a resolução e a cena, mas não mede fluidez física ou qualidade em movimento.

## Falha de frequência e estado final

1. O inventário interativo informou 3840×2160 a 60 Hz e enumerou modos de 120, 144 e 160 Hz, entre outros; a enumeração não comprova que a configuração ativa possa aplicá-los.
2. Em `desktop-009`, a verificação de 144 Hz retornou `test_status=0`, mas a aplicação retornou `change_status=-1` (`DISP_CHANGE_FAILED`).
3. Em `desktop-010`, a própria verificação de 120 Hz retornou `test_status=-1`; a aplicação não foi executada.
4. De `desktop-011` a `desktop-014`, `DuplicateOutput` falhou com HRESULT `-2005270491` (`0x887A0025`, `DXGI_ERROR_MODE_CHANGE_IN_PROGRESS`).
5. Retry limitado a aproximadamente cinco segundos e pedido temporário para manter a tela ativa não resolveram o problema.
6. O usuário confirmou monitor ligado e sessão desbloqueada; a hipótese de bloqueio da sessão não explica o resultado confirmado.
7. A tentativa `display-recovery-001` de reaplicar somente o modo corrente de 4K/60 Hz, usando `CDS_RESET`, retornou `restore_current_status=-1`; o inventário seguinte continuou informando 4K/60 Hz, e a captura continuou indisponível.

As tentativas não solicitaram alteração persistente do modo no registro.
Até `desktop-014`, a captura continuava indisponível, apesar do modo de 60 Hz reportado.
Não houve reinício do Windows, de serviços NVIDIA ou reset do driver nesta recuperação.
Após o usuário confirmar o modo nas configurações locais do Windows, `desktop-015` voltou a inicializar a captura em 3840×2160/60 Hz.
A rodada `desktop-016` confirmou a recuperação completa do caminho até o cliente Mac, com 7.913 frames submetidos, uma sessão e encerramento normal após a medição de 90 segundos.
Essa sequência confirma a recuperação observada, sem determinar a causa interna do estado do driver.
Em seguida, o usuário informou que configurou 160 Hz localmente; `desktop-017` confirmou 4K/160 Hz no inventário e na captura, e concluiu outra sessão de dois minutos.
A limpeza final de `desktop-017` confirmou zero processos de host/janela de teste, zero tarefas de laboratório, zero endpoints UDP 37373 e zero regras temporárias de firewall.

## Implementação e validação

O host e o runner agora aceitam largura, FPS e bitrate configuráveis, preservando 1920/30/20 como padrão.
Foram acrescentados CSV de tempos por frame, frequência da origem, contagem de atualizações/reutilizações, cena animada opcional, seleção de tela no cliente Mac e ferramenta de inventário/troca temporária de frequência.
Essas ferramentas continuam sendo de laboratório; recuperação de mudança de modo, perda do device e troca de sessão ainda precisa de implementação e qualificação de produto.

- Regressão Mac: 92 testes Swift aprovados, sendo 80 core e 12 Mac.
- Ferramentas: 29 testes Python aprovados.
- Windows: build MSVC `/std:c++20 /W4 /WX /O2` aprovado e 15 casos de input com emissor falso aprovados.
- CLI: ID de tela não numérico rejeitado; isso não qualifica toda a matriz de argumentos ou múltiplas telas.

Os hashes dos binários efetivamente usados estão no `launch.json` de cada rodada.
O manifesto de fontes representa o estado posterior às tentativas de recuperação e não uma reconstrução exata das fontes das rodadas bem-sucedidas.
O relatório e o ZIP anteriores de 1080p30 permanecem evidência histórica e não contêm estas alterações de 4K90.

## Próxima execução

1. Recuperação em 4K/60 Hz concluída nesta rodada; preservar esse modo como referência e repetir a verificação após qualquer nova troca de frequência.
2. Origem 4K/160 Hz confirmada em `desktop-017`; automatizar a detecção de capacidade e tratar falhas de troca de modo antes de usar esse fluxo em produto.
3. Repetir 4K90 sem snapshot ou inspeção visual concorrente, registrar tempos de captura/conversão/encode/submissão, filas, perdas e apresentação no Mac; comparar também com 4K60.
4. Usar cena de movimento em tela inteira, ampliar duração para 30 minutos e medir p50/p95/p99, RAM/VRAM e carga NVIDIA ao longo do tempo.
5. Instrumentar frames apresentados e latência input→photon antes de qualificar fluidez e interatividade; exercitar mudança de modo e recuperação sem reiniciar o processo.

O runner aceita o comando abaixo; `-RefreshHz 0` mantém o modo atual, que precisa ser conferido antes do teste.
Usar um identificador de rodada ainda inexistente, conferir os IPs e preparar a regra de firewall restrita e os arquivos privados de pareamento conforme o relatório de desktop.

```powershell
powershell -NoProfile -File tools/windows/start-desktop-host-test.ps1 -DesktopApproved -Run desktop-018 -BindIPv4 192.168.15.5 -PeerIPv4 192.168.15.13 -PairFile tools/windows/results/desktop-pairing -Seconds 150 -Width 3840 -FPS 90 -BitrateMbps 80 -Motion -RefreshHz 0
```

```sh
output/windows-client/Lightray\ Windows\ Lab.app/Contents/MacOS/lightray-client 192.168.15.5:37373 --pair-file tools/windows/results/desktop-pairing --streams 1 --no-fec --local-cursor --screen-id 5 --exit-after 120
```

Evidência reproduzível: [índice e métricas](evidence/host-4k90-initial/README.md).
Referências: [ChangeDisplaySettingsExW](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-changedisplaysettingsexw) e [DuplicateOutput](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgioutput1-duplicateoutput).

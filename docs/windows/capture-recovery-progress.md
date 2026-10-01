# Recuperação limitada de captura Windows — 30/09 e 01/10/2026

## Resultado

O host agora recria a duplicação DXGI após perda de acesso, com prazo total de cinco segundos por episódio, intervalo entre tentativas e limite de oito recriações.
A implementação cobre o mesmo adapter/device e a mesma geometria, orientação e formato.
Dez ciclos de perda injetada da interface DXGI real recuperaram a captura na mesma sessão em 30/09/2026, sem reconectar o cliente Mac.
A rodada de 01/10/2026 confirmou o prazo de encerramento, mas encontrou um impedimento de captura antes do primeiro frame.
A recuperação geral do desktop ainda precisa de validação após bloqueio real, transição de desktop e alterações de modo.

## Comportamento implementado

- `DXGI_ERROR_WAIT_TIMEOUT` permanece um resultado normal de ausência de atualização, com reutilização da última superfície apenas durante captura pronta.
- Perda de acesso invalida a prontidão do cache, libera a interface de duplicação e impede encoding/submissão de uma superfície anterior até chegar um frame novo.
- O host libera input mantido durante a interrupção e bloqueia novos eventos enquanto a captura não está pronta.
- A recriação usa backoff de 100–800 ms e não renova o prazo do episódio; a aquisição inicial possui um watchdog de um segundo para ausência do primeiro frame.
- Um frame novo inicia outra época de captura; o encoder solicita IDR e exige configuração não vazia antes de enviar o primeiro frame dessa época.
- Perda do device, mudança de geometria/orientação ou mudança de formato encerram com erro explícito, pois ainda não há reconstrução completa do pipeline ou renegociação da resolução.
- O diagnóstico final inclui timeouts de aquisição, recriações, perdas e último HRESULT de recriação.

A política é portável e independente de DXGI, em `tools/windows/src/capture_recovery.hpp`.
`DesktopCapture` gerencia os recursos reais e `windows_host.cpp` mantém o transporte autenticado em atividade durante a espera.
A documentação da Microsoft orienta recriar a interface de duplicação quando ela perde validade; a implementação distingue essa condição do timeout de aquisição. [Microsoft: AcquireNextFrame](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgioutputduplication-acquirenextframe).

## Campanha positiva — 30/09/2026, desktop-024

Configuração: Windows nativo, RTX 4090, HEVC/NVENC, 3840×2160, alvo de 90 FPS, 80 Mbps, LAN, FEC desligado e janela de teste animada.
A origem reportou 60 Hz; nenhuma frequência foi alterada.
O marcador local `invalidate-capture` liberou a interface DXGI do processo em dez ciclos, com intervalo entre eles.
Isso exercita recursos reais de captura, mas não reproduz uma transição real do sistema operacional.

| Indicador | Resultado |
| --- | --- |
| Recuperações concluídas | 10 de 10 |
| Tempo registrado pelo host até aquisição da nova superfície | 109,926–122,153 ms |
| Observação externa por polling | 220–254 ms |
| Épocas com primeiro frame IDR | 11 de 11, incluindo inicialização |
| Sessões autenticadas | 1 |
| Frames registrados | 6.941 |
| Input aplicado / falhas / retidos ao sair | 403 / 0 / 0 |
| Private bytes amostrados | 277.245.952–278.024.192 bytes |
| Handles amostrados | 358–362 |

O tempo do host termina na aquisição que restabelece a captura, antes do encode e da apresentação no Mac.
O polling mede quando o log de IDR passa a ser observado e inclui o intervalo de consulta.
A pequena variação de memória/handles em dez ciclos não certifica ausência de vazamentos em soak prolongado.
O cliente continuou decodificando após os ciclos e encerrou pelo prazo configurado.
O CSV registra `capture_epoch` e `is_idr`, e a conciliação verificou o primeiro registro de cada época.

## Campanha de 01/10/2026

`desktop-025` e `desktop-026` autenticaram, mas não produziram o primeiro frame, apesar de a janela Windows reportar animação ativa e foco.
O host encerrou pelo prazo limitado de captura indisponível.
O inventário reportou 3840×2160 a 60 Hz e não indicou processo `LogonUI` no momento da consulta.
Esses dados não estabelecem a causa da ausência de frames nem comprovam o estado físico do monitor.
Não alteramos a frequência, o driver ou a sessão Windows para contornar o problema.

`desktop-027` aplicou `hold-capture-loss` depois de autenticar, sem primeiro frame anterior.
O host encerrou com o erro esperado e código 1 em 5.022 ms observados externamente.
O diagnóstico registrou sete timeouts, zero recriações e 444 invalidações, pois o marcador mantém a perda continuamente e reinicia o intervalo de backoff, preservando o prazo total.
Esse teste valida encerramento limitado sob perda injetada persistente desde a inicialização; a variante após sessão de vídeo ativa permanece pendente.
A falha esperada não deve ser interpretada como execução normal aprovada.

## Verificação e próximos casos

Doze casos determinísticos de recuperação passaram no Mac e no Windows MSVC com `/W4 /WX`, incluindo ausência de primeiro frame, backoff, prazo preservado, repetição de perda, regressão de relógio e limite de tentativas.
A suite Swift e os testes Python do projeto continuaram aprovados no incremento seguinte, com 111 testes Swift e 31 Python.
O builder Windows também aprovou 19 casos de input com emissor falso.

1. Confirmar captura real e primeiro frame com a tela Windows ativa, preservando o modo configurado pelo usuário.
2. Repetir o caso persistente depois de vídeo ativo e verificar liberação de uma tecla/botão fisicamente mantidos.
3. Validar bloqueio/desbloqueio e transição real de desktop em sessões coordenadas.
4. Acrescentar reconstrução do device/encoder e renegociação antes de suportar mudança de resolução/orientação.
5. Executar 30 minutos de ciclos e medir memória, handles e tempo até decode/apresentação no cliente.

O cliente agora indica espera, vídeo ativo ou interrupção pelo progresso de decode, com limiar local de dois segundos.
Essa observação não atribui a causa ao host e não é uma mensagem de estado de captura no protocolo.
A imagem anterior pode continuar visível durante uma interrupção, acompanhada do estado explícito e da pausa de input.

Os logs e a conciliação estão em [capture-recovery-initial](evidence/capture-recovery-initial/README.md).
A limpeza de 01/10/2026 confirmou zero processos de laboratório, tarefas temporárias, endpoints UDP 37373 e regras temporárias de firewall.
Os fontes continuam locais e não publicados em commit/PR.

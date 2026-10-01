# Controles de sessão e preferências — 01/10/2026

## Entrega

O cliente Mac recebeu um botão Lightray sobre o vídeo, com menu de sessão disponível em janela e tela cheia.
O menu reúne estatísticas, Command/Control, cursor local, tela cheia, Alt+Tab, tecla Windows, retomada da entrada e restauração das preferências.
A identidade visual mantém os controles nativos do Mac, o nome Lightray e o acento ciano já utilizado no laboratório.
O desenho funcional segue a referência do menu sobre o stream do Parsec, que concentra métricas e configurações da sessão. [Parsec: overlay e métricas](https://support.parsec.app/hc/en-us/articles/32381603663636-Stream-Overlay-Stats-and-Logging).

O novo atalho local é Control+Option+Command+S.
O menu AppKit View também oferece “Session Menu”, e os atalhos anteriores continuam disponíveis.
Abrir os controles libera a entrada remota; fechar o menu mantém essa liberação até retomada explícita ou primeiro clique de retomada no vídeo.
Esse primeiro clique é consumido localmente.
Os botões de atalho remoto do painel retomam a entrada de forma explícita, fecham o painel e enviam a sequência completa ao host.
Sem vídeo ativo, esses botões e a retomada permanecem desabilitados.

## Preferências e teclado

As preferências incluem o mapeamento de modificadores, visibilidade das estatísticas e cursor local.
O cliente as salva por identificador público de pareamento, sem gravar chave, token ou conteúdo de clipboard nesse registro.
Todos os streams da mesma execução compartilham o perfil desse host.
Opções explícitas da CLI prevalecem sobre os valores salvos e não alteram o registro apenas por iniciar o cliente.
Uma alteração pela interface salva o perfil, e “Reset host preferences” restaura o padrão.
Registros inválidos ou de versão desconhecida geram diagnóstico e fallback explícito para o padrão.

| Opção | Efeito |
| --- | --- |
| `--swap-command-control` / `--physical-keys` | Escolher o perfil de modificadores inicial |
| `--stats` / `--no-stats` | Escolher a visibilidade inicial das métricas |
| `--local-cursor` / `--host-cursor` | Mostrar ou ocultar o cursor local |
| `--no-preferences` | Ignorar valores salvos e impedir gravação durante o teste |
| `--screen-id N` | Escolher o monitor do Mac para a janela do cliente |

O perfil opcional Command/Control corresponde ao recurso de adaptação documentado pelo Parsec, preservando Option e os lados dos modificadores. [Parsec: Command/Control no macOS](https://support.parsec.app/hc/en-us/articles/32361367389972-Swap-Command-and-Ctrl-for-MacOS).
O host Windows agora aceita a tecla adicional ISO, a tecla de menu e F13–F20, que o mapa Mac já emitia e o backend Windows descartava.
Os testes nativos conferem esses scancodes contra `MapVirtualKeyW`, além de verificar o envio de Right Option como Right Alt estendido.
A interpretação de caracteres e AltGr continua pertencendo ao layout ativo no Windows; ainda não certificamos a matriz ANSI/ISO/ABNT2, acentos, cedilha ou sincronização de Caps Lock.

## Estado de vídeo e proteção da entrada

A interface mostra “Waiting”, “Live”, “Input released” ou “Video interrupted” no botão de sessão, inclusive com estatísticas ocultas.
A observação usa contagem de decodes bem-sucedidos em atualizações limitadas de aproximadamente um segundo.
Dois segundos sem progresso após vídeo ativo marcam interrupção; contagem reiniciada ou relógio regressivo voltam ao estado de espera.
A entrada remota somente segue quando há vídeo ativo e ela está habilitada.
A interrupção, perda de foco, mudança do mapeamento e encerramento liberam teclas e botões mantidos.
O menu de sessão pode ser aberto mesmo sem vídeo, para que os ajustes locais continuem acessíveis.
O estado descreve a observação no cliente e não identifica se a causa está na captura, rede ou decode.

## Validação

- Baseline: 106 testes Swift e 31 Python aprovados antes das alterações.
- Resultado final: 111 testes Swift, com 83 core e 28 Mac, e 31 Python aprovados.
- Novos testes cobrem persistência por host, reset, registros inválidos, atividade do stream e identidade das teclas adicionais nos dois perfis.
- Build Release Mac e assinatura ad hoc do app de laboratório aprovados.
- Build Windows MSVC com `/W4 /WX /O2` aprovado, com 19 casos de input e 12 de recuperação.
- Inspeção real do menu no Mac: abertura por clique, ocultação das estatísticas, troca de Command/Control e entrada indisponível sem vídeo confirmadas pela acessibilidade e screenshots.
- A inspeção posterior utilizou exclusivamente a janela do cliente no monitor U28E590, ID 4 no inventário de 01/10/2026, conforme preferência do usuário.
- No U28E590, a abertura por clique funcionou em janela e tela cheia, com controles legíveis e sem clipping.

As verificações de interface desta rodada ocorreram sem vídeo Windows ativo, devido ao impedimento de primeiro frame documentado na [recuperação de captura](capture-recovery-progress.md).
O atalho novo do menu tem teste automatizado de reconhecimento, mas a tentativa de acioná-lo pelo controle visual retornou timeout da integração; sua validação física permanece pendente.
Os controles de Alt+Tab/Windows no painel novo ainda precisam de validação dentro de uma sessão ativa, embora as sequências e os comandos AppKit anteriores já tenham testes e evidência real.
A persistência possui teste de armazenamento isolado; o teste visual usou `--no-preferences` para preservar o perfil do usuário.
As mudanças não acrescentam clipboard entre máquinas, áudio, captura HID, seleção de qualidade remota ou tela inicial de hosts.

Reprodução no monitor reservado, conferindo IDs e endereços antes da execução:

```sh
swift build --package-path macos -c release --product lightray-client
macos/.build/release/lightray-client 192.168.15.5:37373 --pair-file tools/windows/results/desktop-pairing --streams 1 --no-fec --local-cursor --screen-id 4 --no-preferences
```

O app atualizado está em `output/windows-client/Lightray Windows Lab.app`.
As evidências estão em [session-controls-initial](evidence/session-controls-initial/README.md).
As alterações seguem locais, sem commit ou PR publicado.

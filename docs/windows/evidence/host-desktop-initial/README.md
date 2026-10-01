# Evidência do primeiro desktop Windows→Mac

Campanha final `desktop-005`, 29/09/2026, alterações locais sobre `5002116872492da705aa6252f26482b02e3df5b5`.
Esta pasta não contém a PSK nem o arquivo de pareamento.

- `host-result.json`, `host.log`: duas sessões reais, contadores do encoder/transporte/input e encerramento.
- `test-window.json`: confirmação independente no aplicativo Windows de texto, clique, rolagem e Ctrl+A; não contém texto digitado arbitrário.
- `client-90s.log`, `client-reconnect-30s.log`, `metrics.json`: diagnósticos e resumo do cliente Mac, sem tratar RTT como input→photon.
- `client-decoded-test-window.png`: imagem decodificada pelo próprio cliente após reconectar, com apenas conteúdo da janela de teste.
- `windows-build.log`: build MSVC com warnings como erros e 15 casos de input usando emissor falso.
- `mac-tests.log`, `python-tests.log`, `mac-client-build.log`: 92 testes Swift, 29 Python e build Release do cliente.
- `launch.json`, `source-manifest.json`: hashes da DLL, executável Windows, fontes e binário Mac de build; o bundle Mac local recebeu assinatura ad hoc posteriormente.
- `gpu-sample.csv`: amostra agregada da RTX 4090; não é profiling exclusivo do host.
- `cleanup.json`: zero processos de teste, endpoints UDP, regras temporárias de firewall e tarefas de laboratório restantes.

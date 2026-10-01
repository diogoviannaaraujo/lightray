# Evidências: host NVENC inicial, 29/09/2026

- `encode/provenance.json`: origem nativa Windows, SHA do executável usado, fontes/headers e resultados das três resoluções.
- `encode/1920x1080`, `2560x1440`, `3840x2160`: JSON, CSV de 120 frames e inspeção independente do bitstream; bitstreams/payloads ficam nos diretórios ignorados do laboratório.
- `encode/corpus/manifest.json`: caminhos/tamanhos/hashes exatos dos três clips e metadados; taxa declarada 60, estímulo não cadenciado.
- `mac-software/` e `windows-mf/`: decode dos mesmos clips, hashes por frame e logs de cada backend.
- `comparison/result.json`: 360 frames comparados, zero diferenças de pixels.
- `roundtrip/`: Annex B reconstruído dos NALs com prefixo de comprimento, hashes e percentis de encode/lock recalculados dos CSVs.
- `mac-reference/`: cópia identificada por hashes do core/VideoDecoder, execução Release e igualdade de pixels após fragmentação/remontagem local; sem socket, criptografia, FEC ou GUI.
- `controls/`: builds, 14 casos C++ no Windows, rejeição de adapter/dimensão/sobrescrita, testes Python e limpeza de processos.
- `initial-failure/`: diagnóstico preservado da interpretação incorreta de hwEncodeStatus; não é resultado de aprovação.
- `lab-tests-mac.log`: suíte Python final no Mac.
- `lab-tests-windows.log`: suíte Python final de 25 casos no Windows, incluindo o preparador do ensaio Mac; o log anterior de 24 casos em `controls/` permanece como histórico.
- `docs-check.log`: checker de documentação após adicionar o plano e relatório do host.

A RTX 4090 foi usada para encode NVENC e decode Media Foundation/D3D11; FFmpeg/ffprobe entraram somente como ferramentas de decode, remux e inspeção.
Nenhum arquivo aqui atesta captura de desktop, sessão UDP integrada, apresentação ou input→photon.
Os logs mantêm falhas anteriores como histórico e os resultados finais como campanhas distintas, sem sobrescrita.

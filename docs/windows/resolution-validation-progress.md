# Decode nativo 1440p/4K — 28/09/2026

O experimento de decode foi ampliado para 2560×1440 e 3840×2160 no mesmo Windows 11/RTX 4090 da [primeira execução nativa](native-validation-progress.md).
Cada clip contém 120 frames a 60 fps declarados, HEVC Main, 8-bit 4:2:0, somente imagens I/P, geradas de `testsrc2` pelo VideoToolbox do Mac com fallback de encoder software desabilitado.
Não houve captura de desktop, abertura de janela ou input.

## Resultado

| Backend Windows | 1440p | 4K | Comparação dos pixels com o Mac |
| --- | --- | --- | --- |
| FFmpeg software | 120/120 frames | 120/120 frames | [Zero diferenças](evidence/resolutions/comparison-software/result.json) |
| FFmpeg D3D11VA, adapter 0 | 120/120 frames | 120/120 frames | [Zero diferenças](evidence/resolutions/comparison-d3d11va/result.json) |
| Media Foundation/D3D11, adapter 0 | 120/120 samples GPU | 120/120 samples GPU | [Zero diferenças](evidence/resolutions/comparison-media-foundation/result.json) |

São 720 decodificações no Windows sobre 240 frames distintos, além da referência software no Mac.
O runner exigiu hashes/tamanhos corretos do corpus, formato Main/yuv420p, dimensões e quantidade exatas, além da identidade válida do adapter nos caminhos GPU.
Todos os pixels yuv420p foram comparados por índice; a comparação recusa artefatos alterados e frames omitidos/reordenados.

Esse resultado comprova decode correto desses clips nas duas resoluções nesta máquina.
Não comprova apresentação sustentada a 60 fps, qualidade de cor no monitor, input→photon, estabilidade longa, streaming pela rede ou compatibilidade com outra GPU.
Os caminhos de GPU continuam fazendo download para hashing e o probe MF continua alocando staging por frame; seus tempos não elegem o backend de menor latência.

## Corpus e reprodução

O [gerador](../../tools/windows/generate-corpus.py) limita o ensaio a dois clips de 120 frames, timeout por processo, perfil Main/I/P e diretório novo dentro do checkout.
O [manifesto](evidence/resolutions/corpus-manifest.json) preserva comandos, versão FFmpeg, origem sintética, tamanhos e SHA-256 dos quatro arquivos.
Os bitstreams e metadados ocupam aproximadamente 14,4 MiB e permanecem em `tools/windows/results/resolution-corpus-001/` nos laboratórios Mac e Windows; não foram incluídos no Git.
Os resultados e hashes por frame foram preservados em [evidence/resolutions](evidence/resolutions/README.md).
Regenerar o estímulo em outro hardware/OS pode produzir outros bytes codificados; nesse caso gerar uma nova referência e comparar somente execuções do mesmo manifesto.
Para reproduzir exatamente os hashes desta execução é necessário usar os arquivos preservados com os SHA-256 registrados, não simplesmente regenerá-los.

```sh
python3 tools/windows/generate-corpus.py --output tools/windows/results/resolution-corpus-001
python3 tools/windows/lab.py decode-reference --corpus-manifest tools/windows/results/resolution-corpus-001/manifest.json --output tools/windows/results/resolution-mac-software-001
```

No Windows, transferir o corpus mantendo os caminhos relativos e executar `decode-reference` com o mesmo `--corpus-manifest`, um `--backend` por execução e diretórios novos.
Comparar cada execução com a referência Mac usando `compare-reference`.

O manifesto auditado de 1080p permanece como padrão e não foi alterado.
O runner agora aceita manifesto sintético explícito, com um a oito pares HEVC/JSON, caminhos únicos, nomes de clips únicos, confinamento ao checkout e integridade de cada arquivo.
E03.2 permanece aberto: a parte de decode cobre agora as três resoluções, mas apresentação e instrumentação comparável ainda precisam ser executadas.
